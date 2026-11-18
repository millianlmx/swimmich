import Foundation
import UIKit
import Vision

/// Reel orchestration: looks at the photos (`PhotoLooker`) — a search's best
/// matches first, or an even spread of an album or a selection — picks the
/// reel's photos (`ReelPlan.pick`), loads their previews, and exports the
/// film (`ReelRenderer`). A search's words are the reel's title ("sunset");
/// without them, the years it spans.
@MainActor
@Observable
final class ReelViewModel: Identifiable {

    enum ExportState: Equatable {
        case idle
        case rendering(Double)
        case saving
        case done
        case failed(String)
    }

    /// The player's photos are kept this large at most (their longest side).
    static let playerImageSide: CGFloat = 720

    let token: String?
    /// The address in use, read at every use (L-26).
    var baseURL: URL { baseURLProvider() }
    private let baseURLProvider: @Sendable () -> URL
    private let photos: PhotoLibraryService
    private let client: any ImmichClient
    private let session: @Sendable () -> URLSession
    private let assets: [AssetReactItem]
    /// The words searched for, or the album's name; nil for a selection.
    private let query: String?
    /// True for a search: its order is how well each photo matched.
    private let ranked: Bool

    private(set) var isPreparing = true
    private(set) var preparationProgress = 0.0
    private(set) var errorMessage: String?

    private var candidates: [DumpCandidate] = []
    private var featurePrints: [String: FeaturePrintObservation] = [:]
    private var takenAt: [String: Date] = [:]
    /// The reel's photos, oldest first, before their previews are in.
    private(set) var picks: [DumpCandidate] = []
    /// Photos added and removed by hand: a change of length keeps the first
    /// and never brings back the second.
    private var added = Set<String>()
    private var removed = Set<String>()
    /// The reel's photos whose preview is in, oldest first.
    private(set) var shots: [ReelShot] = []
    /// The title card's photo: the best of the reel.
    private(set) var cover: ReelShot?
    private var previewData: [String: Data] = [:]
    @ObservationIgnored private var playerImages: [String: UIImage] = [:]
    private var preparationStarted = false

    var length: ReelLength = .medium {
        didSet { if length != oldValue, !candidates.isEmpty { Task { await repick() } } }
    }
    var showsCredit = true
    /// The city and country over each photo.
    var showsPlaces = true
    /// Where each photo was taken, by asset id ("" when the server does not know).
    private var places: [String: String] = [:]

    private(set) var exportState: ExportState = .idle
    private(set) var exportedVideoURL: URL?
    private var exportTask: Task<Void, Never>?

    init(
        assets: [AssetReactItem],
        title: String?,
        ranked: Bool,
        client: any ImmichClient,
        baseURL: @escaping @Sendable () -> URL,
        token: String?,
        photos: PhotoLibraryService,
        session: @escaping @Sendable () -> URLSession
    ) {
        // Photos only, and only those on the server.
        self.assets = assets.filter { $0.isImage && $0.thumbhash != nil }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed?.isEmpty == false ? trimmed : nil
        self.ranked = ranked
        self.client = client
        self.baseURLProvider = baseURL
        self.token = token
        self.photos = photos
        self.session = session
    }

    var duration: Double { ReelPlan.duration(photoCount: shots.count) }

    /// The search's words or the album's name, else the years the reel spans.
    var title: String { query ?? subtitleYears ?? "" }
    /// The years under the title.
    var subtitle: String? { query == nil ? nil : subtitleYears }

    private var subtitleYears: String? { ReelPlan.yearRange(shots.compactMap(\.year)) }

    // MARK: - Preparation

    func prepare() async {
        guard !preparationStarted else { return }
        preparationStarted = true
        defer { isPreparing = false }
        guard assets.count >= ReelPlan.minPhotos else {
            errorMessage = String(localized: "A reel needs at least \(ReelPlan.minPhotos) photos.")
            return
        }
        for asset in assets { takenAt[asset.id] = PhotoDumpViewModel.date(asset.fileCreatedAt) }
        let sample = ranked
            ? Array(assets.prefix(ReelPlan.sampleSize))
            : MosaicLayoutBuilder.spread(assets.sorted { $0.fileCreatedAt < $1.fileCreatedAt }, keeping: ReelPlan.sampleSize)
        let found = await PhotoLooker.look(
            at: sample, baseURL: { baseURL }, token: token, session: session,
            progress: { preparationProgress = $0 * 0.8 }
        )
        guard !Task.isCancelled else {
            preparationStarted = false
            return
        }
        for (candidate, print) in found {
            candidates.append(candidate)
            featurePrints[candidate.id] = print
        }
        guard candidates.count >= ReelPlan.minPhotos else {
            errorMessage = String(localized: "The photos could not be loaded.")
            return
        }
        await repick()
    }

    /// Picks the reel's photos for the current length — those added by hand
    /// kept, those removed left out — and shows them.
    private func repick() async {
        picks = ReelPlan.pick(
            candidates, count: max(length.photoCount, added.count), required: added, excluded: removed
        ) { a, b in
            PhotoLooker.isDuplicate(a, b, prints: featurePrints, dates: takenAt)
        }
        await show()
    }

    /// Loads the previews of `picks` not in yet and makes them the reel.
    private func show() async {
        let picks = self.picks
        let session = self.session
        let token = self.token
        let base = baseURL
        let missing = picks.filter { previewData[$0.id] == nil }
        var done = 0
        await withTaskGroup(of: (String, Data?).self) { group in
            for pick in missing {
                group.addTask {
                    let url = ImmichAssetURL.thumbnail(
                        assetId: pick.id, thumbhash: pick.asset.thumbhash ?? "", baseURL: base, size: .preview
                    )
                    return (pick.id, try? await AssetFileTransfer.fetchData(from: url, token: token, session: session()).0)
                }
            }
            for await (id, data) in group {
                if let data, UIImage(data: data) != nil { previewData[id] = data }
                done += 1
                if isPreparing { preparationProgress = 0.8 + 0.2 * Double(done) / Double(max(missing.count, 1)) }
            }
        }
        await loadPlaces(of: picks)
        shots = picks.compactMap { pick in
            previewData[pick.id].map { data in
                let day = takenAt[pick.id].flatMap { GrowingUpPlan.localDay(of: pick.asset, date: $0) }
                let place = places[pick.id].flatMap { $0.isEmpty ? nil : $0 }
                return ReelShot(asset: pick.asset, imageData: data, focus: pick.focus, year: day?.year, place: place)
            }
        }
        let best = picks.max { $0.score < $1.score }?.id
        cover = shots.first { $0.id == best } ?? shots.first
        if shots.count < ReelPlan.minPhotos, isPreparing {
            errorMessage = String(localized: "The photos could not be loaded.")
        }
    }

    /// Where each of `picks` was taken: from the list it came in when it says
    /// (an album's photos carry their city), else asked of the server, once
    /// per photo. Search results come without it.
    private func loadPlaces(of picks: [DumpCandidate]) async {
        var missing: [AssetReactItem] = []
        for pick in picks where places[pick.id] == nil {
            if let label = ReelPlan.placeLabel(city: pick.asset.city, country: pick.asset.country) {
                places[pick.id] = label
            } else {
                missing.append(pick.asset)
            }
        }
        guard !missing.isEmpty else { return }
        let client = self.client
        await withTaskGroup(of: (String, String).self) { group in
            for asset in missing {
                group.addTask {
                    let exif = try? await client.getAsset(id: asset.id).exifInfo
                    return (asset.id, ReelPlan.placeLabel(city: exif?.city, country: exif?.country) ?? "")
                }
            }
            for await (id, label) in group { places[id] = label }
        }
    }

    // MARK: - Editing

    /// The photos looked at and not in the reel, the most worth showing first.
    var morePhotos: [DumpCandidate] {
        let inReel = Set(picks.map(\.id))
        return ReelPlan.weighed(candidates).filter { !inReel.contains($0.id) }
    }

    /// A photo can leave the reel while it keeps enough of them.
    var canRemove: Bool { picks.count > ReelPlan.minPhotos }

    func remove(_ id: String) async {
        guard canRemove else { return }
        removed.insert(id)
        added.remove(id)
        picks.removeAll { $0.id == id }
        await show()
    }

    func add(_ id: String) async {
        guard let candidate = candidates.first(where: { $0.id == id }), !picks.contains(candidate) else { return }
        added.insert(id)
        removed.remove(id)
        picks = PhotoDumpPicker.chronologicalOrder(picks + [candidate])
        await show()
    }

    func thumbnailURL(for asset: AssetReactItem) -> URL {
        ImmichAssetURL.thumbnail(assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: baseURL, size: .thumbnail)
    }

    // MARK: - Player

    /// The photo of `shot`, downscaled for the player, decoded once.
    func playerImage(for shot: ReelShot) -> UIImage? {
        if let image = playerImages[shot.id] { return image }
        guard let image = UIImage(data: shot.imageData) else { return nil }
        let side = max(image.size.width, image.size.height)
        let scale = min(1, Self.playerImageSide / max(side, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        playerImages[shot.id] = small
        return small
    }

    // MARK: - Export

    func startExport() {
        guard exportTask == nil, let cover, !shots.isEmpty else { return }
        exportState = .rendering(0)
        let shots = shots
        let title = title
        let subtitle = subtitle
        let credit = showsCredit
        let showsPlaces = showsPlaces
        let photos = photos
        exportTask = Task {
            defer { exportTask = nil }
            do {
                // Off the main actor (a nonisolated function), and cancelled with this task.
                let url = try await ReelRenderer.render(
                    shots: shots, cover: cover, title: title, subtitle: subtitle,
                    showsCredit: credit, showsPlaces: showsPlaces
                ) { value in
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
                discardExportedVideo()
                exportedVideoURL = url
                exportState = .done
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = error.userFacingMessage.map { .failed($0) } ?? .idle
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func dismissExportResult() {
        exportState = .idle
    }

    func discardExportedVideo() {
        if let exportedVideoURL { try? FileManager.default.removeItem(at: exportedVideoURL) }
        exportedVideoURL = nil
    }
}
