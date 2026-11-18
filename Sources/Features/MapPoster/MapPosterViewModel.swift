import Foundation
import MapKit
import UIKit

/// "Everywhere I've been": every geotagged photo of the library (the map
/// markers — one request, no photo downloaded) on a dark map, with the
/// numbers they add up to, as a poster to save and share. All time, this
/// year or last year.
@MainActor
@Observable
final class MapPosterViewModel: Identifiable {

    enum ExportState: Equatable {
        case idle
        case saving
        case done
        case failed(String)
    }

    private let client: any ImmichClient
    private let photos: PhotoLibraryService

    var scope: MapPosterScope = .allTime { didSet { if scope != oldValue { Task { await load() } } } }
    var format: MosaicFormat = .story { didSet { if format != oldValue { Task { await redraw() } } } }
    var showsCredit = true { didSet { if showsCredit != oldValue { Task { await redraw() } } } }

    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var stats: MapPosterStats?
    private(set) var poster: UIImage?
    private var markers: [MapPhoto] = []
    /// The map drawn for the current markers and format, kept while only the
    /// credit changes.
    private var snapshot: (key: String, snapshot: MKMapSnapshotter.Snapshot)?
    private var generation = 0

    private(set) var exportState: ExportState = .idle
    private(set) var exportedImageURL: URL?

    init(client: any ImmichClient, photos: PhotoLibraryService) {
        self.client = client
        self.photos = photos
    }

    var title: String {
        if let year = scope.year() { return String(localized: "My \(String(year)) on the map") }
        return String(localized: "Everywhere I’ve been")
    }

    // MARK: - Loading

    func load() async {
        generation += 1
        let current = generation
        isLoading = true
        errorMessage = nil
        defer { if current == generation { isLoading = false } }
        do {
            let response = try await client.getMapMarkers(filter: scope.filter())
            guard current == generation else { return }
            markers = response.map(MapPhoto.init(from:))
        } catch {
            guard current == generation else { return }
            errorMessage = error.userFacingMessage ?? String(localized: "The map could not be loaded.")
            return
        }
        guard !markers.isEmpty else {
            stats = nil
            poster = nil
            errorMessage = String(localized: "No photo with a location for this period.")
            return
        }
        stats = MapPosterStats.make(markers)
        snapshot = nil
        await redraw()
    }

    /// Draws the poster again: the map is taken once per set of places and
    /// format, the rest is drawn over it.
    private func redraw() async {
        guard let stats, !markers.isEmpty else { return }
        let current = generation
        let frame = MapPosterRenderer.mapFrame(format: format)
        let key = "\(generation)|\(format.rawValue)"
        if snapshot?.key != key {
            let rect = MapPosterRenderer.mapRect(for: markers.map(\.coordinate), aspect: frame.width / frame.height)
            let shot = try? await MapPosterRenderer.snapshot(of: rect, size: frame.size)
            guard current == generation else { return }
            snapshot = shot.map { (key, $0) }
        }
        let subtitle = String(localized: "\(stats.photoCount) photos")
        poster = MapPosterRenderer.render(
            markers: markers, stats: stats, snapshot: snapshot?.snapshot, format: format,
            title: title, subtitle: subtitle, showsCredit: showsCredit
        )
    }

    // MARK: - Export

    func export() {
        guard exportState != .saving, let poster, let data = poster.jpegData(compressionQuality: 0.92) else { return }
        exportState = .saving
        let photos = photos
        Task {
            do {
                _ = try await photos.saveImage(data: data)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Swimmich Map \(UUID().uuidString.prefix(8)).jpg")
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
