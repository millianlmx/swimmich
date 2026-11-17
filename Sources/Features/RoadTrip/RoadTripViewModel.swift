import Foundation
import CoreLocation
import MapKit
import UIKit

/// Road-trip feature orchestration. Fetches the album's photos WITH EXIF
/// (latitude/longitude/city drive the clustering and the map legs), clusters
/// them, loads the photos the film shows and the real driving routes, then
/// builds the deterministic timeline ONCE — the player and the export both play
/// that one timeline, which never changes once it is up — and drives the video
/// export.
@MainActor
@Observable
final class RoadTripViewModel {

    /// How long the preparation waits for the driving routes (MKDirections). A
    /// leg whose route has not arrived by then keeps its straight line: the
    /// routes are resolved BEFORE playback, because swapping them in later
    /// rebuilt the timeline under the playing film (new leg durations moved
    /// every later segment, and the leg on screen jumped to another geometry).
    static let routeDeadline: Duration = .seconds(8)

    let client: any ImmichClient
    let albumId: String
    let albumTitle: String
    /// The address in use, read at every use (L-26): a switch of address during a
    /// road trip moves the thumbnails to the new one.
    var baseURL: URL { baseURLProvider() }
    private let baseURLProvider: @Sendable () -> URL
    let token: String?
    private let photos: PhotoLibraryService

    /// Optional id filter (selection mode); nil = the whole album.
    private let selectedAssetIds: Set<String>?

    private(set) var clusters: [RoadTripCluster] = []
    private(set) var legs: [RoadTripLeg] = []
    private(set) var timeline: RoadTripTimeline?
    private(set) var isPreparing = true
    private(set) var errorMessage: String?
    /// The decoded previews of the photos the film shows (asset id → image),
    /// loaded once by the preparation. The player draws them directly: an
    /// asynchronous loader per slide cleared its image at every cut and showed
    /// a shimmering placeholder for a few frames, so each photo change, each
    /// crossfade and each arrival dive flashed gray.
    private(set) var slideImages: [String: UIImage] = [:]
    /// `prepare()` runs once per player: a second `.task` (the view appearing
    /// again) must not refetch and rebuild the film under the playback.
    private var preparationStarted = false

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
    /// The exported film, kept once it is in the photo library so the player
    /// can hand it to the share sheet; removed when the result is dismissed.
    private(set) var exportedVideoURL: URL?

    private var renderTask: Task<Void, Never>?
    private var lastReportedProgress = 0.0
    /// Quality score per asset id (computed during preflight) — drives the
    /// "best of the trip" photo selection.
    private var assetScores: [String: Double] = [:]
    /// The process-wide road-trip session (`ServerSessions.roadTrip`): thumbnail
    /// pre-selection here and image preloading in the renderer share it.
    private let session: @Sendable () -> URLSession

    init(
        client: any ImmichClient,
        albumId: String,
        selectedAssetIds: Set<String>?,
        albumTitle: String,
        baseURL: @escaping @Sendable () -> URL,
        token: String?,
        photos: PhotoLibraryService,
        session: @escaping @Sendable () -> URLSession
    ) {
        self.client = client
        self.albumId = albumId
        self.selectedAssetIds = selectedAssetIds
        self.albumTitle = albumTitle
        self.baseURLProvider = baseURL
        self.token = token
        self.photos = photos
        self.session = session
    }

    // MARK: - Preparation

    /// Fetches album assets WITH `withExif: true` (search omits exifInfo
    /// otherwise, so latitude/longitude would be nil → no map legs), clusters
    /// off the main thread, then — concurrently — loads the photos the film
    /// shows, resolves the driving routes (bounded by `routeDeadline`) and warms
    /// the 3D car sprites. The timeline is built once, when all three are in.
    func prepare() async {
        guard !preparationStarted else { return }
        preparationStarted = true
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }

        var assets: [AssetReactItem] = []
        do {
            let dto = MetadataSearchDto(albumIds: [albumId], size: 1000, withExif: true)
            let response = try await client.searchMetadata(dto: dto)
            assets = response.assets.items.map(AssetReactItem.init(from:))
        } catch {
            // Cancelled (the player closed): a later appearance may start over.
            if Task.isCancelled { preparationStarted = false }
            errorMessage = error.userFacingMessage
            return
        }

        if let selectedAssetIds, !selectedAssetIds.isEmpty {
            assets = assets.filter { selectedAssetIds.contains($0.id) }
        }
        guard !assets.isEmpty else {
            errorMessage = String(localized: "No photos in this selection.")
            return
        }

        let clustered = await Task.detached(priority: .userInitiated) {
            RoadTripClusterer.cluster(assets)
        }.value
        let straight = Self.straightLegs(between: clustered)
        // The photos to load are those the straight-line film shows. A real
        // road only lengthens its leg, which leaves less time for photos, so
        // the final film shows a subset of them.
        guard let provisional = RoadTripTimelineBuilder.build(clusters: clustered, legs: straight) else {
            errorMessage = String(localized: "No displayable photos.")
            return
        }
        let candidates = Self.shownAssets(in: provisional, clusters: clustered)

        async let routed = resolveRoutes(straight)
        async let carWarmed: Void = Self.warmCar()
        let validIDs = await validAssetIDs(candidates)
        let resolvedLegs = await routed
        await carWarmed

        guard !Task.isCancelled else {
            preparationStarted = false
            return
        }
        guard !validIDs.isEmpty else {
            // Kept on screen: the film would otherwise play black frames.
            errorMessage = String(localized: "No displayable photos.")
            return
        }

        // Only the photos that loaded stay, so neither the player nor the
        // export draws a dead frame. A stop left without a photo disappears and
        // the legs around it are joined again (a straight line where no route
        // was resolved for the new pair).
        let kept: [RoadTripCluster] = clustered.compactMap { cluster in
            let loaded = cluster.assets.filter { validIDs.contains($0.id) }
            guard !loaded.isEmpty else { return nil }
            return RoadTripCluster(
                id: cluster.id,
                assets: loaded,
                latitude: cluster.latitude,
                longitude: cluster.longitude,
                placeName: cluster.placeName,
                startDate: cluster.startDate,
                endDate: cluster.endDate
            )
        }
        var routeByPair: [String: RoadTripLeg] = [:]
        for leg in resolvedLegs {
            routeByPair["\(leg.fromClusterID)>\(leg.toClusterID)"] = leg
        }
        let finalLegs = Self.straightLegs(between: kept).map { leg in
            routeByPair["\(leg.fromClusterID)>\(leg.toClusterID)"] ?? leg
        }

        clusters = kept
        legs = finalLegs
        let built = RoadTripTimelineBuilder.build(clusters: kept, legs: finalLegs, scores: assetScores)
        timeline = built
        guard let built else {
            errorMessage = String(localized: "No displayable photos.")
            return
        }
        // Only the photos of the film stay in memory.
        let shown = Set(Self.shownAssets(in: built, clusters: kept).map(\.id))
        slideImages = slideImages.filter { shown.contains($0.key) }

        // The legs' smoothed rails, heading rails and speed profiles, computed
        // now and off the main actor: built on a leg's first frame they held
        // that frame back, in front of the moving car.
        let travels: [RoadTripTimeline.Travel] = built.segments.compactMap { segment in
            if case .travel(let travel) = segment { return travel }
            return nil
        }
        await Task.detached(priority: .userInitiated) {
            Self.warmLegGeometry(travels)
        }.value
    }

    /// Fills the geometry caches every frame of `travels` reads.
    nonisolated static func warmLegGeometry(_ travels: [RoadTripTimeline.Travel]) {
        for travel in travels {
            _ = RoadTripTravelTiming.frame(travel: travel, localTime: 0)
            _ = RoadTripAerialCamera.carHeading(travel: travel, localTime: 0)
        }
    }

    func cluster(by id: String) -> RoadTripCluster? {
        clusters.first { $0.id == id }
    }

    /// The trip's located stops, in film order: the pins of the map.
    var mapStops: [RoadTripMapStop] {
        RoadTripMapStop.stops(of: clusters)
    }

    /// The photo a stop opens on (its hero), shown on the ending's map.
    func heroImage(forClusterID id: String) -> UIImage? {
        guard let timeline, let cluster = cluster(by: id) else { return nil }
        for segment in timeline.segments {
            guard case .slideshow(let slideshow) = segment, slideshow.clusterID == id,
                  let first = slideshow.assetIndices.first, cluster.assets.indices.contains(first) else { continue }
            return slideImage(for: cluster.assets[first])
        }
        return nil
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

    /// The decoded preview of `asset` when the preparation loaded it.
    func slideImage(for asset: AssetReactItem) -> UIImage? {
        slideImages[asset.id]
    }

    // MARK: - Timeline + routes

    /// Straight-line legs between consecutive located stops (a stop without a
    /// location has no leg on either side).
    static func straightLegs(between clusters: [RoadTripCluster]) -> [RoadTripLeg] {
        guard clusters.count >= 2 else { return [] }
        var built: [RoadTripLeg] = []
        for i in 0..<(clusters.count - 1) {
            guard let from = clusters[i].coordinate, let to = clusters[i + 1].coordinate else { continue }
            built.append(RoadTripLeg(
                fromClusterID: clusters[i].id,
                toClusterID: clusters[i + 1].id,
                distanceMeters: RoadTripClusterer.haversine(from, to),
                route: [
                    RoutePoint(latitude: from.latitude, longitude: from.longitude),
                    RoutePoint(latitude: to.latitude, longitude: to.longitude)
                ]
            ))
        }
        return built
    }

    /// The assets the slideshows of `timeline` show, each once, in film order.
    static func shownAssets(in timeline: RoadTripTimeline, clusters: [RoadTripCluster]) -> [AssetReactItem] {
        var clusterByID: [String: RoadTripCluster] = [:]
        for cluster in clusters { clusterByID[cluster.id] = cluster }
        var seen = Set<String>()
        var result: [AssetReactItem] = []
        for segment in timeline.segments {
            guard case .slideshow(let slideshow) = segment,
                  let cluster = clusterByID[slideshow.clusterID] else { continue }
            for index in slideshow.assetIndices where cluster.assets.indices.contains(index) {
                let asset = cluster.assets[index]
                if seen.insert(asset.id).inserted {
                    result.append(asset)
                }
            }
        }
        return result
    }

    /// Renders the 3D car sprite sheets (SceneKit, a few seconds the first
    /// time) off the main actor, so the first map leg never blocks on them.
    private nonisolated static func warmCar() async {
        RoadTripCar3D.warm()
    }

    /// Loads the previews of `assets` (batches of 8, the address read per
    /// batch — L-26) and returns the ids that loaded and decoded. Each image is
    /// kept decoded in `slideImages` for the player and stored in `ImageCache`;
    /// its quality score feeds the "best of the trip" selection.
    func validAssetIDs(_ assets: [AssetReactItem]) async -> Set<String> {
        let session = self.session
        let tok = token
        var valid = Set<String>()
        let chunkSize = 8
        var offset = 0
        while offset < assets.count {
            if Task.isCancelled { break }
            // Read per batch (L-26): a switch of address moves the next batch.
            let base = baseURL
            let epoch = await ImageCache.shared.epoch
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
                slideImages[id] = image
                if let score {
                    assetScores[id] = score
                }
                let asset = assets.first { $0.id == id }
                let url = ImmichAssetURL.thumbnail(assetId: id, thumbhash: asset?.thumbhash ?? "", baseURL: base, size: .preview)
                await ImageCache.shared.store(image, for: url, epoch: epoch)
            }
            offset += chunkSize
        }
        return valid
    }

    private nonisolated static func loadThumbnail(
        _ asset: AssetReactItem,
        baseURL: URL,
        token: String?,
        session: @escaping @Sendable () -> URLSession
    ) async -> (String, UIImage?, Double?) {
        let url = ImmichAssetURL.thumbnail(assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: baseURL, size: .preview)
        do {
            let (data, _) = try await AssetFileTransfer.fetchData(from: url, token: token, session: session())
            guard let image = UIImage(data: data) else { return (asset.id, nil, nil) }
            let score = image.cgImage.map { RoadTripPhotoScore.score($0) }
            // Decoded here, off the main actor: the player draws it on the
            // frame of its cut without a decode hitch.
            return (asset.id, image.preparingForDisplay() ?? image, score)
        } catch {
            return (asset.id, nil, nil)
        }
    }

    private enum RouteOutcome {
        case route(Int, [RoutePoint]?)
        case deadline
    }

    /// The driving route of every straight leg, requested concurrently. Stops
    /// waiting at `routeDeadline`: a leg without its route by then (or whose
    /// request failed — no road, offline) keeps its straight line.
    private func resolveRoutes(_ straight: [RoadTripLeg]) async -> [RoadTripLeg] {
        var requests: [(index: Int, from: RoutePoint, to: RoutePoint)] = []
        for (index, leg) in straight.enumerated() {
            guard leg.route.count >= 2, let from = leg.route.first, let to = leg.route.last else { continue }
            requests.append((index, from, to))
        }
        guard !requests.isEmpty else { return straight }
        let deadline = Self.routeDeadline
        let found: [Int: [RoutePoint]] = await withTaskGroup(of: RouteOutcome.self) { group in
            for request in requests {
                group.addTask {
                    let route = await self.drivingRoute(from: request.from, to: request.to)
                    return RouteOutcome.route(request.index, route)
                }
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return RouteOutcome.deadline
            }
            var routes: [Int: [RoutePoint]] = [:]
            var pending = requests.count
            for await outcome in group {
                switch outcome {
                case .route(let index, let route):
                    if let route { routes[index] = route }
                    pending -= 1
                case .deadline:
                    pending = 0
                }
                if pending == 0 { break }
            }
            group.cancelAll()
            return routes
        }
        return straight.enumerated().map { index, leg in
            guard let route = found[index] else { return leg }
            return RoadTripLeg(
                fromClusterID: leg.fromClusterID,
                toClusterID: leg.toClusterID,
                distanceMeters: leg.distanceMeters,
                route: route
            )
        }
    }

    private func drivingRoute(from: RoutePoint, to: RoutePoint) async -> [RoutePoint]? {
        let request = MKDirections.Request()
        request.transportType = .automobile
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.coordinate))
        let directions = MKDirections(request: request)
        do {
            let response = try await withTaskCancellationHandler {
                try await directions.calculate()
            } onCancel: {
                Task { @MainActor in directions.cancel() }
            }
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
    /// Spacing grows past 40 m on very long routes so a leg never exceeds
    /// ~10 000 points: every frame of the player and the export walks them.
    private func densified(_ route: [RoutePoint]) -> [RoutePoint] {
        guard route.count >= 2 else { return route }
        let cumulative = RoadTripTravelTiming.cumulativeLengths(route)
        let total = cumulative.last ?? 0
        let fractions = cumulative.map { total > 0 ? $0 / total : 0 }
        let spacing = max(40, total / 10_000)
        return RoadTripDriveCamera.densified(route: route, fractions: fractions, spacing: spacing).points
    }

    // MARK: - Export

    func startExport(reduceMotion: Bool) {
        guard !isExporting, let timeline, !clusters.isEmpty else { return }
        isExporting = true
        lastReportedProgress = 0
        exportState = .rendering(0)

        let config = makeRenderConfig(reduceMotion: reduceMotion)
        let renderer = RoadTripVideoRenderer(session: session)
        let clusters = self.clusters
        let photos = self.photos
        // The previews the player already holds: the export does not download
        // them a second time.
        let preloaded = slideImages.compactMapValues(\.cgImage)

        renderTask = Task { [weak self] in
            do {
                let url = try await renderer.render(
                    clusters: clusters, timeline: timeline, config: config, preloaded: preloaded
                ) { progress in
                    Task { @MainActor [weak self] in self?.reportProgress(progress) }
                }
                guard let self else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.exportState = .saving
                do {
                    _ = try await photos.saveVideo(at: url)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                self.discardExportedVideo()
                self.exportedVideoURL = url
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

    /// The render keeps the address read here, at its start (L-26).
    func makeRenderConfig(reduceMotion: Bool) -> RoadTripRenderConfig {
        RoadTripRenderConfig(
            size: CGSize(width: 1080, height: 1920),
            fps: 30,
            baseURL: baseURL,
            token: token,
            albumTitle: albumTitle,
            reduceMotion: reduceMotion
        )
    }

    func cancelExport() {
        renderTask?.cancel()
        renderTask = nil
    }

    func dismissExportResult() {
        exportState = .idle
        discardExportedVideo()
    }

    /// Removes the exported film's temporary file (the photo library keeps
    /// its own copy).
    func discardExportedVideo() {
        guard let url = exportedVideoURL else { return }
        exportedVideoURL = nil
        try? FileManager.default.removeItem(at: url)
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
