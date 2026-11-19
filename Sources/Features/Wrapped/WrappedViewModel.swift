import Foundation
import UIKit
import Vision

/// Swimmich Wrapped: a year of photos as a story of cards. Gathers, in
/// parallel, the year's month counts (the timeline's buckets), its people
/// (each named person's buckets), its places (the map markers of the year),
/// its photos (their colors, their busiest day, the best nine), then draws
/// the cards (`WrappedRenderer`).
@MainActor
@Observable
final class WrappedViewModel: Identifiable {

    enum ExportState: Equatable {
        case idle
        case rendering(Double)
        case saving
        case done
        case failed(String)
    }

    private let client: any ImmichClient
    let token: String?
    var baseURL: URL { baseURLProvider() }
    private let baseURLProvider: @Sendable () -> URL
    private let photos: PhotoLibraryService
    private let session: @Sendable () -> URLSession

    /// This year and last year: the year in progress, and the last one whole.
    let years: [Int]
    var year: Int { didSet { if year != oldValue { Task { await load() } } } }
    var showsCredit = true { didSet { if showsCredit != oldValue { redraw() } } }

    private(set) var isLoading = true
    private(set) var progress = 0.0
    private(set) var errorMessage: String?
    private(set) var cards: [(card: WrappedCard, image: UIImage)] = []
    private var content: WrappedContent?
    private var generation = 0

    private(set) var exportState: ExportState = .idle
    private(set) var exportedURLs: [URL] = []
    private var exportTask: Task<Void, Never>?

    init(
        client: any ImmichClient,
        baseURL: @escaping @Sendable () -> URL,
        token: String?,
        photos: PhotoLibraryService,
        session: @escaping @Sendable () -> URLSession,
        now: Date = Date()
    ) {
        self.client = client
        self.baseURLProvider = baseURL
        self.token = token
        self.photos = photos
        self.session = session
        let current = Calendar.current.component(.year, from: now)
        self.years = [current, current - 1]
        self.year = current
    }

    // MARK: - Loading

    func load() async {
        generation += 1
        let current = generation
        let year = year
        isLoading = true
        errorMessage = nil
        progress = 0
        defer { if current == generation { isLoading = false } }
        let client = self.client
        do {
            let buckets = try await client.getTimeBuckets(
                isFavorite: nil, isTrashed: nil, personId: nil, withPartners: nil,
                visibility: AssetVisibility.timeline.rawValue, withStacked: nil, orderBy: nil
            )
            guard current == generation else { return }
            let months = WrappedPlan.monthCounts(buckets, year: year)
            let total = months.reduce(0, +)
            guard total > 0 else {
                cards = []
                errorMessage = String(localized: "No photos in \(String(year)) yet.")
                return
            }
            progress = 0.1
            async let people = loadPeople(year: year)
            async let places = loadPlaces(year: year)
            async let assets = loadAssets(year: year)
            let (loadedPeople, loadedPlaces, loadedAssets) = await (people, places, assets)
            guard current == generation else { return }
            progress = 0.6
            let colors = loadedAssets.compactMap { asset in
                MosaicColor(thumbhash: asset.thumbhash).map { MosaicTile(asset: asset, color: $0) }
            }
            // The best shots are scored while the mosaic's thumbnails download.
            async let bestTask = bestShots(of: loadedAssets)
            async let colorImagesTask = mosaicThumbnails(of: colors)
            let (best, colorImages) = await (bestTask, colorImagesTask)
            guard current == generation else { return }
            progress = 0.95
            content = WrappedContent(
                year: year,
                total: total,
                monthCounts: months,
                busiestDay: WrappedPlan.busiestDay(loadedAssets),
                people: loadedPeople,
                placesPoster: loadedPlaces?.poster,
                places: loadedPlaces?.stats,
                colors: colors,
                colorImages: colorImages,
                best: best
            )
            redraw()
            progress = 1
        } catch {
            guard current == generation else { return }
            errorMessage = error.userFacingMessage ?? String(localized: "The year could not be loaded.")
        }
    }

    /// The named people of the year, the most photographed first, with
    /// their face.
    private func loadPeople(year: Int) async -> [(person: WrappedPerson, face: UIImage?)] {
        let client = self.client
        guard let response = try? await client.getPeople(page: 1, withHidden: false) else { return [] }
        let named = response.people.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(WrappedPlan.peopleConsidered)
        let counted = await withTaskGroup(of: WrappedPerson?.self) { group in
            for person in named {
                group.addTask {
                    guard let buckets = try? await client.getTimeBuckets(
                        isFavorite: nil, isTrashed: nil, personId: person.id, withPartners: nil,
                        visibility: AssetVisibility.timeline.rawValue, withStacked: nil, orderBy: nil
                    ) else { return nil }
                    let count = WrappedPlan.monthCounts(buckets, year: year).reduce(0, +)
                    return WrappedPerson(id: person.id, name: person.name, photos: count)
                }
            }
            var out: [WrappedPerson] = []
            for await person in group {
                if let person { out.append(person) }
            }
            return out
        }
        let top = WrappedPlan.topPeople(counted)
        let base = baseURL
        let token = self.token
        let session = self.session
        let faces = await withTaskGroup(of: (String, UIImage?).self) { group in
            for person in top {
                group.addTask {
                    let url = ImmichAssetURL.personThumbnail(personId: person.id, baseURL: base, size: .preview)
                    let data = try? await AssetFileTransfer.fetchData(from: url, token: token, session: session()).0
                    return (person.id, data.flatMap(UIImage.init(data:)))
                }
            }
            var out: [String: UIImage] = [:]
            for await (id, image) in group { out[id] = image }
            return out
        }
        return top.map { ($0, faces[$0.id]) }
    }

    /// The year's map poster and its numbers, nil without a photo with a place.
    private func loadPlaces(year: Int) async -> (poster: UIImage, stats: MapPosterStats)? {
        guard let markers = try? await client.getMapMarkers(filter: ThenAndNowPlan.filter(year: year)).map(MapPhoto.init(from:)),
              !markers.isEmpty else { return nil }
        let stats = MapPosterStats.make(markers)
        let frame = MapPosterRenderer.mapFrame(format: .story)
        let rect = MapPosterRenderer.mapRect(for: markers.map(\.coordinate), aspect: frame.width / frame.height)
        let snapshot = try? await MapPosterRenderer.snapshot(of: rect, size: frame.size)
        let poster = MapPosterRenderer.render(
            markers: markers, stats: stats, snapshot: snapshot, format: .story,
            title: String(localized: "My \(String(year)) on the map"),
            subtitle: String(localized: "\(stats.photoCount) photos"), showsCredit: false
        )
        return (poster, stats)
    }

    /// The year's photos, a page at a time, up to `WrappedPlan.maxAssets`.
    private func loadAssets(year: Int) async -> [AssetReactItem] {
        guard let range = WrappedPlan.takenRange(year: year) else { return [] }
        var assets: [AssetReactItem] = []
        var seen = Set<String>()
        var page: Int? = 1
        while let current = page, assets.count < WrappedPlan.maxAssets {
            var dto = MetadataSearchDto()
            dto.takenAfter = range.after
            dto.takenBefore = range.before
            dto.type = "IMAGE"
            dto.size = 1000
            dto.page = current
            guard let response = try? await client.searchMetadata(dto: dto) else { break }
            for item in response.assets.items where seen.insert(item.id).inserted {
                assets.append(AssetReactItem(from: item))
            }
            page = response.assets.nextPage.flatMap(Int.init)
        }
        return assets
    }

    /// The thumbnails of the photos the colors card shows (the story mosaic's
    /// cells, ~90 px each: the server's small thumbnail), eight at a time.
    private func mosaicThumbnails(of tiles: [MosaicTile]) async -> [String: UIImage] {
        guard let layout = MosaicLayoutBuilder.build(tiles: tiles, format: .story, arrangement: .rainbow) else { return [:] }
        let token = self.token
        let session = self.session
        var images: [String: UIImage] = [:]
        let cells = layout.cells.map(\.asset)
        var offset = 0
        while offset < cells.count {
            if Task.isCancelled { break }
            let base = baseURL
            let chunk = Array(cells[offset..<min(offset + 8, cells.count)])
            let loaded = await withTaskGroup(of: (String, UIImage?).self) { group in
                for asset in chunk {
                    group.addTask {
                        let url = ImmichAssetURL.thumbnail(assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: base, size: .thumbnail)
                        let data = try? await AssetFileTransfer.fetchData(from: url, token: token, session: session()).0
                        return (asset.id, data.flatMap(UIImage.init(data:)))
                    }
                }
                var out: [(String, UIImage?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (id, image) in loaded { images[id] = image }
            offset += 8
        }
        return images
    }

    /// The year's best nine: an even spread and the favorites looked at
    /// (`PhotoLooker`), picked like a photo dump.
    private func bestShots(of assets: [AssetReactItem]) async -> [WrappedShot] {
        let withThumbhash = assets.filter { $0.thumbhash != nil }
        guard !withThumbhash.isEmpty else { return [] }
        let chronological = withThumbhash.sorted { $0.fileCreatedAt < $1.fileCreatedAt }
        let spread = Set(MosaicLayoutBuilder.spread(chronological, keeping: 90).map(\.id))
        let favorites = chronological.filter(\.isFavorite).prefix(30).map(\.id)
        let sample = chronological.filter { spread.contains($0.id) || favorites.contains($0.id) }
        let found = await PhotoLooker.look(at: sample, baseURL: { baseURL }, token: token, session: session) { value in
            progress = 0.6 + value * 0.3
        }
        var prints: [String: FeaturePrintObservation] = [:]
        var dates: [String: Date] = [:]
        for (candidate, print) in found {
            prints[candidate.id] = print
            dates[candidate.id] = PhotoDumpViewModel.date(candidate.asset.fileCreatedAt)
        }
        let picks = PhotoDumpPicker.pick(found.map(\.0), count: WrappedPlan.bestCount) { a, b in
            PhotoLooker.isDuplicate(a, b, prints: prints, dates: dates)
        }
        let base = baseURL
        let token = self.token
        let session = self.session
        let images = await withTaskGroup(of: (String, UIImage?).self) { group in
            for pick in picks {
                group.addTask {
                    let url = ImmichAssetURL.thumbnail(assetId: pick.id, thumbhash: pick.asset.thumbhash ?? "", baseURL: base, size: .preview)
                    let data = try? await AssetFileTransfer.fetchData(from: url, token: token, session: session()).0
                    return (pick.id, data.flatMap(UIImage.init(data:)))
                }
            }
            var out: [String: UIImage] = [:]
            for await (id, image) in group { out[id] = image }
            return out
        }
        return picks.compactMap { pick in images[pick.id].map { WrappedShot(image: $0, focus: pick.focus) } }
    }

    private func redraw() {
        guard let content else { return }
        let deck = WrappedPlan.cards(
            hasPeople: !content.people.isEmpty,
            hasPlaces: content.placesPoster != nil,
            hasColors: MosaicLayoutBuilder.grid(count: content.colors.count, format: .story) != nil,
            hasBest: content.best.count >= WrappedPlan.bestCount
        )
        cards = deck.map { ($0, WrappedRenderer.render($0, content: content, showsCredit: showsCredit)) }
    }

    // MARK: - Export

    /// Every card saved to the photo library in order, the files kept for
    /// the share sheet.
    func saveImages() {
        guard exportTask == nil, !cards.isEmpty else { return }
        exportState = .saving
        let images = cards.map(\.image)
        let photos = photos
        let year = year
        exportTask = Task {
            defer { exportTask = nil }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Swimmich Wrapped \(year) \(UUID().uuidString.prefix(6))", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var urls: [URL] = []
                for (index, image) in images.enumerated() {
                    guard let data = image.jpegData(compressionQuality: 0.92) else { throw CocoaError(.fileWriteUnknown) }
                    _ = try await photos.saveImage(data: data)
                    let url = folder.appendingPathComponent(String(format: "%02d.jpg", index + 1))
                    try data.write(to: url)
                    urls.append(url)
                }
                finish(urls)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                exportState = .failed(error.userFacingMessage ?? error.localizedDescription)
            }
        }
    }

    /// The cards as one video, each fading into the next.
    func saveVideo() {
        guard exportTask == nil, !cards.isEmpty else { return }
        exportState = .rendering(0)
        let images = cards.map(\.image)
        let photos = photos
        exportTask = Task {
            defer { exportTask = nil }
            do {
                // Off the main actor (a nonisolated function), and cancelled with this task.
                let url = try await WrappedRenderer.renderVideo(cards: images) { value in
                    Task { @MainActor [weak self] in
                        if case .rendering = self?.exportState { self?.exportState = .rendering(value) }
                    }
                }
                exportState = .saving
                do {
                    _ = try await photos.saveVideo(at: url)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                finish([url])
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = error.userFacingMessage.map { .failed($0) } ?? .idle
            }
        }
    }

    private func finish(_ urls: [URL]) {
        discardExport()
        exportedURLs = urls
        exportState = .done
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func dismissExportResult() {
        exportState = .idle
    }

    func discardExport() {
        let folders = Set(exportedURLs.map { $0.deletingLastPathComponent() })
        for url in exportedURLs { try? FileManager.default.removeItem(at: url) }
        for folder in folders where folder.lastPathComponent.hasPrefix("Swimmich Wrapped") {
            try? FileManager.default.removeItem(at: folder)
        }
        exportedURLs = []
    }
}
