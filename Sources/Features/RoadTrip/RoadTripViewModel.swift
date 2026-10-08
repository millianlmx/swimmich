import Foundation
import CoreLocation
import MapKit
import UIKit

/// Road-trip feature orchestration. Fetches the album's photos WITH EXIF
/// (latitude/longitude/city drive the clustering and the map legs), clusters
/// them, builds the deterministic timeline (straight-line travel legs
/// immediately, upgraded to real MKDirections routes in the background), and
/// drives the video export.
@MainActor
@Observable
final class RoadTripViewModel {

    let client: any ImmichClient
    let albumId: String
    let albumTitle: String
    let baseURL: URL
    let token: String?
    private let photos: PhotoLibraryService

    /// Optional id filter (selection mode); nil = the whole album.
    private let selectedAssetIds: Set<String>?

    private(set) var clusters: [RoadTripCluster] = []
    private(set) var legs: [RoadTripLeg] = []
    private(set) var timeline: RoadTripTimeline?
    private(set) var isPreparing = true
    private(set) var errorMessage: String?

    // MARK: - Export state

    enum ExportState: Equatable {
        case idle
        case rendering(Double)
        case saving
        case done
        case failed(String)
    }

    private(set) var exportState: ExportState = .idle
    private(set) var isExporting = false

    private var routeTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var lastReportedProgress = 0.0
    /// Quality score per asset id (computed during preflight) — drives the
    /// "best of the trip" photo selection.
    private var assetScores: [String: Double] = [:]

    init(
        client: any ImmichClient,
        albumId: String,
        selectedAssetIds: Set<String>?,
        albumTitle: String,
        baseURL: URL,
        token: String?,
        photos: PhotoLibraryService
    ) {
        self.client = client
        self.albumId = albumId
        self.selectedAssetIds = selectedAssetIds
        self.albumTitle = albumTitle
        self.baseURL = baseURL
        self.token = token
        self.photos = photos
    }

    // MARK: - Preparation

    /// Fetches album assets WITH `withExif: true` (search omits exifInfo
    /// otherwise, so latitude/longitude would be nil → no map legs), clusters
    /// off the main thread, and builds the timeline so playback can start
    /// immediately. Real driving routes are fetched in the background.
    func prepare() async {
        isPreparing = true

        var assets: [AssetReactItem] = []
        do {
            let dto = MetadataSearchDto(albumIds: [albumId], size: 1000, withExif: true)
            let response = try await client.searchMetadata(dto: dto)
            assets = response.assets.items.map(AssetReactItem.init(from:))
        } catch {
            errorMessage = error.userFacingMessage
            isPreparing = false
            return
        }

        if let selectedAssetIds, !selectedAssetIds.isEmpty {
            assets = assets.filter { selectedAssetIds.contains($0.id) }
        }
        guard !assets.isEmpty else {
            errorMessage = String(localized: "No photos in this selection.")
            isPreparing = false
            return
        }

        let clustered = await Task.detached(priority: .userInitiated) {
            RoadTripClusterer.cluster(assets)
        }.value
        clusters = clustered
        rebuildTimeline()
        await preflightAssets()

        // Warm the 3D car sprite sheet off the main thread BEFORE playback so
        // the map leg never blocks on its first appearance.
        await Task.detached(priority: .userInitiated) { RoadTripCar3D.warm() }.value

        errorMessage = nil
        isPreparing = false

        // Non-blocking upgrade: real driving routes replace the straight-line
        // legs once resolved; the map already animates on the fallback legs.
        routeTask = Task { await fetchRoutes() }
    }

    func cluster(by id: String) -> RoadTripCluster? {
        clusters.first { $0.id == id }
    }

    /// "Paris, France" or a "Stop N" fallback (stable, localized).
    func placeName(forClusterIndex index: Int) -> String {
        guard clusters.indices.contains(index) else { return "" }
        if let name = clusters[index].placeName, !name.isEmpty {
            return name
        }
        return String(localized: "Stop \(index + 1)")
    }

    func placeName(forClusterID id: String) -> String {
        guard let index = clusters.firstIndex(where: { $0.id == id }) else { return "" }
        return placeName(forClusterIndex: index)
    }

    // MARK: - Timeline + routes

    /// Validates the thumbnails of the photos the timeline actually shows,
    /// dropping the ones that fail to load/decode so neither the player nor the
    /// export renders dead frames. Warms `ImageCache` so the live player hits
    /// memory instead of refetching.
    private func preflightAssets() async {
        guard let timeline, !clusters.isEmpty else { return }

        var needed: [AssetReactItem] = []
        var seen = Set<String>()
        for segment in timeline.segments {
            guard case .slideshow(let slideshow) = segment,
                  let cluster = clusters.first(where: { $0.id == slideshow.clusterID }) else { continue }
            for index in slideshow.assetIndices where cluster.assets.indices.contains(index) {
                let asset = cluster.assets[index]
                if seen.insert(asset.id).inserted {
                    needed.append(asset)
                }
            }
        }
        guard !needed.isEmpty else { return }

        let validIDs = await validAssetIDs(needed)
        guard !validIDs.isEmpty else {
            errorMessage = String(localized: "No displayable photos.")
            return
        }

        let filtered = clusters.map { cluster in
            RoadTripCluster(
                id: cluster.id,
                assets: cluster.assets.filter { validIDs.contains($0.id) },
                latitude: cluster.latitude,
                longitude: cluster.longitude,
                placeName: cluster.placeName,
                startDate: cluster.startDate,
                endDate: cluster.endDate
            )
        }.filter { !$0.assets.isEmpty }

        clusters = filtered
        rebuildTimeline()
    }

    private func validAssetIDs(_ assets: [AssetReactItem]) async -> Set<String> {
        let session = URLSession(configuration: .default)
        let base = baseURL
        let tok = token
        var valid = Set<String>()
        let chunkSize = 8
        var offset = 0
        while offset < assets.count {
            if Task.isCancelled { break }
            let chunk = Array(assets[offset..<min(offset + chunkSize, assets.count)])
            let results = await withTaskGroup(of: (String, UIImage?, Double?).self) { group in
                for asset in chunk {
                    group.addTask {
                        await Self.loadThumbnail(asset, baseURL: base, token: tok, session: session)
                    }
                }
                var out: [(String, UIImage?, Double?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (id, image, score) in results {
                guard let image else { continue }
                valid.insert(id)
                if let score {
                    assetScores[id] = score
                }
                let asset = assets.first { $0.id == id }
                let url = ImmichAssetURL.thumbnail(assetId: id, thumbhash: asset?.thumbhash ?? "", baseURL: base, size: .preview)
                await ImageCache.shared.store(image, for: url)
            }
            offset += chunkSize
        }
        return valid
    }

    private nonisolated static func loadThumbnail(
        _ asset: AssetReactItem,
        baseURL: URL,
        token: String?,
        session: URLSession
    ) async -> (String, UIImage?, Double?) {
        let url = ImmichAssetURL.thumbnail(assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: baseURL, size: .preview)
        do {
            let (data, _) = try await AssetFileTransfer.fetchData(from: url, token: token, session: session)
            guard let image = UIImage(data: data) else { return (asset.id, nil, nil) }
            let score = image.cgImage.map { RoadTripPhotoScore.score($0) }
            return (asset.id, image, score)
        } catch {
            return (asset.id, nil, nil)
        }
    }

    private func rebuildTimeline() {
        guard !clusters.isEmpty else {
            timeline = nil
            legs = []
            return
        }
        var built: [RoadTripLeg] = []
        for i in 0..<(clusters.count - 1) {
            guard let from = clusters[i].coordinate, let to = clusters[i + 1].coordinate else { continue }
            let distance = RoadTripClusterer.haversine(from, to)
            built.append(RoadTripLeg(
                fromClusterID: clusters[i].id,
                toClusterID: clusters[i + 1].id,
                distanceMeters: distance,
                route: [
                    RoutePoint(latitude: from.latitude, longitude: from.longitude),
                    RoutePoint(latitude: to.latitude, longitude: to.longitude)
                ]
            ))
        }
        legs = built
        timeline = RoadTripTimelineBuilder.build(clusters: clusters, legs: built, scores: assetScores)
    }

    /// Sequential MKDirections calls; straight-line legs are kept on failure or
    /// cancellation, so the map never waits for the network.
    private func fetchRoutes() async {
        guard !legs.isEmpty else { return }
        var updated = legs
        for i in updated.indices {
            if Task.isCancelled { return }
            let leg = updated[i]
            guard leg.route.count >= 2 else { continue }
            if let route = await fetchRoute(from: leg.route[0], to: leg.route[1]) {
                updated[i] = RoadTripLeg(
                    fromClusterID: leg.fromClusterID,
                    toClusterID: leg.toClusterID,
                    distanceMeters: leg.distanceMeters,
                    route: route
                )
            }
        }
        guard !Task.isCancelled else { return }
        legs = updated
        timeline = RoadTripTimelineBuilder.build(clusters: clusters, legs: updated, scores: assetScores)
    }

    private func fetchRoute(from: RoutePoint, to: RoutePoint) async -> [RoutePoint]? {
        let request = MKDirections.Request()
        request.transportType = .automobile
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let polyline = response.routes.first?.polyline, polyline.pointCount >= 2 else { return nil }
            return densified(simplified(polyline))
        } catch {
            return nil
        }
    }

    private func simplified(_ polyline: MKPolyline) -> [RoutePoint] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        let points = polyline.points()
        let turnThreshold = 3.0 * Double.pi / 180.0
        let maxGapMeters = 200.0

        var result: [RoutePoint] = []
        var last = points[0].coordinate
        result.append(RoutePoint(latitude: last.latitude, longitude: last.longitude))
        var lastBearing: Double?
        var accumulatedTurn = 0.0

        for i in 1..<(count - 1) {
            let c = points[i].coordinate
            let bearingNow = Self.bearing(from: last, to: c)
            if let previous = lastBearing {
                var delta = abs(bearingNow - previous)
                if delta > .pi { delta = 2 * .pi - delta }
                accumulatedTurn += delta
            }
            lastBearing = bearingNow
            let gap = RoadTripClusterer.haversine(last, c)
            if accumulatedTurn >= turnThreshold || gap >= maxGapMeters {
                result.append(RoutePoint(latitude: c.latitude, longitude: c.longitude))
                last = c
                accumulatedTurn = 0
                lastBearing = nil
            }
        }

        let final = points[count - 1].coordinate
        if result.last?.latitude != final.latitude || result.last?.longitude != final.longitude {
            result.append(RoutePoint(latitude: final.latitude, longitude: final.longitude))
        }
        return result
    }

    /// Initial compass bearing (radians, north = 0, clockwise) a→b.
    private static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x)
    }

    /// Densifies a leg's route to ~40 m spacing so the car glides smoothly:
    /// the timing, camera and heading math all interpolate between consecutive
    /// route points, so coarse points make the car snap at every vertex.
    private func densified(_ route: [RoutePoint]) -> [RoutePoint] {
        guard route.count >= 2 else { return route }
        let cumulative = RoadTripTravelTiming.cumulativeLengths(route)
        let total = cumulative.last ?? 0
        let fractions = cumulative.map { total > 0 ? $0 / total : 0 }
        return RoadTripDriveCamera.densified(route: route, fractions: fractions, spacing: 40).points
    }

    // MARK: - Export

    func startExport(reduceMotion: Bool) {
        guard !isExporting, let timeline, !clusters.isEmpty else { return }
        isExporting = true
        lastReportedProgress = 0
        exportState = .rendering(0)

        let config = RoadTripRenderConfig(
            size: CGSize(width: 1080, height: 1920),
            fps: 30,
            baseURL: baseURL,
            token: token,
            albumTitle: albumTitle,
            reduceMotion: reduceMotion
        )
        let renderer = RoadTripVideoRenderer()
        let clusters = self.clusters
        let photos = self.photos

        renderTask = Task { [weak self] in
            do {
                let url = try await renderer.render(clusters: clusters, timeline: timeline, config: config) { progress in
                    Task { @MainActor [weak self] in self?.reportProgress(progress) }
                }
                guard let self else { return }
                self.exportState = .saving
                _ = try await photos.saveVideo(at: url)
                try? FileManager.default.removeItem(at: url)
                self.exportState = .done
                self.isExporting = false
            } catch is CancellationError {
                guard let self else { return }
                self.exportState = .idle
                self.isExporting = false
            } catch {
                guard let self else { return }
                self.isExporting = false
                if let message = error.userFacingMessage {
                    self.exportState = .failed(message)
                } else {
                    // Cancellation: no event, the export simply stops (SP-1).
                    self.exportState = .idle
                }
            }
        }
    }

    func cancelExport() {
        renderTask?.cancel()
        renderTask = nil
    }

    func dismissExportResult() {
        exportState = .idle
    }

    private func reportProgress(_ progress: Double) {
        // Throttle to 1% steps so the progress UI never churns per-frame.
        guard progress - lastReportedProgress >= 0.01 || progress >= 1 else { return }
        lastReportedProgress = progress
        exportState = .rendering(progress)
    }
}

/// Deterministic photo quality scoring for the "best of the trip" selection:
/// sharpness (Laplacian variance), exposure balance, and colorfulness on a
/// small downsampled sample. Favorites are ranked first by the builder.
enum RoadTripPhotoScore {

    static func score(_ image: CGImage) -> Double {
        guard let small = downsample(image, maxDimension: 48) else { return 0.5 }
        let w = small.width, h = small.height
        guard w > 2, h > 2,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return 0.5 }
        ctx.interpolationQuality = .medium
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0.5 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        var lum = [Double](repeating: 0, count: w * h)
        var meanL = 0.0, meanR = 0.0, meanG = 0.0, meanB = 0.0
        for i in 0..<(w * h) {
            let r = Double(bytes[i * 4]) / 255
            let g = Double(bytes[i * 4 + 1]) / 255
            let b = Double(bytes[i * 4 + 2]) / 255
            lum[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            meanL += lum[i]; meanR += r; meanG += g; meanB += b
        }
        let n = Double(w * h)
        meanL /= n; meanR /= n; meanG /= n; meanB /= n

        // Sharpness: mean |Laplacian| of the luminance field.
        var sharp = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = 4 * lum[i] - lum[i - 1] - lum[i + 1] - lum[i - w] - lum[i + w]
                sharp += abs(lap)
            }
        }
        sharp /= Double((w - 2) * (h - 2))

        // Exposure: closeness of mean luminance to a pleasing mid-tone.
        let exposure = 1.0 - min(abs(meanL - 0.55) / 0.55, 1.0)
        // Colorfulness: mean channel deviation from luminance.
        let color = min((abs(meanR - meanL) + abs(meanG - meanL) + abs(meanB - meanL)) / 0.45, 1.0)

        return min(sharp / 0.18, 1.0) * 0.5 + exposure * 0.25 + color * 0.25
    }

    private static func downsample(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let scale = min(1.0, Double(maxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
