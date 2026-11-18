import Foundation
import UIKit

/// Color-mosaic orchestration. The photos' colors come from their thumbhashes,
/// so the mosaic is laid out at once, before any download; the thumbnails of
/// the photos it shows then load in the background, each cell going from its
/// color to its photo. The export draws the same layout (`MosaicRenderer`).
@MainActor
@Observable
final class ColorMosaicViewModel: Identifiable {

    enum ExportState: Equatable {
        case idle
        case rendering
        case done
        case failed(String)
    }

    let token: String?
    /// The address in use, read at every use (L-26).
    var baseURL: URL { baseURLProvider() }
    private let baseURLProvider: @Sendable () -> URL
    private let photos: PhotoLibraryService
    private let session: @Sendable () -> URLSession

    /// The photos with a color, i.e. a thumbhash; a photo without one cannot
    /// be placed and is left out.
    let tiles: [MosaicTile]

    var format: MosaicFormat = .story { didSet { if format != oldValue { relayout() } } }
    var arrangement: MosaicArrangement = .rainbow { didSet { if arrangement != oldValue { relayout() } } }
    var showsCredit = true

    private(set) var layout: MosaicLayout?
    /// Loaded thumbnails, by asset id.
    private(set) var images: [String: UIImage] = [:]
    /// Ids whose image is the large preview (cells wider than a thumbnail).
    private var previewIDs = Set<String>()
    private var loadTask: Task<Void, Never>?

    private(set) var exportState: ExportState = .idle
    /// The exported picture, kept once it is in the photo library so the
    /// screen can hand it to the share sheet.
    private(set) var exportedImageURL: URL?

    init(
        assets: [AssetReactItem],
        baseURL: @escaping @Sendable () -> URL,
        token: String?,
        photos: PhotoLibraryService,
        session: @escaping @Sendable () -> URLSession
    ) {
        self.baseURLProvider = baseURL
        self.token = token
        self.photos = photos
        self.session = session
        self.tiles = assets.compactMap { asset in
            MosaicColor(thumbhash: asset.thumbhash).map { MosaicTile(asset: asset, color: $0) }
        }
        relayout()
    }

    /// Photos the current format needs at least, when there are fewer.
    var missingPhotosMessage: String? {
        guard layout == nil else { return nil }
        let needed = MosaicLayoutBuilder.minimumCount(format: format)
        return String(localized: "A mosaic needs at least \(needed) photos.")
    }

    /// Share of the shown photos whose thumbnail is in.
    var loadedFraction: Double {
        guard let layout, !layout.cells.isEmpty else { return 0 }
        return Double(layout.cells.filter { images[$0.id] != nil }.count) / Double(layout.cells.count)
    }

    func image(for tile: MosaicTile) -> UIImage? { images[tile.id] }

    func cancel() {
        loadTask?.cancel()
        discardExportedImage()
    }

    // MARK: - Layout and loading

    private func relayout() {
        layout = MosaicLayoutBuilder.build(tiles: tiles, format: format, arrangement: arrangement)
        loadTask?.cancel()
        guard let layout else { return }
        // A cell wider than the server's thumbnail (250 px) shows the preview.
        let size: AssetMediaSize = format.pixelSize.width / CGFloat(layout.columns) > 250 ? .preview : .thumbnail
        let needed = layout.cells.filter { tile in
            images[tile.id] == nil || (size == .preview && !previewIDs.contains(tile.id))
        }.map(\.asset)
        loadTask = Task { await load(needed, size: size) }
    }

    /// Downloads `assets` in batches of 8, the address read per batch (L-26).
    /// A photo that does not load keeps its color.
    private func load(_ assets: [AssetReactItem], size: AssetMediaSize) async {
        let session = self.session
        let tok = token
        let chunkSize = 8
        var offset = 0
        while offset < assets.count {
            if Task.isCancelled { return }
            let base = baseURL
            let chunk = Array(assets[offset..<min(offset + chunkSize, assets.count)])
            let results = await withTaskGroup(of: (String, UIImage?).self) { group in
                for asset in chunk {
                    group.addTask {
                        let url = ImmichAssetURL.thumbnail(
                            assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: base, size: size
                        )
                        guard let (data, _) = try? await AssetFileTransfer.fetchData(from: url, token: tok, session: session()),
                              let image = UIImage(data: data) else { return (asset.id, nil) }
                        return (asset.id, image.preparingForDisplay() ?? image)
                    }
                }
                var out: [(String, UIImage?)] = []
                for await result in group { out.append(result) }
                return out
            }
            if Task.isCancelled { return }
            for (id, image) in results {
                guard let image else { continue }
                images[id] = image
                if size == .preview { previewIDs.insert(id) }
            }
            offset += chunkSize
        }
    }

    // MARK: - Export

    /// Draws the mosaic at full size, saves it to the photo library and keeps
    /// a copy for the share sheet. Photos still loading are drawn as colors.
    func export() {
        guard exportState != .rendering, let layout else { return }
        exportState = .rendering
        let format = format
        let images = images
        let showsCredit = showsCredit
        let photos = photos
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                MosaicRenderer.render(layout: layout, format: format, images: images, showsCredit: showsCredit)
                    .jpegData(compressionQuality: 0.92)
            }.value
            guard let data else {
                exportState = .failed(String(localized: "The mosaic could not be drawn."))
                return
            }
            do {
                _ = try await photos.saveImage(data: data)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Swimmich Mosaic \(UUID().uuidString.prefix(8)).jpg")
                try data.write(to: url)
                discardExportedImage()
                exportedImageURL = url
                exportState = .done
            } catch {
                exportState = .failed(error.userFacingMessage ?? error.localizedDescription)
            }
        }
    }

    func dismissExportResult() {
        exportState = .idle
    }

    func discardExportedImage() {
        if let exportedImageURL { try? FileManager.default.removeItem(at: exportedImageURL) }
        exportedImageURL = nil
    }
}
