import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UIKit
import MapKit

struct RoadTripRenderConfig: Sendable {
    let size: CGSize
    let fps: Int
    let baseURL: URL
    let token: String?
    let albumTitle: String
    let reduceMotion: Bool
    /// The car's paint (`RoadTripSettings`).
    var carColor: RoadTripSettings.CarColor = .white
}

/// Renders the deterministic road-trip timeline into an HEVC `.mp4`: a
/// 1080 × 1920 vertical video cut for Reels, TikTok and Shorts.
///
/// Pipeline:
/// 1. Photos downloaded once (authenticated), decoded once to `CGImage`.
/// 2. The map from satellite snapshots (`MKMapSnapshotter`): one of the whole
///    trip for the opening and the ending, and per leg (taken when the leg
///    comes up, released after it) one of all the ground its camera shows plus
///    sharper close-ups of its start and its end. Each frame crops the
///    sharpest snapshot holding the camera's rect (`RoadTripAerialCamera`, the
///    live player's camera) and draws the trip's line, the stops, the car and
///    the road counter over it.
/// 3. Title cards and leg labels pre-rendered once.
/// 4. Frame loop draws each frame whole on the GPU (`RoadTripMetalCanvas`,
///    Core Graphics where Metal is missing) straight into the `CVPixelBuffer`s
///    of the writer's pool (IOSurface: shared with the GPU, no copy),
///    streamed to `AVAssetWriter`.
///    Frames are drawn a batch at a time on every core (`drawFrame` reads
///    only immutable inputs), appended in order; each leg's snapshots are
///    taken ahead, while the frames before it are drawn.
///    Canvas coordinates are y-down (`RoadTripFrameCanvas`), as the live
///    player's and the map snapshots'.
final class RoadTripVideoRenderer: @unchecked Sendable {

    /// The process-wide road-trip session (`ServerSessions.roadTrip`): trust
    /// store aware, never built per call.
    private let session: @Sendable () -> URLSession

    init(session: @escaping @Sendable () -> URLSession) {
        self.session = session
    }

    // MARK: - Prepared visuals

    /// A satellite snapshot of the film's map and the exact map rect it covers.
    struct MapShot {
        let image: CGImage
        let rect: MKMapRect
    }

    /// A leg's road as drawn: map points and their arc fractions.
    struct Road {
        let points: [MKMapPoint]
        let fractions: [Double]
    }

    /// Everything the map frames draw.
    struct ExportMap {
        /// The whole trip: the opening and the ending.
        var overview: [MapShot] = []
        /// Each leg's snapshots, by segment index — only the leg being drawn.
        var legs: [Int: [MapShot]] = [:]
        /// Each leg's road, by segment index.
        var roads: [Int: Road] = [:]
        /// The located stops, in film order.
        var stops: [RoadTripMapStop] = []
        /// The photo each stop opens on (cluster id → image): the ending's pins.
        var heroes: [String: CGImage] = [:]

        static let empty = ExportMap()
    }

    struct VisualAssets {
        let opening: CGImage?
        let ending: CGImage?
        let intertitles: [String: CGImage]
        /// "Paris, France → Versailles, France" pills, by leg segment index.
        var legLabels: [Int: CGImage] = [:]
    }

    // MARK: - Public entry point

    /// `preloaded`: photos already decoded by the caller (asset id → image);
    /// only the missing ones are downloaded.
    func render(
        clusters: [RoadTripCluster],
        timeline: RoadTripTimeline,
        config: RoadTripRenderConfig,
        preloaded: [String: CGImage] = [:],
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let images = try await preloadImages(clusters: clusters, timeline: timeline, config: config, preloaded: preloaded)
        try Task.checkCancellation()
        let visuals = await prepareCards(clusters: clusters, timeline: timeline, config: config)
        try Task.checkCancellation()
        defer { RoadTripMetalEngine.shared?.purge() }
        return try await writeVideo(
            clusters: clusters, timeline: timeline, config: config,
            images: images, visuals: visuals, progress: progress
        )
    }

    // MARK: - Preload photos

    private func preloadImages(
        clusters: [RoadTripCluster],
        timeline: RoadTripTimeline,
        config: RoadTripRenderConfig,
        preloaded: [String: CGImage]
    ) async throws -> [String: CGImage] {
        var assetByID: [String: AssetReactItem] = [:]
        for cluster in clusters {
            for asset in cluster.assets { assetByID[asset.id] = asset }
        }

        var needed = Set<String>()
        var clusterByID: [String: RoadTripCluster] = [:]
        for cluster in clusters { clusterByID[cluster.id] = cluster }
        for segment in timeline.segments {
            guard case .slideshow(let slideshow) = segment,
                  let cluster = clusterByID[slideshow.clusterID] else { continue }
            for index in slideshow.assetIndices where cluster.assets.indices.contains(index) {
                needed.insert(cluster.assets[index].id)
            }
        }

        let session = self.session
        var result: [String: CGImage] = [:]
        for id in needed {
            if let image = preloaded[id] { result[id] = image }
        }
        let ids = needed.filter { result[$0] == nil }.sorted()
        let chunkSize = 6
        var offset = 0
        while offset < ids.count {
            try Task.checkCancellation()
            let chunk = Array(ids[offset..<min(offset + chunkSize, ids.count)])
            let pairs = await withTaskGroup(of: (String, CGImage?).self) { group in
                for id in chunk {
                    group.addTask { await Self.loadImage(id: id, asset: assetByID[id], config: config, session: session) }
                }
                var collected: [(String, CGImage?)] = []
                for await pair in group { collected.append(pair) }
                return collected
            }
            for (id, cg) in pairs where cg != nil {
                result[id] = cg
            }
            offset += chunkSize
        }
        return result
    }

    private nonisolated static func loadImage(
        id: String,
        asset: AssetReactItem?,
        config: RoadTripRenderConfig,
        session: @Sendable () -> URLSession
    ) async -> (String, CGImage?) {
        guard let asset else { return (id, nil) }
        let url = ImmichAssetURL.thumbnail(
            assetId: id, thumbhash: asset.thumbhash ?? "", baseURL: config.baseURL, size: .preview
        )
        do {
            let (data, _) = try await AssetFileTransfer.fetchData(from: url, token: config.token, session: session())
            return (id, Self.decode(data))
        } catch {
            return (id, nil)
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    // MARK: - Preload cards (MainActor: SwiftUI/UIKit rendering)

    @MainActor
    private func prepareCards(
        clusters: [RoadTripCluster],
        timeline: RoadTripTimeline,
        config: RoadTripRenderConfig
    ) async -> VisualAssets {
        var intertitles: [String: CGImage] = [:]
        var names: [String: String] = [:]
        for (i, cluster) in clusters.enumerated() {
            let name = cluster.placeName?.isEmpty == false ? cluster.placeName! : String(localized: "Stop \(i + 1)")
            names[cluster.id] = name
            intertitles[cluster.id] = Self.intertitleCard(placeName: name, size: config.size)
        }
        var legLabels: [Int: CGImage] = [:]
        for (index, segment) in timeline.segments.enumerated() {
            guard case .travel(let travel) = segment else { continue }
            let label = "\(names[travel.fromClusterID] ?? "") → \(names[travel.toClusterID] ?? "")"
            legLabels[index] = Self.pillCard(label, canvas: config.size)
        }

        let photoCount = timeline.photoCount
        let placeNames = RoadTripTimeline.dedupedPlaceNames(clusters.map { $0.placeName ?? "" })
        let meters = timeline.totalDrivenMeters
        let overMap = !RoadTripMapStop.stops(of: clusters).isEmpty
        RoadTripCar3D.warm(color: config.carColor)
        return VisualAssets(
            opening: Self.openingCard(
                albumTitle: config.albumTitle, photoCount: photoCount,
                placeCount: clusters.count, meters: meters, overMap: overMap, size: config.size
            ),
            ending: Self.endingCard(
                albumTitle: config.albumTitle, photoCount: photoCount, placeCount: clusters.count,
                meters: meters, places: placeNames, overMap: overMap, size: config.size
            ),
            intertitles: intertitles,
            legLabels: legLabels
        )
    }

    /// The whole trip, for the opening and the ending: one snapshot holding
    /// every rect they show.
    @MainActor
    private func snapshotOverview(timeline: RoadTripTimeline, stops: [RoadTripMapStop], canvas: CGSize) async -> [MapShot] {
        let aspect = Double(canvas.width / canvas.height)
        guard let overview = RoadTripAerialCamera.overview(timeline: timeline, stops: stops, aspect: aspect) else { return [] }
        let rect = RoadTripAerialCamera.scaled(overview, by: RoadTripAerialCamera.openingPullFactor * 1.04)
        guard let shot = await snapshot(rect, canvas: canvas, oversample: 1.5) else { return [] }
        return [shot]
    }

    /// A leg's snapshots: all the ground its camera shows, and sharper
    /// close-ups of its start and its end (where the camera is closest).
    @MainActor
    private func snapshotLeg(travel: RoadTripTimeline.Travel, canvas: CGSize) async -> [MapShot] {
        guard travel.route.count >= 2 else { return [] }
        let aspect = Double(canvas.width / canvas.height)
        let envelope = RoadTripAerialCamera.scaled(RoadTripAerialCamera.legEnvelope(travel: travel, aspect: aspect), by: 1.06)
        let start = RoadTripAerialCamera.scaled(RoadTripAerialCamera.legRect(travel: travel, localTime: 0, aspect: aspect), by: 1.4)
        let end = RoadTripAerialCamera.scaled(RoadTripAerialCamera.legRect(travel: travel, localTime: travel.duration, aspect: aspect), by: 1.4)
        // The three at once: MapKit renders them in parallel.
        async let whole = snapshot(envelope, canvas: canvas, oversample: 2)
        async let first = snapshot(start, canvas: canvas, oversample: 1.5)
        async let last = snapshot(end, canvas: canvas, oversample: 1.5)
        return [await whole, await first, await last].compactMap { $0 }
    }

    /// A satellite snapshot of `rect`, `oversample` × the canvas in pixels;
    /// nil when MapKit fails (the frame then draws no map).
    @MainActor
    private func snapshot(_ rect: MKMapRect, canvas: CGSize, oversample: CGFloat) async -> MapShot? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = CGSize(width: (canvas.width * oversample).rounded(), height: (canvas.height * oversample).rounded())
        options.scale = 1
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        let snapshotter = MKMapSnapshotter(options: options)
        do {
            let snapshot: MKMapSnapshotter.Snapshot = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    snapshotter.start { snapshot, error in
                        if let snapshot {
                            continuation.resume(returning: snapshot)
                        } else {
                            continuation.resume(throwing: error ?? APIError.decoding("Map snapshot failed"))
                        }
                    }
                }
            } onCancel: {
                snapshotter.cancel()
            }
            guard let image = snapshot.image.cgImage else { return nil }
            return MapShot(image: image, rect: Self.coveredRect(of: snapshot, requested: rect))
        } catch {
            return nil
        }
    }

    /// The map rect a snapshot really covers, from its own `point(for:)` at
    /// two corners of the requested rect (MapKit may fit the rect to the size).
    private static func coveredRect(of snapshot: MKMapSnapshotter.Snapshot, requested rect: MKMapRect) -> MKMapRect {
        let a = MKMapPoint(x: rect.minX, y: rect.minY)
        let b = MKMapPoint(x: rect.maxX, y: rect.maxY)
        let pa = snapshot.point(for: a.coordinate)
        let pb = snapshot.point(for: b.coordinate)
        let scaleX = Double(pb.x - pa.x) / max(b.x - a.x, 1e-9)
        let scaleY = Double(pb.y - pa.y) / max(b.y - a.y, 1e-9)
        guard scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return rect }
        let size = snapshot.image.size
        return MKMapRect(
            x: a.x - Double(pa.x) / scaleX, y: a.y - Double(pa.y) / scaleY,
            width: Double(size.width) / scaleX, height: Double(size.height) / scaleY
        )
    }

    // MARK: - Card rendering (UIKit, deterministic, off-main)

    private static func text(_ string: String, font: UIFont, color: UIColor, kern: CGFloat = 0) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: kern,
            .paragraphStyle: paragraph
        ])
    }

    private static func height(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
        string.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
    }

    private static func render(_ size: CGSize, opaque: Bool, draw: @escaping (CGSize) -> Void) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(size) }.cgImage
    }

    /// Stacks `items` (attributed string + measured height) vertically centered
    /// on `centerY`, horizontally centered in the card.
    private static func drawCentered(
        _ items: [(NSAttributedString, CGFloat)], in size: CGSize, gap: CGFloat, centerY: CGFloat, shadow: Bool = false
    ) {
        let inset: CGFloat = 64
        let width = size.width - inset * 2
        let totalHeight = items.reduce(0) { $0 + $1.1 } + gap * CGFloat(max(items.count - 1, 0))
        var y = centerY - totalHeight / 2
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.saveGState()
        if shadow {
            ctx?.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: UIColor.black.withAlphaComponent(0.6).cgColor)
        }
        for (string, h) in items {
            string.draw(in: CGRect(x: inset, y: y, width: width, height: h))
            y += h + gap
        }
        ctx?.restoreGState()
    }

    /// The opening's title: over the map (a scrim darkening its top), or on
    /// black when nothing is located.
    private static func openingCard(
        albumTitle: String, photoCount: Int, placeCount: Int, meters: Double, overMap: Bool, size: CGSize
    ) -> CGImage? {
        render(size, opaque: !overMap) { canvas in
            if overMap {
                drawTitleScrim(canvas)
            } else {
                UIColor.black.setFill()
                UIRectFill(CGRect(origin: .zero, size: canvas))
            }
            let kicker = text("ROAD TRIP", font: .systemFont(ofSize: 30, weight: .semibold), color: .white.withAlphaComponent(0.85), kern: 6)
            let title = text(albumTitle, font: .systemFont(ofSize: 84, weight: .heavy), color: .white)
            let sub = text(
                statsLine(photoCount: photoCount, placeCount: placeCount, meters: meters),
                font: .systemFont(ofSize: 36, weight: .semibold), color: .white.withAlphaComponent(0.92)
            )
            let width = canvas.width - 128
            drawCentered(
                [(kicker, height(kicker, width: width)), (title, height(title, width: width)), (sub, height(sub, width: width))],
                in: canvas, gap: 28, centerY: overMap ? canvas.height * 0.2 : canvas.height / 2, shadow: overMap
            )
        }
    }

    /// The ending's title over the whole trip — or, with nothing located, the
    /// list of places on a dusk gradient.
    private static func endingCard(
        albumTitle: String, photoCount: Int, placeCount: Int, meters: Double,
        places: [String], overMap: Bool, size: CGSize
    ) -> CGImage? {
        render(size, opaque: !overMap) { canvas in
            if overMap {
                drawTitleScrim(canvas)
            } else {
                // Warm dusk gradient instead of pure black for the finale.
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let colors = [
                    UIColor(red: 0.11, green: 0.07, blue: 0.05, alpha: 1).cgColor,
                    UIColor(red: 0.04, green: 0.03, blue: 0.03, alpha: 1).cgColor
                ] as CFArray
                if let ctx = UIGraphicsGetCurrentContext(),
                   let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: canvas.height), options: [])
                }
            }
            let kicker = text("ROAD TRIP", font: .systemFont(ofSize: 30, weight: .semibold), color: UIColor(red: 1, green: 0.82, blue: 0.62, alpha: 1), kern: 6)
            let title = text(albumTitle, font: .systemFont(ofSize: 72, weight: .heavy), color: .white)
            let sub = text(
                statsLine(photoCount: photoCount, placeCount: placeCount, meters: meters),
                font: .systemFont(ofSize: 36, weight: .semibold), color: .white.withAlphaComponent(0.92)
            )
            let width = canvas.width - 128
            var items: [(NSAttributedString, CGFloat)] = [
                (kicker, height(kicker, width: width)),
                (title, height(title, width: width)),
                (sub, height(sub, width: width))
            ]
            if !overMap {
                for place in places.filter({ !$0.isEmpty }) {
                    let line = text(place, font: .systemFont(ofSize: 30, weight: .regular), color: .white.withAlphaComponent(0.85))
                    items.append((line, height(line, width: width)))
                }
            }
            drawCentered(items, in: canvas, gap: 24, centerY: overMap ? canvas.height * 0.18 : canvas.height / 2, shadow: overMap)
        }
    }

    /// "8 photos · 8 places · 142 km".
    private static func statsLine(photoCount: Int, placeCount: Int, meters: Double) -> String {
        let counts = String(localized: "\(photoCount) photos · \(placeCount) places")
        guard meters > 0 else { return counts }
        return counts + " · " + RoadTripTimeline.distanceText(meters: meters)
    }

    /// Darkens the top of the map under a title.
    private static func drawTitleScrim(_ canvas: CGSize) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let colors = [
            UIColor.black.withAlphaComponent(0.75).cgColor,
            UIColor.black.withAlphaComponent(0.35).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) else { return }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: canvas.height * 0.5), options: [])
    }

    /// A leg's "Paris, France → Versailles, France" pill, sized to its text.
    private static func pillCard(_ label: String, canvas: CGSize) -> CGImage? {
        let string = text(label, font: .systemFont(ofSize: 36, weight: .semibold), color: .white)
        let maxWidth = canvas.width - 160
        let textSize = string.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        ).size
        let size = CGSize(width: min(textSize.width, maxWidth).rounded(.up) + 64, height: textSize.height.rounded(.up) + 32)
        return render(size, opaque: false) { pill in
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: pill), cornerRadius: pill.height / 2)
            UIColor.black.withAlphaComponent(0.55).setFill()
            path.fill()
            string.draw(in: CGRect(x: 32, y: 16, width: pill.width - 64, height: textSize.height.rounded(.up)))
        }
    }

    private static func intertitleCard(placeName: String, size: CGSize) -> CGImage? {
        render(size, opaque: false) { canvas in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
            shadow.shadowOffset = CGSize(width: 0, height: 3)
            shadow.shadowBlurRadius = 8
            let string = NSAttributedString(string: placeName, attributes: [
                .font: UIFont.systemFont(ofSize: 72, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .shadow: shadow
            ])
            let width = canvas.width - 96
            let h = string.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
            ).height
            string.draw(in: CGRect(x: 48, y: canvas.height / 2 - h / 2, width: width, height: h))
        }
    }

    // MARK: - Frame writing

    private func writeVideo(
        clusters: [RoadTripCluster],
        timeline: RoadTripTimeline,
        config: RoadTripRenderConfig,
        images: [String: CGImage],
        visuals: VisualAssets,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roadtrip-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // `AVAssetWriterInput` raises an Objective-C exception — an abort
        // Swift cannot catch — on any settings it refuses: checked first.
        let settings = Self.videoSettings(config)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw APIError.decoding("Unsupported video settings")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(config.size.width),
                kCVPixelBufferHeightKey as String: Int(config.size.height),
                // Shared with the GPU: Core Image draws the ground straight
                // into the buffer instead of into a texture copied back.
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? APIError.decoding("Failed to start video writer")
        }
        writer.startSession(atSourceTime: .zero)

        var clusterByID: [String: RoadTripCluster] = [:]
        for cluster in clusters { clusterByID[cluster.id] = cluster }

        // The map: the trip's roads and stops, the overview snapshot now, and
        // each leg's snapshots taken ahead — the next leg's while the frames
        // before it are drawn — and released after it (peak memory holds two
        // legs').
        let travelIndices = timeline.segments.indices.filter {
            if case .travel = timeline.segments[$0] { return true }
            return false
        }
        var legShots: [Int: Task<[MapShot], Never>] = [:]
        func legShotsTask(_ index: Int) -> Task<[MapShot], Never> {
            if let task = legShots[index] { return task }
            guard case .travel(let travel) = timeline.segments[index] else { return Task { [] } }
            let task = Task { await self.snapshotLeg(travel: travel, canvas: config.size) }
            legShots[index] = task
            return task
        }
        if let first = travelIndices.first { _ = legShotsTask(first) }
        var map = await prepareMap(clusters: clusters, timeline: timeline, images: images, canvas: config.size)

        let totalFrames = max(1, Int((timeline.totalDuration * Double(config.fps)).rounded(.up)))
        let batchSize = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var frameTime = CMTime.zero

        do {
            // A batch is drawn while the one before it goes to the encoder:
            // the GPU and the encoder never wait for each other.
            var batchStart = 0
            var drawing: (task: Task<Void, Never>, frames: [Int], buffers: [CVPixelBuffer])?
            defer { drawing?.task.cancel() }
            while batchStart < totalFrames || drawing != nil {
                try Task.checkCancellation()
                var next: (task: Task<Void, Never>, frames: [Int], buffers: [CVPixelBuffer])?
                if batchStart < totalFrames {
                    let batch = Array(batchStart..<min(batchStart + batchSize, totalFrames))
                    let times = batch.map { Double($0) / Double(config.fps) }

                    // The legs this batch draws: their snapshots in, the next
                    // leg's started, the legs behind released (the batch
                    // being encoded holds its own copy of the map).
                    let segments = Set(times.map { timeline.localTime(at: $0).segmentIndex })
                    let legsHere = travelIndices.filter { segments.contains($0) }
                    for index in legsHere where map.legs[index] == nil {
                        map.legs[index] = await legShotsTask(index).value
                    }
                    if let last = segments.max(), let following = travelIndices.first(where: { $0 > last }) {
                        _ = legShotsTask(following)
                    }
                    let firstSegment = segments.min() ?? 0
                    for index in Array(map.legs.keys) where index < firstSegment {
                        map.legs[index] = nil
                    }
                    for index in Array(legShots.keys) where index < firstSegment {
                        legShots[index] = nil
                    }

                    guard let pool = adaptor.pixelBufferPool else { throw APIError.decoding("No pixel buffer pool") }
                    var buffers: [CVPixelBuffer] = []
                    for _ in batch {
                        var pixelBuffer: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                        guard let buffer = pixelBuffer else { throw APIError.decoding("No pixel buffer") }
                        buffers.append(buffer)
                    }

                    // Every frame of the batch at once.
                    let inputs = FrameInputs(
                        clusters: clusters, clusterByID: clusterByID, timeline: timeline, config: config,
                        images: images, visuals: visuals, map: map, buffers: buffers
                    )
                    let task = Task {
                        await withTaskGroup(of: Void.self) { group in
                            for (k, t) in times.enumerated() {
                                group.addTask {
                                    self.drawFrame(
                                        at: t, into: inputs.buffers[k],
                                        clusters: inputs.clusters, clusterByID: inputs.clusterByID, timeline: inputs.timeline,
                                        config: inputs.config, images: inputs.images, visuals: inputs.visuals, map: inputs.map
                                    )
                                }
                            }
                        }
                    }
                    next = (task, batch, buffers)
                    batchStart += batch.count
                }

                if let done = drawing {
                    await done.task.value
                    for (k, buffer) in done.buffers.enumerated() {
                        while !input.isReadyForMoreMediaData {
                            try await Task.sleep(for: .milliseconds(2))
                        }
                        adaptor.append(buffer, withPresentationTime: frameTime)
                        frameTime = CMTimeAdd(frameTime, CMTime(value: 1, timescale: Int32(config.fps)))
                        progress(Double(done.frames[k]) / Double(totalFrames))
                    }
                }
                drawing = next
            }
            for task in legShots.values { task.cancel() }
            input.markAsFinished()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    writer.finishWriting { continuation.resume() }
                }
            } onCancel: {
                writer.cancelWriting()
            }
            guard writer.status == .completed else {
                throw writer.error ?? APIError.decoding("Video writer did not complete")
            }
            progress(1)
            return outputURL
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// What every frame of a batch reads, handed to the drawing tasks: never
    /// mutated while they run (each frame writes only its own buffer).
    private struct FrameInputs: @unchecked Sendable {
        let clusters: [RoadTripCluster]
        let clusterByID: [String: RoadTripCluster]
        let timeline: RoadTripTimeline
        let config: RoadTripRenderConfig
        let images: [String: CGImage]
        let visuals: VisualAssets
        let map: ExportMap
        let buffers: [CVPixelBuffer]
    }

    /// HEVC at the canvas size (internal for the tests). The encoder's tuning
    /// lives under `AVVideoCompressionPropertiesKey`: a bitrate at the top
    /// level makes `AVAssetWriterInput` raise and the app abort on Save.
    static func videoSettings(_ config: RoadTripRenderConfig) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(config.size.width),
            AVVideoHeightKey: Int(config.size.height),
            AVVideoCompressionPropertiesKey: [
                // Explicit bitrate — encoder defaults smear the map's motion.
                AVVideoAverageBitRateKey: 14_000_000,
                AVVideoExpectedSourceFrameRateKey: config.fps,
                // A key frame every second: scrubbing and the cuts stay clean.
                AVVideoMaxKeyFrameIntervalKey: config.fps
            ] as [String: Any]
        ]
    }

    /// The trip's roads, stops, the stops' hero photos and the overview
    /// snapshot.
    private func prepareMap(
        clusters: [RoadTripCluster],
        timeline: RoadTripTimeline,
        images: [String: CGImage],
        canvas: CGSize
    ) async -> ExportMap {
        var map = ExportMap()
        map.stops = RoadTripMapStop.stops(of: clusters)
        map.roads = Self.roads(of: timeline)
        var clusterByID: [String: RoadTripCluster] = [:]
        for cluster in clusters { clusterByID[cluster.id] = cluster }
        for segment in timeline.segments {
            guard case .slideshow(let slideshow) = segment,
                  let cluster = clusterByID[slideshow.clusterID],
                  let first = slideshow.assetIndices.first,
                  cluster.assets.indices.contains(first),
                  let image = images[cluster.assets[first].id] else { continue }
            map.heroes[slideshow.clusterID] = image
        }
        if !map.stops.isEmpty {
            map.overview = await snapshotOverview(timeline: timeline, stops: map.stops, canvas: canvas)
        }
        return map
    }

    /// Each leg's road as drawn (internal for the tests).
    static func roads(of timeline: RoadTripTimeline) -> [Int: Road] {
        var roads: [Int: Road] = [:]
        for (index, segment) in timeline.segments.enumerated() {
            guard case .travel(let travel) = segment else { continue }
            let drawn = RoadTripRouteDrawing.drawnRoute(travel.route)
            guard drawn.coordinates.count >= 2 else { continue }
            roads[index] = Road(points: drawn.coordinates.map { MKMapPoint($0) }, fractions: drawn.fractions)
        }
        return roads
    }

    // MARK: - Frame drawing

    /// What draws the frames.
    enum Backend {
        /// The GPU, every pixel (`RoadTripMetalCanvas`).
        case metal
        /// Core Graphics (`RoadTripCGCanvas`): where Metal is missing, and the
        /// tests' reference.
        case coreGraphics
    }

    /// Draws the frame at `time` into `pixelBuffer` (internal for the tests):
    /// the scene below, on the GPU unless `backend` says otherwise or Metal
    /// is missing.
    func drawFrame(
        at time: TimeInterval,
        into pixelBuffer: CVPixelBuffer,
        clusters: [RoadTripCluster],
        clusterByID: [String: RoadTripCluster],
        timeline: RoadTripTimeline,
        config: RoadTripRenderConfig,
        images: [String: CGImage],
        visuals: VisualAssets,
        map: ExportMap,
        backend: Backend = .metal
    ) {
        let metal: RoadTripFrameCanvas? = backend == .metal
            ? RoadTripMetalEngine.shared.flatMap { RoadTripMetalCanvas(pixelBuffer: pixelBuffer, engine: $0) }
            : nil
        guard let canvas = metal ?? RoadTripCGCanvas(pixelBuffer: pixelBuffer) else { return }
        drawScene(
            on: canvas, at: time, clusterByID: clusterByID, timeline: timeline,
            config: config, images: images, visuals: visuals, map: map
        )
        canvas.finish()
    }

    /// The film at `time`, whatever draws it.
    private func drawScene(
        on canvas: RoadTripFrameCanvas,
        at time: TimeInterval,
        clusterByID: [String: RoadTripCluster],
        timeline: RoadTripTimeline,
        config: RoadTripRenderConfig,
        images: [String: CGImage],
        visuals: VisualAssets,
        map: ExportMap
    ) {
        let size = canvas.size
        let aspect = Double(size.width / max(size.height, 1))
        canvas.fill(.black)

        let (segmentIndex, local) = timeline.localTime(at: time)
        switch timeline.segments[segmentIndex] {
        case .opening(let duration):
            let progress = local / max(duration, 0.001)
            if let rect = RoadTripAerialCamera.rect(for: .opening(progress: progress), timeline: timeline, stops: map.stops, aspect: aspect) {
                drawMap(on: canvas, shots: map.overview, rect: rect)
                drawRoads(on: canvas, map: map, rect: rect, alpha: RoadTripMapStyle.previewAlpha) { _ in 1 }
                drawStops(on: canvas, map: map, upTo: map.stops.count - 1, rect: rect)
            }
            if let card = visuals.opening {
                drawCard(on: canvas, card, progress: progress, fadeIn: 0.15, fadeOut: 0)
            }
        case .slideshow(let slideshow):
            drawSlideshow(on: canvas, slideshow: slideshow, clusterByID: clusterByID, localTime: local, config: config, images: images)
            canvas.vignette()
            if let title = visuals.intertitles[slideshow.clusterID] {
                drawOverlayFade(on: canvas, title, localTime: local, duration: 1.5)
            }
        case .travel(let travel):
            drawTravel(
                on: canvas, travel: travel, segmentIndex: segmentIndex, localTime: local,
                timeline: timeline, map: map, legLabel: visuals.legLabels[segmentIndex],
                carColor: config.carColor,
                outgoing: edgePhotos(
                    at: segmentIndex - 1, first: false, timeline: timeline, clusterByID: clusterByID,
                    images: images, reduceMotion: config.reduceMotion, canvas: size
                ),
                arriving: edgePhotos(
                    at: segmentIndex + 1, first: true, timeline: timeline, clusterByID: clusterByID,
                    images: images, reduceMotion: config.reduceMotion, canvas: size
                )
            )
        case .ending(let duration):
            let progress = local / max(duration, 0.001)
            if let rect = RoadTripAerialCamera.rect(for: .ending(progress: progress), timeline: timeline, stops: map.stops, aspect: aspect) {
                drawMap(on: canvas, shots: map.overview, rect: rect)
                drawRoads(on: canvas, map: map, rect: rect, alpha: 1) { _ in 1 }
                drawStops(on: canvas, map: map, upTo: map.stops.count - 1, rect: rect)
                drawPhotoPins(on: canvas, map: map, progress: progress, rect: rect)
            }
            if let card = visuals.ending {
                drawCard(on: canvas, card, progress: progress, fadeIn: 0.2, fadeOut: 0)
            }
        }
    }

    private func drawSlideshow(
        on canvas: RoadTripFrameCanvas,
        slideshow: RoadTripTimeline.Slideshow,
        clusterByID: [String: RoadTripCluster],
        localTime: TimeInterval,
        config: RoadTripRenderConfig,
        images: [String: CGImage]
    ) {
        let frame = RoadTripSlideTiming.frame(slideshow: slideshow, localTime: localTime, reduceMotion: config.reduceMotion)
        guard let cluster = clusterByID[slideshow.clusterID] else { return }

        if slideshow.isCollage(slide: frame.currentIndex) {
            // The stop's photos on one screen — the player draws the same tiles.
            let tiles = RoadTripCollage.drawnTiles(
                slideshow: slideshow, localTime: localTime, canvas: canvas.size, reduceMotion: config.reduceMotion
            )
            for tile in tiles {
                if let image = image(at: tile.position, of: slideshow, cluster: cluster, images: images) {
                    drawTile(on: canvas, image, tile: tile, alpha: tile.alpha)
                }
            }
        } else {
            let position = slideshow.positions(ofSlide: frame.currentIndex).lowerBound
            if slideshow.assetIndices.indices.contains(position) {
                drawSlideImage(on: canvas, image(at: position, of: slideshow, cluster: cluster, images: images),
                               transform: frame.currentTransform, alpha: 1)
            }
        }
        if frame.crossfade > 0, let next = frame.nextIndex {
            let position = slideshow.positions(ofSlide: next).lowerBound
            if slideshow.assetIndices.indices.contains(position) {
                drawSlideImage(on: canvas, image(at: position, of: slideshow, cluster: cluster, images: images),
                               transform: frame.nextTransform ?? .identity, alpha: frame.crossfade)
            }
        }
    }

    /// The decoded photo at `position` of the slideshow's `assetIndices`.
    private func image(
        at position: Int,
        of slideshow: RoadTripTimeline.Slideshow,
        cluster: RoadTripCluster,
        images: [String: CGImage]
    ) -> CGImage? {
        guard slideshow.assetIndices.indices.contains(position),
              cluster.assets.indices.contains(slideshow.assetIndices[position]) else { return nil }
        return images[cluster.assets[slideshow.assetIndices[position]].id]
    }

    /// One photo of a collage (or a frame's photo, as an edge tile): filling
    /// its rect, pushed in by its zoom, tilted about its center, inside its
    /// white rim when framed.
    private func drawTile(on canvas: RoadTripFrameCanvas, _ image: CGImage, tile: RoadTripCollage.DrawnTile, alpha: Double) {
        if tile.framed {
            let rim = canvas.size.width * CGFloat(RoadTripCollage.frameBorder)
            canvas.fill(tile.rect.insetBy(dx: -rim, dy: -rim), color: RoadTripRGBA.white.withAlpha(alpha), rotation: tile.rotation)
        }
        canvas.drawFilled(image, in: tile.rect, zoom: tile.zoom, alpha: alpha, rotation: tile.rotation)
    }

    /// A slideshow photo in its Ken Burns framing (grey where it is missing).
    private func drawSlideImage(on canvas: RoadTripFrameCanvas, _ image: CGImage?, transform: KenBurnsTransform, alpha: Double) {
        let size = canvas.size
        guard let image else {
            canvas.fill(CGRect(origin: .zero, size: size), color: RoadTripRGBA(red: 0.1, green: 0.1, blue: 0.1, alpha: alpha))
            return
        }
        canvas.draw(image, in: transformed(aspectFillRect(image: image, canvas: size), canvas: size, transform: transform), alpha: alpha)
    }

    /// A photo of a slideshow's first or last frame and where it sits.
    private struct EdgePhoto {
        let tile: RoadTripCollage.DrawnTile
        let image: CGImage
    }

    /// The photos on the first (`first`) or last frame of the slideshow
    /// segment at `index` — one photo, or a collage's tiles — used for the
    /// map↔media transitions (the dive on the arrival side, the fading photos
    /// on the departure side). Travel legs are always sandwiched between
    /// slideshows, so the neighbors are the slideshow segments.
    private func edgePhotos(
        at index: Int,
        first: Bool,
        timeline: RoadTripTimeline,
        clusterByID: [String: RoadTripCluster],
        images: [String: CGImage],
        reduceMotion: Bool,
        canvas: CGSize
    ) -> [EdgePhoto] {
        guard timeline.segments.indices.contains(index),
              case .slideshow(let slideshow) = timeline.segments[index],
              let cluster = clusterByID[slideshow.clusterID] else { return [] }
        return RoadTripSlideTiming.edgeTiles(slideshow: slideshow, first: first, reduceMotion: reduceMotion, canvas: canvas)
            .compactMap { tile in
                image(at: tile.position, of: slideshow, cluster: cluster, images: images).map { EdgePhoto(tile: tile, image: $0) }
            }
    }

    private func drawTravel(
        on canvas: RoadTripFrameCanvas,
        travel: RoadTripTimeline.Travel,
        segmentIndex: Int,
        localTime: TimeInterval,
        timeline: RoadTripTimeline,
        map: ExportMap,
        legLabel: CGImage?,
        carColor: RoadTripSettings.CarColor,
        outgoing: [EdgePhoto],
        arriving: [EdgePhoto]
    ) {
        let size = canvas.size
        guard travel.route.count >= 2, let shots = map.legs[segmentIndex], !shots.isEmpty else {
            canvas.fill(RoadTripRGBA(red: 0.06, green: 0.06, blue: 0.06, alpha: 1))
            return
        }
        let aspect = Double(size.width / max(size.height, 1))
        let rect = RoadTripAerialCamera.legRect(travel: travel, localTime: localTime, aspect: aspect)
        let timing = RoadTripTravelTiming.frame(travel: travel, localTime: localTime)
        let fraction = min(max(timing.routeDrawnFraction, 0), 1)
        let dive = RoadTripSegue.diveProgress(localTime: localTime, legDuration: travel.duration)

        // The ground, the trip's line (every leg already driven, this one up
        // to the car), the stops reached and the one ahead.
        drawMap(on: canvas, shots: shots, rect: rect)
        drawRoads(on: canvas, map: map, rect: rect, alpha: 1) { segment in
            segment < segmentIndex ? 1 : (segment == segmentIndex ? fraction : 0)
        }
        let destination = map.stops.firstIndex { $0.clusterID == travel.toClusterID } ?? (map.stops.count - 1)
        drawStops(on: canvas, map: map, upTo: destination, rect: rect)

        // The car, nose along the road (north-up: heading = screen angle).
        let car = RoadTripAerialCamera.project(MKMapPoint(timing.carCoordinate.coordinate), in: rect, canvas: size)
        let heading = RoadTripAerialCamera.carHeading(travel: travel, localTime: localTime)
        drawTopCar(on: canvas, at: car, heading: heading, size: size.width * CGFloat(RoadTripMapStyle.carSpriteSize), color: carColor)

        // The road counter and the leg's pill, faded out by the dive.
        let overlayAlpha = RoadTripSegue.overlayAlpha(dive)
        if overlayAlpha > 0 {
            if let strip = Self.counterStrip(meters: timeline.drivenMeters(at: timeline.segmentStartTimes[segmentIndex] + localTime), canvas: size) {
                canvas.draw(strip.image, in: strip.rect, alpha: overlayAlpha)
            }
            if let legLabel {
                let label = CGSize(width: legLabel.width, height: legLabel.height)
                canvas.draw(legLabel, in: CGRect(
                    x: (size.width - label.width) / 2, y: size.height * 0.86 - label.height / 2,
                    width: label.width, height: label.height
                ), alpha: overlayAlpha)
            }
        }

        // Arrival dive: the map dims out as the destination photo takes over.
        if dive > 0 {
            let fade = RoadTripSegue.mapDim(dive)
            if fade > 0 {
                canvas.fill(RoadTripRGBA.black.withAlpha(fade))
            }
            if let destination = travel.route.last?.coordinate {
                let point = RoadTripSegue.clampedToMargins(
                    RoadTripAerialCamera.project(MKMapPoint(destination), in: rect, canvas: size), canvas: size
                )
                let pop = CGFloat(RoadTripSegue.pinPop(dive))
                let pinAlpha = RoadTripSegue.pinAlpha(dive)
                canvas.circle(center: point, radius: size.width * CGFloat(RoadTripMapStyle.pinRingDiameter) * 0.7 * pop,
                              color: RoadTripRGBA.white.withAlpha(pinAlpha))
                canvas.circle(center: point, radius: size.width * CGFloat(RoadTripMapStyle.pinDotDiameter) * 0.7 * pop,
                              color: RoadTripRGBA(RoadTripMapStyle.pin).withAlpha(pinAlpha))
                if let divePhoto = arriving.first {
                    let pinSize = CGSize(width: size.width * RoadTripSegue.thumbSizeFraction,
                                         height: size.width * RoadTripSegue.thumbSizeFraction * 0.75)
                    // The next stop's first frame: its photo, or its collage's first tile.
                    let thumb = RoadTripSegue.thumbnailRect(pinCenter: point, pinSize: pinSize, canvas: size, dive: dive, landing: divePhoto.tile.rect)
                    let radius: CGFloat = dive >= 0.99 ? 0 : 18 * (1 - dive)
                    canvas.drawFilled(divePhoto.image, in: thumb, alpha: RoadTripSegue.thumbnailAlpha(dive), mask: .roundedRect(radius: radius))
                }
                // A collage's other photos fade in with the dim, in place:
                // the dive's last frame is the collage's first.
                for photo in arriving.dropFirst() {
                    drawTile(on: canvas, photo.image, tile: photo.tile, alpha: RoadTripSegue.mapDim(dive))
                }
            }
        }

        // Slideshow→travel: the outgoing photos fade out over the map, framed
        // as the slideshow's last frame left them.
        let alpha = RoadTripSegue.outgoingPhotoAlpha(localTime: localTime)
        if alpha > 0 {
            if outgoing.count > 1 {
                // A collage's black between its tiles fades out with them.
                canvas.fill(RoadTripRGBA.black.withAlpha(alpha))
            }
            for photo in outgoing {
                drawTile(on: canvas, photo.image, tile: photo.tile, alpha: alpha * photo.tile.alpha)
            }
        }
    }

    // MARK: - Map drawing

    /// The snapshot to crop for `rect`: the sharpest one holding all of it,
    /// else the one showing most of it (internal for the tests).
    static func bestShot(_ shots: [MapShot], for rect: MKMapRect) -> MapShot? {
        if let sharpest = shots.filter({ $0.rect.contains(rect) }).min(by: { $0.rect.size.width < $1.rect.size.width }) {
            return sharpest
        }
        func overlap(_ shot: MapShot) -> Double {
            let common = shot.rect.intersection(rect)
            return common.isNull ? 0 : common.size.width * common.size.height
        }
        return shots.max { overlap($0) < overlap($1) }
    }

    /// The ground of `rect`: the crop of the best snapshot, scaled to the canvas.
    private func drawMap(on canvas: RoadTripFrameCanvas, shots: [MapShot], rect: MKMapRect) {
        guard let shot = Self.bestShot(shots, for: rect) else { return }
        let visible = rect.intersection(shot.rect)
        guard !visible.isNull, visible.size.width > 0, visible.size.height > 0 else { return }
        let image = shot.image
        let pixelsPerX = Double(image.width) / shot.rect.size.width
        let pixelsPerY = Double(image.height) / shot.rect.size.height
        let source = CGRect(
            x: (visible.minX - shot.rect.minX) * pixelsPerX,
            y: (visible.minY - shot.rect.minY) * pixelsPerY,
            width: visible.size.width * pixelsPerX,
            height: visible.size.height * pixelsPerY
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !source.isEmpty else { return }
        // Where those pixels lie on the ground, then on the canvas.
        let topLeft = RoadTripAerialCamera.project(MKMapPoint(
            x: shot.rect.minX + Double(source.minX) / pixelsPerX,
            y: shot.rect.minY + Double(source.minY) / pixelsPerY
        ), in: rect, canvas: canvas.size)
        let bottomRight = RoadTripAerialCamera.project(MKMapPoint(
            x: shot.rect.minX + Double(source.maxX) / pixelsPerX,
            y: shot.rect.minY + Double(source.maxY) / pixelsPerY
        ), in: rect, canvas: canvas.size)
        let width = CGFloat(image.width), height = CGFloat(image.height)
        canvas.draw(
            image,
            in: CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y),
            source: CGRect(x: source.minX / width, y: source.minY / height, width: source.width / width, height: source.height / height),
            alpha: 1, rotation: 0, mask: .none
        )
    }

    /// The trip's line: each leg drawn up to `drawn(segmentIndex)` of its arc,
    /// glow under white casing under color, at `alpha`.
    private func drawRoads(
        on canvas: RoadTripFrameCanvas, map: ExportMap, rect: MKMapRect, alpha: Double,
        drawn: (Int) -> Double
    ) {
        let size = canvas.size
        var lines: [[CGPoint]] = []
        for segment in map.roads.keys.sorted() {
            guard let road = map.roads[segment] else { continue }
            let end = drawn(segment)
            guard end > 0 else { continue }
            var points: [CGPoint] = []
            for (i, point) in road.points.enumerated() {
                let projected = RoadTripAerialCamera.project(point, in: rect, canvas: size)
                let fraction = road.fractions[i]
                if fraction <= end || i == 0 {
                    points.append(projected)
                    continue
                }
                // The partial segment up to the car.
                let previousFraction = road.fractions[i - 1]
                let t = (end - previousFraction) / max(fraction - previousFraction, 1e-9)
                let previous = points[points.count - 1]
                points.append(CGPoint(
                    x: previous.x + (projected.x - previous.x) * CGFloat(t),
                    y: previous.y + (projected.y - previous.y) * CGFloat(t)
                ))
                break
            }
            if points.count >= 2 { lines.append(points) }
        }
        guard !lines.isEmpty else { return }
        canvas.stroke(lines, styles: [
            (RoadTripRGBA(RoadTripMapStyle.routeGlow), size.width * CGFloat(RoadTripMapStyle.glowWidth)),
            (RoadTripRGBA(RoadTripMapStyle.casing), size.width * CGFloat(RoadTripMapStyle.casingWidth)),
            (RoadTripRGBA(RoadTripMapStyle.route), size.width * CGFloat(RoadTripMapStyle.lineWidth))
        ], alpha: alpha)
    }

    /// The pins of the stops up to `last` (film order).
    private func drawStops(on canvas: RoadTripFrameCanvas, map: ExportMap, upTo last: Int, rect: MKMapRect) {
        guard last >= 0 else { return }
        let size = canvas.size
        for stop in map.stops.prefix(last + 1) {
            let point = RoadTripAerialCamera.project(MKMapPoint(stop.coordinate.coordinate), in: rect, canvas: size)
            canvas.circle(center: point, radius: size.width * CGFloat(RoadTripMapStyle.pinRingDiameter) / 2, color: .white)
            canvas.circle(center: point, radius: size.width * CGFloat(RoadTripMapStyle.pinDotDiameter) / 2, color: RoadTripRGBA(RoadTripMapStyle.pin))
        }
    }

    /// The ending's photo pins: each stop's hero photo popping in, one after
    /// the other, in a white-rimmed circle above its pin.
    private func drawPhotoPins(on canvas: RoadTripFrameCanvas, map: ExportMap, progress: Double, rect: MKMapRect) {
        let size = canvas.size
        let diameter = size.width * CGFloat(RoadTripMapStyle.photoPinDiameter)
        let border = size.width * CGFloat(RoadTripMapStyle.photoPinBorder)
        // Laid out together (every stop with a photo, popped or not) so a
        // photo never jumps when the next one pops.
        let shown = map.stops.enumerated().filter { map.heroes[$0.element.clusterID] != nil }
        let pins = shown.map { RoadTripAerialCamera.project(MKMapPoint($0.element.coordinate.coordinate), in: rect, canvas: size) }
        let centers = RoadTripMapStyle.photoPinCenters(pins: pins, diameter: diameter, canvas: size)
        for ((index, stop), (point, center)) in zip(shown, zip(pins, centers)) {
            let pop = CGFloat(RoadTripMapStyle.photoPinPop(index: index, count: map.stops.count, endingProgress: progress))
            guard pop > 0.01, let image = map.heroes[stop.clusterID] else { continue }
            if pop > 0.5, RoadTripMapStyle.photoPinNeedsStem(center: center, pin: point, diameter: diameter) {
                canvas.stroke([[point, center]], styles: [(.white, size.width * CGFloat(RoadTripMapStyle.photoPinStemWidth))], alpha: 1)
            }
            let circle = CGRect(x: center.x - diameter * pop / 2, y: center.y - diameter * pop / 2, width: diameter * pop, height: diameter * pop)
            let rim = circle.insetBy(dx: -border * pop, dy: -border * pop)
            canvas.circleShadow(in: rim.offsetBy(dx: 0, dy: diameter * 0.04), blur: diameter * 0.12, color: RoadTripRGBA.black.withAlpha(0.45))
            canvas.circle(center: center, radius: rim.width / 2, color: .white)
            canvas.drawFilled(image, in: circle, mask: .ellipse)
        }
    }

    /// The 3D car seen from above, nose on `heading` (radians, clockwise from
    /// screen-up), with its shadow.
    private func drawTopCar(on canvas: RoadTripFrameCanvas, at point: CGPoint, heading: Double, size: CGFloat, color: RoadTripSettings.CarColor) {
        let step = 2 * Double.pi / Double(RoadTripCar3D.spriteCount)
        let nearest = (heading / step).rounded() * step
        let sprite = Self.shadowedSprite(RoadTripCar3D.sprite(forBearing: nearest, color: color), size: size)
        // Residual rotation keeps the turn continuous between sprite frames.
        canvas.draw(sprite.image, in: CGRect(
            x: point.x - sprite.side / 2, y: point.y - sprite.side / 2, width: sprite.side, height: sprite.side
        ), source: CGRect(x: 0, y: 0, width: 1, height: 1), alpha: 1, rotation: heading - nearest, mask: .none)
    }

    private final class ShadowedSprite: @unchecked Sendable {
        let image: CGImage
        let side: CGFloat
        init(image: CGImage, side: CGFloat) {
            self.image = image
            self.side = side
        }
    }

    private static let shadowedSprites: NSCache<NSString, ShadowedSprite> = {
        let cache = NSCache<NSString, ShadowedSprite>()
        cache.countLimit = 2 * RoadTripCar3D.spriteCount
        return cache
    }()

    /// The car `sprite` drawn `size` wide with its shadow, on a margin wide
    /// enough for the shadow's blur — made once per sprite and size (a blurred
    /// shadow costs more than the rest of a map frame).
    private static func shadowedSprite(_ sprite: CGImage, size: CGFloat) -> ShadowedSprite {
        let key = "\(ObjectIdentifier(sprite).hashValue)-\(Int(size.rounded()))" as NSString
        if let cached = shadowedSprites.object(forKey: key) { return cached }
        let margin = (size * 0.2).rounded(.up)
        let side = size + 2 * margin
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            // Shadow offsets are in the base space (y up): below the car.
            context.cgContext.setShadow(offset: CGSize(width: 0, height: -size * 0.03), blur: size * 0.08,
                                        color: UIColor.black.withAlphaComponent(0.5).cgColor)
            UIImage(cgImage: sprite).draw(in: CGRect(x: margin, y: margin, width: size, height: size))
        }.cgImage
        let made = ShadowedSprite(image: image ?? sprite, side: image == nil ? size : side)
        shadowedSprites.setObject(made, forKey: key)
        return made
    }

    /// The road driven so far, big over the top of the map: a strip drawn
    /// once per distinct text (the text and its blurred shadow cost several
    /// milliseconds) and stamped on every frame that shows it.
    private static func counterStrip(meters: Double, canvas: CGSize) -> CounterStrip? {
        let text = RoadTripTimeline.distanceText(meters: meters)
        let key = "\(Int(canvas.width))x\(Int(canvas.height))|\(text)" as NSString
        if let cached = counterStrips.object(forKey: key) { return cached }
        guard let made = counterStrip(text, canvas: canvas) else { return nil }
        counterStrips.setObject(made, forKey: key)
        return made
    }

    private final class CounterStrip: @unchecked Sendable {
        let image: CGImage
        let rect: CGRect
        init(image: CGImage, rect: CGRect) {
            self.image = image
            self.rect = rect
        }
    }

    private static let counterStrips: NSCache<NSString, CounterStrip> = {
        let cache = NSCache<NSString, CounterStrip>()
        cache.countLimit = 64
        return cache
    }()

    /// The counter `text` over a transparent strip the canvas' width, and
    /// where the strip sits on the canvas.
    private static func counterStrip(_ text: String, canvas: CGSize) -> CounterStrip? {
        let fontSize = canvas.width * 0.085
        let base = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: fontSize) } ?? base
        let string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor.white
        ])
        let textSize = string.size()
        let iconHeight = fontSize * 0.62
        let icon = UIImage(systemName: "car.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
        let iconWidth = icon.map { iconHeight * $0.size.width / max($0.size.height, 1) } ?? 0
        let gap = icon == nil ? 0 : fontSize * 0.25
        let total = iconWidth + gap + textSize.width
        let originX = (canvas.width - total) / 2
        let top = canvas.height * 0.09
        // Room for the shadow's blur above and below the text.
        let margin = (fontSize * 0.6).rounded(.up)
        let rect = CGRect(x: 0, y: top - margin, width: canvas.width, height: (textSize.height + 2 * margin).rounded(.up))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            let ctx = context.cgContext
            // Shadow offsets are in the context's base space (y up), as the
            // frame's: the same offset as before, below the text.
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.05), blur: fontSize * 0.25,
                          color: UIColor.black.withAlphaComponent(0.6).cgColor)
            icon?.draw(in: CGRect(x: originX, y: margin + (textSize.height - iconHeight) / 2, width: iconWidth, height: iconHeight))
            string.draw(at: CGPoint(x: originX + iconWidth + gap, y: margin))
        }.cgImage
        return image.map { CounterStrip(image: $0, rect: rect) }
    }

    private func drawCard(on canvas: RoadTripFrameCanvas, _ image: CGImage, progress: Double, fadeIn: Double, fadeOut: Double) {
        let size = canvas.size
        let p = min(max(progress, 0), 1)
        var alpha = 1.0
        if fadeIn > 0 { alpha = min(p / fadeIn, 1) }
        if fadeOut > 0 { alpha = min(alpha, max((1 - p) / fadeOut, 0)) }
        let scale = 0.94 + 0.06 * KenBurnsRecipe.smoothstep(min(p / max(fadeIn, 0.001), 1))
        let w = size.width * CGFloat(scale), h = size.height * CGFloat(scale)
        canvas.draw(image, in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h), alpha: alpha)
    }

    private func drawOverlayFade(on canvas: RoadTripFrameCanvas, _ image: CGImage, localTime: Double, duration: Double) {
        guard localTime < duration, duration > 0 else { return }
        let p = localTime / duration
        let alpha: Double = p < 0.25 ? p / 0.25 : (p > 0.75 ? max((1 - p) / 0.25, 0) : 1)
        let rise = (1 - KenBurnsRecipe.smoothstep(p < 0.25 ? p / 0.25 : 1)) * 24
        canvas.draw(image, in: CGRect(x: 0, y: -CGFloat(rise), width: canvas.size.width, height: canvas.size.height), alpha: alpha)
    }

    // MARK: - Geometry helpers

    private func aspectFillRect(image: CGImage, canvas: CGSize) -> CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0 else { return CGRect(origin: .zero, size: canvas) }
        let scale = max(canvas.width / iw, canvas.height / ih)
        let w = iw * scale, h = ih * scale
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }

    private func transformed(_ rect: CGRect, canvas: CGSize, transform: KenBurnsTransform) -> CGRect {
        let w = rect.width * CGFloat(transform.scale)
        let h = rect.height * CGFloat(transform.scale)
        let dx = CGFloat(transform.offsetX) * canvas.width
        let dy = CGFloat(transform.offsetY) * canvas.height
        return CGRect(x: rect.midX - w / 2 + dx, y: rect.midY - h / 2 + dy, width: w, height: h)
    }
}
