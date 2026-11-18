import Foundation
import CoreLocation
import MapKit
import UIKit
import Vision

/// Road-trip feature orchestration. Fetches the album's photos WITH EXIF
/// (latitude/longitude/city drive the clustering and the map legs), clusters
/// them, loads the photos the film shows and the real driving routes, then
/// builds the deterministic timeline ONCE — the player and the export both play
/// that one timeline, which never changes under the playback; only the
/// person's settings (`apply`) rebuild it, the film starting over — and drives
/// the video export.
@MainActor
@Observable
final class RoadTripViewModel {

    /// How long the preparation waits for the driving routes (MKDirections)
    /// once its photos are in — the routes were asked for at its start. A
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
    /// The person's choices for this album's film, kept per album.
    private(set) var settings: RoadTripSettings
    private let settingsStore: RoadTripSettingsStore
    /// Every stop with all its photos (what the per-stop editor lists), before
    /// the photos left out and those that failed to load are taken away.
    private(set) var editableStops: [RoadTripCluster] = []
    /// Photos whose preview did not load: never in the film.
    private var unavailableIDs = Set<String>()
    /// The resolved driving route of each pair of stops ("from>to").
    private var routeByPair: [String: RoadTripLeg] = [:]
    /// The pairs of stops a route was asked for: a pair the film makes later
    /// (a stop between them left the film) is asked for then, once.
    private var requestedPairs = Set<String>()
    /// Stops already written down as lost (none of their photos loaded).
    private var loggedLostStops = Set<String>()
    /// Where a route that MapKit refused is written down (the app's log).
    private let appLog: any AppLogSink
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
    /// Width / height per asset id, as displayed (read on the scoring
    /// thumbnails) — the collage layouts fit their tiles to it.
    private var assetAspects: [String: Double] = [:]
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
        session: @escaping @Sendable () -> URLSession,
        appLog: any AppLogSink = NoopAppLogSink()
    ) {
        self.client = client
        self.albumId = albumId
        self.selectedAssetIds = selectedAssetIds
        self.albumTitle = albumTitle
        self.baseURLProvider = baseURL
        self.token = token
        self.photos = photos
        self.session = session
        self.appLog = appLog
        let store = RoadTripSettingsStore(albumId: albumId)
        self.settingsStore = store
        self.settings = store.load()
    }

    // MARK: - Preparation

    /// Fetches album assets WITH `withExif: true` (search omits exifInfo
    /// otherwise, so latitude/longitude would be nil → no map legs), clusters
    /// off the main thread, then — concurrently — loads the photos the film
    /// shows, resolves the driving routes (bounded by `routeDeadline`) and warms
    /// the 3D car sprites. The timeline is built when all three are in.
    func prepare() async {
        guard !preparationStarted else { return }
        preparationStarted = true
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }

        var assets: [AssetReactItem] = []
        var cameraless = Set<String>()
        do {
            let dto = MetadataSearchDto(albumIds: [albumId], size: 1000, withExif: true)
            let response = try await client.searchMetadata(dto: dto)
            assets = response.assets.items.map(AssetReactItem.init(from:))
            cameraless = Set(response.assets.items.filter { !Self.namesACamera($0.exifInfo) }.map(\.id))
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
        // Screenshots and images saved from apps (an Instagram story) carry
        // no camera in their EXIF: they are not the trip's photos, and their
        // location is where they were saved, not what they show. Kept only
        // when nothing else is left.
        let cameraPhotos = assets.filter { !cameraless.contains($0.id) }
        if !cameraPhotos.isEmpty { assets = cameraPhotos }

        let clustered = await Task.detached(priority: .userInitiated) {
            RoadTripClusterer.cluster(assets)
        }.value
        editableStops = clustered
        let straight = Self.straightLegs(between: clustered)
        // The routes only need the stops: they resolve while the photos are
        // scored and loaded.
        let routing = Task { await self.resolveRoutes(straight) }
        defer { routing.cancel() }
        async let carWarmed: Void = Self.warmCar(color: settings.carColor)

        // Every stop's photos are scored on small thumbnails BEFORE the film
        // picks its photos: picking first left each stop on its earliest shot
        // (a black night sky, a blurred tunnel), whatever came after it.
        await scoreAssets(Self.scoringSample(of: clustered))
        for asset in clustered.flatMap(\.assets) where assetScores[asset.id] == nil {
            // Beyond the sample: ranked after every photo that was looked at.
            assetScores[asset.id] = 0
        }

        // The photos the straight-line film shows load while the routes
        // resolve. A real road only lengthens its leg, which leaves less time
        // for photos, so the final film mostly shows a subset of them.
        let provisionalStops = filmStops()
        if let provisional = RoadTripTimelineBuilder.build(
            clusters: provisionalStops, legs: Self.straightLegs(between: provisionalStops),
            scores: assetScores, aspects: assetAspects, options: settings.builderOptions
        ) {
            let candidates = Self.shownAssets(in: provisional, clusters: provisionalStops)
            let validIDs = await validAssetIDs(candidates)
            unavailableIDs.formUnion(candidates.map(\.id).filter { !validIDs.contains($0) })
        }
        await carWarmed
        // The deadline runs from here, once the photos are in: the scoring
        // and the loading took long enough on a big trip that a route asked
        // for at the start missed a deadline running from the start.
        await Self.wait(for: routing, atMost: Self.routeDeadline)

        guard !Task.isCancelled else {
            preparationStarted = false
            return
        }
        await assemble()
        if Task.isCancelled && timeline == nil { preparationStarted = false }
    }

    /// Whether `exif` names a camera (make or model): not for a screenshot
    /// or an image saved from an app (an Instagram story, a WhatsApp photo).
    /// Without any EXIF, nothing is known: the photo counts as a camera's.
    nonisolated static func namesACamera(_ exif: ExifResponseDto?) -> Bool {
        guard let exif else { return true }
        return [exif.make, exif.model].contains { !($0?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
    }

    /// Waits for `task` at most `limit`, then cancels it (what it stored by
    /// then stays).
    private static func wait(for task: Task<Void, Never>, atMost limit: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            // Ends the routing too: the group waits for its `task.value`.
            task.cancel()
            group.cancelAll()
        }
    }

    /// Applies the person's new choices: the film is rebuilt from what the
    /// preparation gathered (scores, routes, loaded photos) — only photos it
    /// newly shows are downloaded.
    func apply(_ newSettings: RoadTripSettings) async {
        guard newSettings != settings, !isPreparing else { return }
        let paintChanged = newSettings.carColor != settings.carColor
        settings = newSettings
        settingsStore.save(newSettings)
        isPreparing = true
        defer { isPreparing = false }
        if paintChanged {
            await Self.warmCar(color: newSettings.carColor)
        }
        await assemble()
    }

    /// The stops as the film may show them: every stop's photos less those
    /// left out and those that failed to load; a stop left empty disappears.
    private func filmStops() -> [RoadTripCluster] {
        editableStops.compactMap { cluster in
            let assets = cluster.assets.filter { !unavailableIDs.contains($0.id) && !settings.excluded.contains($0.id) }
            guard !assets.isEmpty else { return nil }
            return RoadTripCluster(
                id: cluster.id,
                assets: assets,
                latitude: cluster.latitude,
                longitude: cluster.longitude,
                placeName: cluster.placeName,
                startDate: cluster.startDate,
                endDate: cluster.endDate
            )
        }
    }

    /// Builds the film from the stops, the routes and the settings, loads the
    /// photos it shows that are not loaded yet, and rebuilds without any that
    /// fail — neither the player nor the export draws a dead frame. A stop
    /// left without a photo disappears and the legs around it are joined
    /// again (a straight line where no route was resolved for the new pair).
    private func assemble() async {
        while !Task.isCancelled {
            let stops = filmStops()
            logLostStops(kept: stops)
            // Stops that are neighbours only now — one between them left the
            // film — get their road too: they were never asked for.
            let unrequested = Self.straightLegs(between: stops).filter {
                !requestedPairs.contains("\($0.fromClusterID)>\($0.toClusterID)")
            }
            if !unrequested.isEmpty {
                let routing = Task { await self.resolveRoutes(unrequested) }
                await Self.wait(for: routing, atMost: Self.routeDeadline)
            }
            let joined = Self.straightLegs(between: stops).map { leg in
                routeByPair["\(leg.fromClusterID)>\(leg.toClusterID)"] ?? leg
            }
            // One point per stop: where the car arrives. The pin, the arrival
            // dive and the ending's photo all sit on it, on the road.
            let anchored = RoadTripAnchoring.anchored(clusters: stops, legs: joined)
            guard let built = RoadTripTimelineBuilder.build(
                clusters: anchored.clusters, legs: anchored.legs,
                scores: assetScores, aspects: assetAspects, options: settings.builderOptions
            ) else {
                // Kept on screen: the film would otherwise play black frames.
                clusters = []
                legs = []
                timeline = nil
                slideImages = [:]
                errorMessage = String(localized: "No displayable photos.")
                return
            }
            let shownAssets = Self.shownAssets(in: built, clusters: anchored.clusters)
            let missing = shownAssets.filter { slideImages[$0.id] == nil }
            if !missing.isEmpty {
                let validIDs = await validAssetIDs(missing)
                let failed = missing.map(\.id).filter { !validIDs.contains($0) }
                if !failed.isEmpty {
                    unavailableIDs.formUnion(failed)
                    continue
                }
            }
            guard !Task.isCancelled else { return }

            clusters = anchored.clusters
            legs = anchored.legs
            timeline = built
            errorMessage = nil
            // Only the photos of the film stay in memory.
            let shown = Set(shownAssets.map(\.id))
            slideImages = slideImages.filter { shown.contains($0.key) }

            // The legs' smoothed rails, heading rails and speed profiles,
            // computed now and off the main actor: built on a leg's first
            // frame they held that frame back, in front of the moving car.
            let travels: [RoadTripTimeline.Travel] = built.segments.compactMap { segment in
                if case .travel(let travel) = segment { return travel }
                return nil
            }
            await Task.detached(priority: .userInitiated) {
                Self.warmLegGeometry(travels)
            }.value
            return
        }
    }

    /// The ids of the photos the film shows now.
    var shownAssetIDs: Set<String> {
        guard let timeline else { return [] }
        return Set(Self.shownAssets(in: timeline, clusters: clusters).map(\.id))
    }

    /// The small thumbnail of `asset` (the per-stop editor's grid).
    func thumbnailURL(for asset: AssetReactItem) -> URL {
        ImmichAssetURL.thumbnail(assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: baseURL, size: .thumbnail)
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
    private nonisolated static func warmCar(color: RoadTripSettings.CarColor) async {
        RoadTripCar3D.warm(color: color)
    }

    /// Loads the previews of `assets` (batches of 8, the address read per
    /// batch — L-26) and returns the ids that loaded and decoded. Each image is
    /// kept decoded in `slideImages` for the player and stored in `ImageCache`.
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
            let results = await withTaskGroup(of: (String, UIImage?).self) { group in
                for asset in chunk {
                    group.addTask {
                        await Self.loadThumbnail(asset, baseURL: base, token: tok, session: session)
                    }
                }
                var out: [(String, UIImage?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (id, image) in results {
                guard let image else { continue }
                valid.insert(id)
                slideImages[id] = image
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
    ) async -> (String, UIImage?) {
        let url = ImmichAssetURL.thumbnail(assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: baseURL, size: .preview)
        do {
            let (data, _) = try await AssetFileTransfer.fetchData(from: url, token: token, session: session())
            guard let image = UIImage(data: data) else { return (asset.id, nil) }
            // Decoded here, off the main actor: the player draws it on the
            // frame of its cut without a decode hitch.
            return (asset.id, image.preparingForDisplay() ?? image)
        } catch {
            return (asset.id, nil)
        }
    }

    // MARK: - Scoring

    /// Photos scored per stop at most, and over the whole trip: a stop's
    /// sample is spread evenly over its time, so a long stop is looked at
    /// from its first photo to its last.
    static let scoringSamplePerStop = 30
    static let scoringSampleTotal = 300

    /// The photos to score: every photo of a small stop, an even spread of a
    /// large one, and every favorite.
    static func scoringSample(of clusters: [RoadTripCluster]) -> [AssetReactItem] {
        guard !clusters.isEmpty else { return [] }
        let perStop = max(4, min(scoringSamplePerStop, scoringSampleTotal / clusters.count))
        var sample: [AssetReactItem] = []
        for cluster in clusters {
            let count = cluster.assets.count
            let picked = Set(RoadTripTimelineBuilder.selectedIndices(kept: perStop, count: count))
            for (index, asset) in cluster.assets.enumerated() where picked.contains(index) || asset.isFavorite {
                sample.append(asset)
            }
        }
        return sample
    }

    /// Downloads the small thumbnails of `assets` (batches of 8, the address
    /// read per batch — L-26) and scores them into `assetScores` (their shape
    /// into `assetAspects`), off the main actor. A photo whose thumbnail does
    /// not load keeps no score.
    func scoreAssets(_ assets: [AssetReactItem]) async {
        let session = self.session
        let tok = token
        let chunkSize = 8
        var offset = 0
        while offset < assets.count {
            if Task.isCancelled { break }
            let base = baseURL
            let chunk = Array(assets[offset..<min(offset + chunkSize, assets.count)])
            let results = await withTaskGroup(of: (String, Double, Double)?.self) { group in
                for asset in chunk {
                    group.addTask {
                        let url = ImmichAssetURL.thumbnail(
                            assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: base, size: .thumbnail
                        )
                        guard let (data, _) = try? await AssetFileTransfer.fetchData(from: url, token: tok, session: session()),
                              let image = UIImage(data: data), let pixels = image.cgImage,
                              image.size.height > 0 else { return nil }
                        let score = await RoadTripPhotoScore.score(pixels)
                        return (asset.id, score, Double(image.size.width / image.size.height))
                    }
                }
                var out: [(String, Double, Double)] = []
                for await result in group {
                    if let result { out.append(result) }
                }
                return out
            }
            for (id, score, aspect) in results {
                assetScores[id] = score
                assetAspects[id] = aspect
            }
            offset += chunkSize
        }
    }

    /// The driving route of every straight leg, requested concurrently, each
    /// stored in `routeByPair` as it arrives — the preparation stops waiting
    /// at its deadline and keeps what came. A route found once is read back
    /// from `RoadTripRouteCache` (instant, and immune to MapKit's throttling
    /// when the same trip is opened again); a failed request is retried.
    private func resolveRoutes(_ straight: [RoadTripLeg]) async {
        for leg in straight {
            requestedPairs.insert("\(leg.fromClusterID)>\(leg.toClusterID)")
        }
        await withTaskGroup(of: (RoadTripLeg, [RoutePoint]?, Error?).self) { group in
            for leg in straight {
                guard leg.route.count >= 2, let from = leg.route.first, let to = leg.route.last else { continue }
                group.addTask {
                    if let cached = RoadTripRouteCache.route(from: from, to: to) { return (leg, cached, nil) }
                    var lastError: Error?
                    for wait in Self.routeRetryWaits {
                        if Task.isCancelled { break }
                        if wait > .zero { try? await Task.sleep(for: wait) }
                        switch await self.drivingRoute(from: from, to: to) {
                        case .success(let route):
                            RoadTripRouteCache.store(route, from: from, to: to)
                            return (leg, route, nil)
                        case .failure(let error):
                            lastError = error
                        }
                    }
                    return (leg, nil, lastError)
                }
            }
            for await (leg, route, error) in group {
                guard let route else {
                    if let error, !Task.isCancelled { logRouteFailure(leg, error) }
                    continue
                }
                routeByPair["\(leg.fromClusterID)>\(leg.toClusterID)"] = RoadTripLeg(
                    fromClusterID: leg.fromClusterID,
                    toClusterID: leg.toClusterID,
                    distanceMeters: leg.distanceMeters,
                    route: route
                )
            }
        }
    }

    /// Before each try of a route: MapKit refuses a burst of requests now and
    /// then (throttling), and a straight line is the last resort.
    private nonisolated static let routeRetryWaits: [Duration] = [.zero, .seconds(1), .seconds(3)]

    /// Writes a refused route down in the app's log: the stops' names and
    /// MapKit's error — what a straight line on the map is down to.
    private func logRouteFailure(_ leg: RoadTripLeg, _ error: Error) {
        let ns = error as NSError
        let from = placeName(ofStop: leg.fromClusterID)
        let to = placeName(ofStop: leg.toClusterID)
        appLog.record(AppLogEntry(
            level: .warning, method: "MAPKIT", path: "MKDirections", category: "RoadTrip",
            message: "No driving route \(from) → \(to): \(ns.domain) \(ns.code)",
            details: String(describing: error)
        ))
    }

    /// Writes down, once, each stop that left the film because none of its
    /// photos loaded (not one the person emptied): its neighbours are joined.
    private func logLostStops(kept: [RoadTripCluster]) {
        let keptIDs = Set(kept.map(\.id))
        for stop in editableStops where !keptIDs.contains(stop.id) && !loggedLostStops.contains(stop.id) {
            guard stop.assets.contains(where: { unavailableIDs.contains($0.id) }) else { continue }
            loggedLostStops.insert(stop.id)
            appLog.record(AppLogEntry(
                level: .warning, method: "FILE", path: "RoadTrip", category: "RoadTrip",
                message: "Stop \(stop.placeName ?? stop.id.prefix(8).description) left the film: none of its \(stop.assets.count) photos loaded"
            ))
        }
    }

    private func placeName(ofStop id: String) -> String {
        editableStops.first { $0.id == id }?.placeName ?? id.prefix(8).description
    }

    /// The error when MapKit gives no route (no road, offline, throttled).
    private struct NoRouteError: Error, CustomStringConvertible {
        var description: String { "MKDirections returned no route" }
    }

    private func drivingRoute(from: RoutePoint, to: RoutePoint) async -> Result<[RoutePoint], Error> {
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
            guard let polyline = response.routes.first?.polyline, polyline.pointCount >= 2 else {
                return .failure(NoRouteError())
            }
            return .success(densified(simplified(polyline)))
        } catch {
            return .failure(error)
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
            reduceMotion: reduceMotion,
            carColor: settings.carColor
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

/// Puts every stop on its road. A driving route starts and ends on the road
/// nearest the stop, not on the stop itself, so a pin drawn at the stop's
/// photo spot sits away from where the car stops. Here each stop moves to the
/// end of the route that arrives at it (the first stop: the start of the route
/// that leaves it), and the route that leaves it starts from that same point.
enum RoadTripAnchoring {

    /// Gap (meters) under which a departing route already starts on the anchor.
    static let joinToleranceMeters = 1.0

    static func anchored(
        clusters: [RoadTripCluster],
        legs: [RoadTripLeg]
    ) -> (clusters: [RoadTripCluster], legs: [RoadTripLeg]) {
        var anchors: [String: RoutePoint] = [:]
        var anchoredLegs: [RoadTripLeg] = []
        for leg in legs {
            guard let first = leg.route.first, let last = leg.route.last else {
                anchoredLegs.append(leg)
                continue
            }
            var route = leg.route
            if let start = anchors[leg.fromClusterID] {
                if RoadTripClusterer.haversine(start.coordinate, first.coordinate) > joinToleranceMeters {
                    route.insert(start, at: 0)
                }
            } else {
                anchors[leg.fromClusterID] = first
            }
            anchors[leg.toClusterID] = last
            anchoredLegs.append(RoadTripLeg(
                fromClusterID: leg.fromClusterID,
                toClusterID: leg.toClusterID,
                distanceMeters: leg.distanceMeters,
                route: route
            ))
        }
        let anchoredClusters = clusters.map { cluster -> RoadTripCluster in
            guard let anchor = anchors[cluster.id] else { return cluster }
            return RoadTripCluster(
                id: cluster.id,
                assets: cluster.assets,
                latitude: anchor.latitude,
                longitude: anchor.longitude,
                placeName: cluster.placeName,
                startDate: cluster.startDate,
                endDate: cluster.endDate
            )
        }
        return (anchoredClusters, anchoredLegs)
    }
}

/// Photo quality for the "best of the trip" selection, 0…1: how much a photo
/// is worth posting. Apple's aesthetics model (`CalculateImageAestheticsScoresRequest`)
/// leads; a cheap pixel look (sharpness, exposure, colour) backs it, and is
/// the whole score where Vision is unavailable. Screenshots, receipts and
/// other utility shots sink, so do near-black and blurred frames; a few faces
/// lift a photo (people in the landscape: the trip's posts). Favorites are
/// ranked first by the builder whatever their score.
enum RoadTripPhotoScore {

    /// What the pixels say, measured on a small downsample.
    struct Look: Equatable {
        /// Mean |Laplacian| of the luminance, normalized to 0…1.
        let sharpness: Double
        /// Mean luminance, 0…1.
        let brightness: Double
        /// Mean channel deviation from luminance, normalized to 0…1.
        let colorfulness: Double

        /// The pixel-only score: sharp, well exposed, colourful.
        var score: Double {
            let exposure = 1.0 - min(abs(brightness - 0.55) / 0.55, 1.0)
            return sharpness * 0.5 + exposure * 0.25 + colorfulness * 0.25
        }
    }

    /// Mean luminance under which a photo is a night sky or a pocket shot.
    static let darkBrightness = 0.15
    /// Sharpness under which a photo reads as blurred.
    static let blurredSharpness = 0.2

    static func score(_ image: CGImage) async -> Double {
        let look = measure(image) ?? Look(sharpness: 0.5, brightness: 0.55, colorfulness: 0.5)
        var aesthetics: Double?
        var utility = false
        if let observation = try? await CalculateImageAestheticsScoresRequest().perform(on: image) {
            aesthetics = (Double(observation.overallScore) + 1) / 2
            utility = observation.isUtility
        }
        var faces = 0
        if let observations = try? await DetectFaceRectanglesRequest().perform(on: image) {
            // Faces big enough to be the subject, not a crowd in the distance.
            faces = observations.filter { $0.boundingBox.width * $0.boundingBox.height > 0.004 }.count
        }
        return combine(look: look, aesthetics: aesthetics, isUtility: utility, faces: faces)
    }

    /// The final score from its parts (pure, so the weighting is testable).
    static func combine(look: Look, aesthetics: Double?, isUtility: Bool, faces: Int) -> Double {
        var score = aesthetics.map { 0.65 * $0 + 0.35 * look.score } ?? look.score
        if isUtility { score *= 0.3 }
        if look.brightness < darkBrightness { score *= 0.5 }
        if look.sharpness < blurredSharpness { score *= 0.7 }
        if (1...4).contains(faces) { score += 0.08 }
        return min(max(score, 0), 1)
    }

    static func measure(_ image: CGImage) -> Look? {
        guard let small = downsample(image, maxDimension: 48) else { return nil }
        let w = small.width, h = small.height
        guard w > 2, h > 2,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
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

        var sharp = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = 4 * lum[i] - lum[i - 1] - lum[i + 1] - lum[i - w] - lum[i + w]
                sharp += abs(lap)
            }
        }
        sharp /= Double((w - 2) * (h - 2))

        return Look(
            sharpness: min(sharp / 0.18, 1.0),
            brightness: meanL,
            colorfulness: min((abs(meanR - meanL) + abs(meanG - meanL) + abs(meanB - meanL)) / 0.45, 1.0)
        )
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
