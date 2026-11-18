import Foundation
import UIKit
import Vision

/// Photo-dump orchestration. Looks at the photos on small thumbnails — their
/// quality (`RoadTripPhotoScore`), a feature print to tell two shots of the
/// same moment apart, and where their subject is — then picks the dump
/// (`PhotoDumpPicker`), loads the previews of the photos it shows and exports
/// them, cropped to one shape, in their order: the carousel, ready to post.
@MainActor
@Observable
final class PhotoDumpViewModel: Identifiable {

    enum ExportState: Equatable {
        case idle
        case rendering
        case done
        case failed(String)
    }

    /// Photos looked at, at most: an even spread over the set, plus every
    /// favorite. Scoring a thumbnail takes Vision a few tens of milliseconds.
    static let scoringSampleSize = 240
    /// Width of the exported photos, the width Instagram shows.
    static let exportWidth: CGFloat = 1080

    let token: String?
    /// The address in use, read at every use (L-26).
    var baseURL: URL { baseURLProvider() }
    private let baseURLProvider: @Sendable () -> URL
    private let photos: PhotoLibraryService
    private let session: @Sendable () -> URLSession
    private let assets: [AssetReactItem]

    private(set) var isPreparing = true
    /// Share of the photos looked at, during the preparation.
    private(set) var preparationProgress = 0.0
    private(set) var errorMessage: String?

    private(set) var candidates: [DumpCandidate] = []
    /// The dump, in carousel order: the cover first.
    private(set) var picks: [DumpCandidate] = []
    /// Photos swapped out: never picked again.
    private var excluded = Set<String>()
    private var featurePrints: [String: FeaturePrintObservation] = [:]
    private var takenAt: [String: Date] = [:]

    var count = PhotoDumpPicker.defaultCount {
        didSet {
            guard count != oldValue, !candidates.isEmpty else { return }
            picks = PhotoDumpPicker.resized(
                picks, to: count, candidates: candidates, excluded: excluded, isDuplicate: isDuplicate
            )
            loadPreviews()
        }
    }
    var aspect: DumpAspect = .portrait

    /// Loaded previews, by asset id.
    private(set) var previews: [String: UIImage] = [:]
    private var previewTask: Task<Void, Never>?
    private var preparationStarted = false

    private(set) var exportState: ExportState = .idle
    /// The exported photos, in order, kept once they are in the photo library
    /// so the screen can hand them to the share sheet.
    private(set) var exportedURLs: [URL] = []

    init(
        assets: [AssetReactItem],
        baseURL: @escaping @Sendable () -> URL,
        token: String?,
        photos: PhotoLibraryService,
        session: @escaping @Sendable () -> URLSession
    ) {
        // Photos only, and only those on the server (a photo still only on
        // this device has no server thumbnail to look at).
        self.assets = assets.filter { $0.isImage && $0.thumbhash != nil }
        self.baseURLProvider = baseURL
        self.token = token
        self.photos = photos
        self.session = session
    }

    /// Photos the dump can still take in place of one swapped out.
    var canSwap: Bool { candidates.count > picks.count }

    // MARK: - Preparation

    func prepare() async {
        guard !preparationStarted else { return }
        preparationStarted = true
        defer { isPreparing = false }
        guard assets.count >= PhotoDumpPicker.countRange.lowerBound else {
            errorMessage = String(localized: "A photo dump needs at least \(PhotoDumpPicker.countRange.lowerBound) photos.")
            return
        }
        for asset in assets {
            takenAt[asset.id] = Self.date(asset.fileCreatedAt)
        }
        await look(at: Self.sample(assets))
        guard !Task.isCancelled else {
            preparationStarted = false
            return
        }
        guard candidates.count >= PhotoDumpPicker.countRange.lowerBound else {
            errorMessage = String(localized: "The photos could not be loaded.")
            return
        }
        picks = PhotoDumpPicker.pick(candidates, count: count, isDuplicate: isDuplicate)
        loadPreviews()
    }

    /// An even spread of `assets` in time, plus every favorite.
    static func sample(_ assets: [AssetReactItem]) -> [AssetReactItem] {
        let chronological = assets.sorted { $0.fileCreatedAt < $1.fileCreatedAt }
        let spread = Set(MosaicLayoutBuilder.spread(chronological, keeping: scoringSampleSize).map(\.id))
        return chronological.filter { spread.contains($0.id) || $0.isFavorite }
    }

    /// Looks at `sample` (`PhotoLooker`), keeping each photo's feature print.
    private func look(at sample: [AssetReactItem]) async {
        let found = await PhotoLooker.look(
            at: sample, baseURL: { baseURL }, token: token, session: session,
            progress: { preparationProgress = $0 }
        )
        for (candidate, print) in found {
            candidates.append(candidate)
            featurePrints[candidate.id] = print
        }
    }

    private func isDuplicate(_ a: DumpCandidate, _ b: DumpCandidate) -> Bool {
        PhotoLooker.isDuplicate(a, b, prints: featurePrints, dates: takenAt)
    }

    // MARK: - Editing

    /// Puts the next best photo of the same stretch of time in place of `id`.
    func swap(_ id: String) {
        guard let index = picks.firstIndex(where: { $0.id == id }),
              let next = PhotoDumpPicker.replacement(
                for: id, in: picks, candidates: candidates, excluded: excluded, isDuplicate: isDuplicate
              ) else { return }
        excluded.insert(id)
        picks[index] = next
        loadPreviews()
    }

    func makeCover(_ id: String) {
        guard let index = picks.firstIndex(where: { $0.id == id }), index > 0 else { return }
        picks.insert(picks.remove(at: index), at: 0)
    }

    /// Moves `id` to the place of `target` (a drag and drop in the grid).
    func move(_ id: String, to target: String) {
        guard id != target,
              let from = picks.firstIndex(where: { $0.id == id }),
              let to = picks.firstIndex(where: { $0.id == target }) else { return }
        picks.insert(picks.remove(at: from), at: to)
    }

    /// Moves `id` one place earlier (`-1`) or later (`1`): the VoiceOver
    /// actions standing for the drag.
    func move(_ id: String, by offset: Int) {
        guard let from = picks.firstIndex(where: { $0.id == id }), picks.indices.contains(from + offset) else { return }
        picks.swapAt(from, from + offset)
    }

    func remove(_ id: String) {
        guard picks.count > PhotoDumpPicker.countRange.lowerBound else { return }
        excluded.insert(id)
        picks.removeAll { $0.id == id }
        count = picks.count
    }

    // MARK: - Previews

    func preview(for candidate: DumpCandidate) -> UIImage? { previews[candidate.id] }

    /// The preview of `candidate` cropped to the dump's shape, around its
    /// subject, small enough for the grid. Kept per photo and shape: the grid
    /// redraws far more often than either changes.
    func croppedPreview(for candidate: DumpCandidate) -> UIImage? {
        guard let image = previews[candidate.id] else { return nil }
        guard let ratio = aspect.ratio else { return image }
        let key = "\(candidate.id)|\(aspect.rawValue)"
        if let cached = croppedCache[key] { return cached }
        let cropped = Self.crop(image, ratio: ratio, focus: candidate.focus, width: 480)
        croppedCache[key] = cropped
        return cropped
    }

    @ObservationIgnored private var croppedCache: [String: UIImage] = [:]

    /// Loads the previews of the photos in the dump that are not in yet.
    private func loadPreviews() {
        let needed = picks.map(\.asset).filter { previews[$0.id] == nil }
        guard !needed.isEmpty else { return }
        let session = self.session
        let tok = token
        let base = baseURL
        previewTask = Task { [weak self] in
            await withTaskGroup(of: (String, UIImage?).self) { group in
                for asset in needed {
                    group.addTask {
                        let url = ImmichAssetURL.thumbnail(
                            assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: base, size: .preview
                        )
                        guard let (data, _) = try? await AssetFileTransfer.fetchData(from: url, token: tok, session: session()),
                              let image = UIImage(data: data) else { return (asset.id, nil) }
                        return (asset.id, image.preparingForDisplay() ?? image)
                    }
                }
                for await (id, image) in group {
                    if let image { self?.previews[id] = image }
                }
            }
        }
    }

    /// `image` cropped to `ratio` around `focus`, drawn `width` pixels wide
    /// (its own scale when nil).
    nonisolated static func crop(_ image: UIImage, ratio: Double, focus: CGPoint, width: CGFloat?) -> UIImage {
        let rect = PhotoDumpPicker.cropRect(imageSize: image.size, ratio: ratio, focus: focus)
        let scale = (width ?? rect.width) / rect.width
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(
                x: -rect.minX * scale, y: -rect.minY * scale,
                width: image.size.width * scale, height: image.size.height * scale
            ))
        }
    }

    // MARK: - Export

    /// Saves the dump to the photo library in carousel order — every photo
    /// cropped to the dump's shape, 1080 pixels wide — and keeps the files
    /// for the share sheet.
    func export() {
        guard exportState != .rendering, !picks.isEmpty else { return }
        let missing = picks.filter { previews[$0.id] == nil }
        guard missing.isEmpty else {
            exportState = .failed(String(localized: "Some photos are still loading. Try again in a moment."))
            return
        }
        exportState = .rendering
        let items = picks.compactMap { pick in previews[pick.id].map { (pick, $0) } }
        let ratio = aspect.ratio
        let photos = photos
        Task {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Swimmich Photo Dump \(UUID().uuidString.prefix(8))", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var urls: [URL] = []
                for (index, (pick, image)) in items.enumerated() {
                    let data = await Task.detached(priority: .userInitiated) {
                        let output = ratio.map { Self.crop(image, ratio: $0, focus: pick.focus, width: Self.exportWidth) } ?? image
                        return output.jpegData(compressionQuality: 0.92)
                    }.value
                    guard let data else { throw CocoaError(.fileWriteUnknown) }
                    // One after the other: the library keeps the carousel's order.
                    _ = try await photos.saveImage(data: data)
                    let url = folder.appendingPathComponent(String(format: "%02d.jpg", index + 1))
                    try data.write(to: url)
                    urls.append(url)
                }
                discardExport()
                exportedURLs = urls
                exportState = .done
            } catch {
                try? FileManager.default.removeItem(at: folder)
                exportState = .failed(error.userFacingMessage ?? error.localizedDescription)
            }
        }
    }

    func dismissExportResult() {
        exportState = .idle
    }

    func cancel() {
        previewTask?.cancel()
        discardExport()
    }

    private func discardExport() {
        if let folder = exportedURLs.first?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: folder)
        }
        exportedURLs = []
    }

    // MARK: - Dates

    private nonisolated static let fractionalParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    private nonisolated static let plainParser = ISO8601DateFormatter()

    /// An Immich timestamp, with or without milliseconds. Pure: callable from anywhere.
    nonisolated static func date(_ wire: String) -> Date? {
        fractionalParser.date(from: wire) ?? plainParser.date(from: wire)
    }
}
