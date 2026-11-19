import Foundation
import UIKit
import Vision

/// Then & now: the places photographed years apart. The map markers carry
/// no date, but their filter does — they are asked for one year at a time,
/// newest first, until every geotagged photo has its year; no photo is
/// downloaded to find the spots (`ThenAndNowPlan.spots`).
@MainActor
@Observable
final class ThenAndNowViewModel {

    private let client: any ImmichClient
    let token: String?
    /// The address in use, read at every use (L-26).
    var baseURL: URL { baseURLProvider() }
    private let baseURLProvider: @Sendable () -> URL
    private let photos: PhotoLibraryService
    private let session: @Sendable () -> URLSession

    private(set) var isLoading = true
    private(set) var progress = 0.0
    private(set) var errorMessage: String?
    private(set) var spots: [ThenNowSpot] = []
    private var loadStarted = false

    init(
        client: any ImmichClient,
        baseURL: @escaping @Sendable () -> URL,
        token: String?,
        photos: PhotoLibraryService,
        session: @escaping @Sendable () -> URLSession
    ) {
        self.client = client
        self.baseURLProvider = baseURL
        self.token = token
        self.photos = photos
        self.session = session
    }

    func load() async {
        guard !loadStarted else { return }
        loadStarted = true
        defer { isLoading = false }
        let client = self.client
        do {
            let total = try await client.getMapMarkers(filter: .all).count
            guard total > 0 else {
                errorMessage = String(localized: "No photo with a location yet.")
                return
            }
            var markers: [DatedMarker] = []
            var year = Calendar.current.component(.year, from: Date())
            // Six years at a time, until every marker has its year.
            while markers.count < total, year >= ThenAndNowPlan.earliestYear {
                try Task.checkCancellation()
                let years = Array(stride(from: year, to: max(year - 6, ThenAndNowPlan.earliestYear - 1), by: -1))
                try await withThrowingTaskGroup(of: [DatedMarker].self) { group in
                    for y in years {
                        group.addTask {
                            try await client.getMapMarkers(filter: ThenAndNowPlan.filter(year: y)).map {
                                DatedMarker(id: $0.id, latitude: $0.lat, longitude: $0.lon, year: y, city: $0.city, country: $0.country)
                            }
                        }
                    }
                    for try await batch in group { markers.append(contentsOf: batch) }
                }
                progress = min(Double(markers.count) / Double(total), 1)
                year -= years.count
            }
            let found = await Task.detached(priority: .userInitiated) { ThenAndNowPlan.spots(markers) }.value
            spots = found
            if found.isEmpty {
                errorMessage = String(localized: "No place photographed at least \(ThenAndNowPlan.minYearGap) years apart yet.")
            }
        } catch {
            if Task.isCancelled { loadStarted = false }
            errorMessage = error.userFacingMessage ?? String(localized: "The map could not be loaded.")
        }
    }

    func thumbnailURL(for id: String) -> URL {
        ImmichAssetURL.thumbnail(assetId: id, thumbhash: "", baseURL: baseURL, size: .thumbnail)
    }

    /// The spot's pair, made once: the list's links are rebuilt with the
    /// list, the pair they open must not be.
    func pairViewModel(for spot: ThenNowSpot) -> ThenAndNowPairViewModel {
        if let pair = pairs[spot.id] { return pair }
        let pair = ThenAndNowPairViewModel(
            spot: spot, baseURL: baseURLProvider, token: token, photos: photos, session: session
        )
        pairs[spot.id] = pair
        return pair
    }

    @ObservationIgnored private var pairs: [String: ThenAndNowPairViewModel] = [:]
}

/// One spot's then & now: of a few photos of its first year and of its last,
/// the pair that looks most alike (the same viewpoint — Vision's feature
/// prints), then any other pair on demand; saved as the stacked image or the
/// wipe video.
@MainActor
@Observable
final class ThenAndNowPairViewModel {

    enum ExportState: Equatable {
        case idle
        case rendering(Double)
        case saving
        case done
        case failed(String)
    }

    /// Photos of each year looked at for the first pair, at most.
    static let photosPerYear = 6
    /// Photos of each year offered to choose from, at most (spread over it).
    static let choicesPerYear = 30

    let spot: ThenNowSpot
    let token: String?
    var baseURL: URL { baseURLProvider() }
    private let baseURLProvider: @Sendable () -> URL
    private let photos: PhotoLibraryService
    private let session: @Sendable () -> URLSession

    private(set) var isPreparing = true
    private(set) var errorMessage: String?
    private(set) var then: ThenNowPhoto?
    private(set) var now: ThenNowPhoto?
    /// A photo being put in place: its row shows it chosen at once.
    private(set) var choosing: String?
    private var looks: [String: DumpCandidate] = [:]
    private var previews: [String: UIImage] = [:]
    private var preparationStarted = false

    var showsCredit = true
    private(set) var exportState: ExportState = .idle
    private(set) var exportedURL: URL?
    private var exportTask: Task<Void, Never>?

    init(
        spot: ThenNowSpot,
        baseURL: @escaping @Sendable () -> URL,
        token: String?,
        photos: PhotoLibraryService,
        session: @escaping @Sendable () -> URLSession
    ) {
        self.spot = spot
        self.baseURLProvider = baseURL
        self.token = token
        self.photos = photos
        self.session = session
    }

    /// The photos of the first year and of the last to choose from.
    var thenChoices: [String] { MosaicLayoutBuilder.spread(spot.thenIDs, keeping: Self.choicesPerYear) }
    var nowChoices: [String] { MosaicLayoutBuilder.spread(spot.nowIDs, keeping: Self.choicesPerYear) }

    func thumbnailURL(for id: String) -> URL {
        ImmichAssetURL.thumbnail(assetId: id, thumbhash: "", baseURL: baseURL, size: .thumbnail)
    }

    func prepare() async {
        guard !preparationStarted else { return }
        preparationStarted = true
        defer { isPreparing = false }
        let thenIDs = MosaicLayoutBuilder.spread(spot.thenIDs, keeping: Self.photosPerYear)
        let nowIDs = MosaicLayoutBuilder.spread(spot.nowIDs, keeping: Self.photosPerYear)
        let found = await PhotoLooker.look(
            at: (thenIDs + nowIDs).map(Self.asset(id:)), baseURL: { baseURL }, token: token, session: session,
            progress: { _ in }
        )
        var prints: [String: FeaturePrintObservation] = [:]
        for (candidate, print) in found {
            looks[candidate.id] = candidate
            prints[candidate.id] = print
        }
        let thenFound = thenIDs.filter { looks[$0] != nil }
        let nowFound = nowIDs.filter { looks[$0] != nil }
        let pairs = ThenAndNowPlan.rankedPairs(then: thenFound, now: nowFound) { a, b in
            prints[a].flatMap { pa in prints[b].flatMap { try? pa.distance(to: $0) } }
        }
        guard let first = pairs.first else {
            errorMessage = String(localized: "The photos could not be loaded.")
            return
        }
        await loadPreviews([first.then, first.now])
        then = photo(first.then, year: spot.thenYear)
        now = photo(first.now, year: spot.nowYear)
        if then == nil || now == nil { errorMessage = String(localized: "The photos could not be loaded.") }
    }

    /// Puts `id` on its side — the first year's or the last's. A photo not
    /// looked at yet is, for where its subject is (the crop is centered on it).
    func choose(_ id: String) async {
        let isThen = spot.thenIDs.contains(id)
        guard isThen || spot.nowIDs.contains(id), id != then?.id, id != now?.id else { return }
        choosing = id
        defer { if choosing == id { choosing = nil } }
        if looks[id] == nil {
            let found = await PhotoLooker.look(
                at: [Self.asset(id: id)], baseURL: { baseURL }, token: token, session: session, progress: { _ in }
            )
            for (candidate, _) in found { looks[candidate.id] = candidate }
        }
        await loadPreviews([id])
        guard choosing == id, let chosen = photo(id, year: isThen ? spot.thenYear : spot.nowYear) else { return }
        if isThen { then = chosen } else { now = chosen }
    }

    private func photo(_ id: String, year: Int) -> ThenNowPhoto? {
        previews[id].map { ThenNowPhoto(id: id, image: $0, focus: looks[id]?.focus ?? CGPoint(x: 0.5, y: 0.5), year: year) }
    }

    private func loadPreviews(_ ids: [String]) async {
        let session = self.session
        let token = self.token
        let base = baseURL
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for id in ids where previews[id] == nil {
                group.addTask {
                    let url = ImmichAssetURL.thumbnail(assetId: id, thumbhash: "", baseURL: base, size: .preview)
                    guard let (data, _) = try? await AssetFileTransfer.fetchData(from: url, token: token, session: session()),
                          let image = UIImage(data: data) else { return (id, nil) }
                    return (id, image.preparingForDisplay() ?? image)
                }
            }
            for await (id, image) in group {
                if let image { previews[id] = image }
            }
        }
    }

    /// The marker's id as an asset: all the looking needs (no thumbhash: the
    /// thumbnail's cache key falls back to the latest one known, or none).
    private static func asset(id: String) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "", ratio: 1, isFavorite: false, visibility: "timeline", isTrashed: false, isImage: true,
            thumbhash: nil, createdAt: "", fileCreatedAt: "", localOffsetHours: 0, duration: nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    // MARK: - Export

    func saveImage() {
        guard exportTask == nil, let then, let now else { return }
        exportState = .saving
        let image = ThenAndNowRenderer.stacked(then: then, now: now, place: spot.place, credit: showsCredit)
        let photos = photos
        exportTask = Task {
            defer { exportTask = nil }
            do {
                guard let data = image.jpegData(compressionQuality: 0.92) else { throw CocoaError(.fileWriteUnknown) }
                _ = try await photos.saveImage(data: data)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Swimmich Then and Now \(UUID().uuidString.prefix(8)).jpg")
                try data.write(to: url)
                finish(with: url)
            } catch {
                exportState = .failed(error.userFacingMessage ?? error.localizedDescription)
            }
        }
    }

    func saveVideo() {
        guard exportTask == nil, let then, let now else { return }
        exportState = .rendering(0)
        let place = spot.place
        let credit = showsCredit
        let photos = photos
        exportTask = Task {
            defer { exportTask = nil }
            do {
                // Off the main actor (a nonisolated function), and cancelled with this task.
                let url = try await ThenAndNowRenderer.render(then: then, now: now, place: place, showsCredit: credit) { value in
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
                finish(with: url)
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = error.userFacingMessage.map { .failed($0) } ?? .idle
            }
        }
    }

    private func finish(with url: URL) {
        discardExport()
        exportedURL = url
        exportState = .done
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func dismissExportResult() {
        exportState = .idle
    }

    func discardExport() {
        if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
        exportedURL = nil
    }
}
