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
/// 4. Frame loop draws straight into `CVPixelBuffer`s from a reuse pool with
///    Core Graphics (no per-frame SwiftUI layout), streamed to `AVAssetWriter`.
///    The context is y-down: every bitmap goes through `drawUpright`.
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

        let photoCount = clusters.reduce(0) { $0 + $1.assets.count }
        let placeNames = RoadTripTimeline.dedupedPlaceNames(clusters.map { $0.placeName ?? "" })
        let meters = timeline.totalDrivenMeters
        let overMap = !RoadTripMapStop.stops(of: clusters).isEmpty
        RoadTripCar3D.warm()
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
        var shots: [MapShot] = []
        for (rect, oversample) in [(envelope, 2.0), (start, 1.5), (end, 1.5)] {
            if Task.isCancelled { break }
            if let shot = await snapshot(rect, canvas: canvas, oversample: CGFloat(oversample)) {
                shots.append(shot)
            }
        }
        return shots
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
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(config.size.width),
                AVVideoHeightKey: Int(config.size.height),
                // Explicit bitrate — encoder defaults smear motion on the
                // warped map planes.
                AVVideoAverageBitRateKey: 14_000_000
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(config.size.width),
                kCVPixelBufferHeightKey as String: Int(config.size.height)
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? APIError.decoding("Failed to start video writer")
        }
        writer.startSession(atSourceTime: .zero)

        var clusterByID: [String: RoadTripCluster] = [:]
        for cluster in clusters { clusterByID[cluster.id] = cluster }

        // The map: the trip's roads and stops, the overview snapshot now, each
        // leg's snapshots when the leg comes up (released after it, so peak
        // memory holds one leg's).
        var map = await prepareMap(clusters: clusters, timeline: timeline, images: images, canvas: config.size)
        var activeTravelIndex: Int?

        let totalFrames = max(1, Int((timeline.totalDuration * Double(config.fps)).rounded(.up)))
        var frameTime = CMTime.zero

        do {
            for frameIndex in 0..<totalFrames {
                try Task.checkCancellation()
                let t = Double(frameIndex) / Double(config.fps)

                let (segmentIndex, _) = timeline.localTime(at: t)
                if case .travel(let travel) = timeline.segments[segmentIndex] {
                    if activeTravelIndex != segmentIndex {
                        if let previous = activeTravelIndex {
                            map.legs[previous] = nil
                        }
                        activeTravelIndex = segmentIndex
                    }
                    if map.legs[segmentIndex] == nil {
                        map.legs[segmentIndex] = await snapshotLeg(travel: travel, canvas: config.size)
                    }
                } else if let previous = activeTravelIndex {
                    map.legs[previous] = nil
                    activeTravelIndex = nil
                }

                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool else { throw APIError.decoding("No pixel buffer pool") }
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard let buffer = pixelBuffer else { continue }

                drawFrame(
                    at: t, into: buffer,
                    clusters: clusters, clusterByID: clusterByID, timeline: timeline,
                    config: config, images: images, visuals: visuals, map: map
                )
                adaptor.append(buffer, withPresentationTime: frameTime)
                frameTime = CMTimeAdd(frameTime, CMTime(value: 1, timescale: Int32(config.fps)))
                progress(Double(frameIndex) / Double(totalFrames))
            }
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

    /// Draws the frame at `time` into `pixelBuffer` (internal for the tests).
    func drawFrame(
        at time: TimeInterval,
        into pixelBuffer: CVPixelBuffer,
        clusters: [RoadTripCluster],
        clusterByID: [String: RoadTripCluster],
        timeline: RoadTripTimeline,
        config: RoadTripRenderConfig,
        images: [String: CGImage],
        visuals: VisualAssets,
        map: ExportMap
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let data = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(
                data: data, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }

        // Flip to top-left coordinates so screen-space math matches the map
        // snapshots and the live player.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let canvas = CGSize(width: width, height: height)
        let aspect = Double(canvas.width / max(canvas.height, 1))

        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: canvas))

        let (segmentIndex, local) = timeline.localTime(at: time)
        switch timeline.segments[segmentIndex] {
        case .opening(let duration):
            let progress = local / max(duration, 0.001)
            if let rect = RoadTripAerialCamera.rect(for: .opening(progress: progress), timeline: timeline, stops: map.stops, aspect: aspect) {
                drawMap(ctx, shots: map.overview, rect: rect, canvas: canvas)
                drawRoads(ctx, map: map, rect: rect, canvas: canvas, alpha: CGFloat(RoadTripMapStyle.previewAlpha)) { _ in 1 }
                drawStops(ctx, map: map, upTo: map.stops.count - 1, rect: rect, canvas: canvas)
            }
            if let card = visuals.opening {
                drawCard(ctx, card, progress: progress, canvas: canvas, fadeIn: 0.15, fadeOut: 0)
            }
        case .slideshow(let slideshow):
            drawSlideshow(ctx, slideshow: slideshow, clusterByID: clusterByID, localTime: local, config: config, images: images, canvas: canvas)
            if let title = visuals.intertitles[slideshow.clusterID] {
                drawOverlayFade(ctx, title, localTime: local, duration: 1.5, canvas: canvas)
            }
            applyVignette(ctx, canvas: canvas)
        case .travel(let travel):
            drawTravel(
                ctx, travel: travel, segmentIndex: segmentIndex, localTime: local,
                timeline: timeline, map: map, legLabel: visuals.legLabels[segmentIndex], canvas: canvas,
                outgoingPhoto: neighborPhoto(at: segmentIndex - 1, edge: .last, timeline: timeline, clusterByID: clusterByID, images: images),
                divePhoto: neighborPhoto(at: segmentIndex + 1, edge: .first, timeline: timeline, clusterByID: clusterByID, images: images)
            )
        case .ending(let duration):
            let progress = local / max(duration, 0.001)
            if let rect = RoadTripAerialCamera.rect(for: .ending(progress: progress), timeline: timeline, stops: map.stops, aspect: aspect) {
                drawMap(ctx, shots: map.overview, rect: rect, canvas: canvas)
                drawRoads(ctx, map: map, rect: rect, canvas: canvas, alpha: 1) { _ in 1 }
                drawStops(ctx, map: map, upTo: map.stops.count - 1, rect: rect, canvas: canvas)
                drawPhotoPins(ctx, map: map, progress: progress, rect: rect, canvas: canvas)
            }
            if let card = visuals.ending {
                drawCard(ctx, card, progress: progress, canvas: canvas, fadeIn: 0.2, fadeOut: 0)
            }
        }
    }

    private func drawSlideshow(
        _ ctx: CGContext,
        slideshow: RoadTripTimeline.Slideshow,
        clusterByID: [String: RoadTripCluster],
        localTime: TimeInterval,
        config: RoadTripRenderConfig,
        images: [String: CGImage],
        canvas: CGSize
    ) {
        let frame = RoadTripSlideTiming.frame(slideshow: slideshow, localTime: localTime, reduceMotion: config.reduceMotion)
        guard let cluster = clusterByID[slideshow.clusterID] else { return }

        if slideshow.assetIndices.indices.contains(frame.currentIndex) {
            let assetIndex = slideshow.assetIndices[frame.currentIndex]
            if cluster.assets.indices.contains(assetIndex) {
                drawSlideImage(ctx, images[cluster.assets[assetIndex].id], transform: frame.currentTransform, canvas: canvas)
            }
        }
        if frame.crossfade > 0, let next = frame.nextIndex, slideshow.assetIndices.indices.contains(next) {
            let assetIndex = slideshow.assetIndices[next]
            if cluster.assets.indices.contains(assetIndex) {
                ctx.saveGState()
                ctx.setAlpha(CGFloat(frame.crossfade))
                drawSlideImage(ctx, images[cluster.assets[assetIndex].id], transform: frame.nextTransform ?? .identity, canvas: canvas)
                ctx.restoreGState()
            }
        }
    }

    private func drawSlideImage(_ ctx: CGContext, _ image: CGImage?, transform: KenBurnsTransform, canvas: CGSize) {
        guard let image else {
            ctx.setFillColor(UIColor(white: 0.1, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: canvas))
            return
        }
        let fill = aspectFillRect(image: image, canvas: canvas)
        let rect = transformed(fill, canvas: canvas, transform: transform)
        drawUpright(ctx, image, in: rect)
    }

    /// Draws `image` upright into `rect` of this renderer's y-down context.
    /// `CGContext.draw` lays an image out for a y-up space: called as is in
    /// the flipped context it renders every photo, card and sprite upside down.
    private func drawUpright(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    /// `image` aspect-filled into `rect` (centered, overflow clipped) and
    /// drawn upright — the photo framing of the live player.
    private func drawFilled(_ ctx: CGContext, _ image: CGImage, in rect: CGRect) {
        let fill = aspectFillRect(image: image, canvas: rect.size).offsetBy(dx: rect.minX, dy: rect.minY)
        ctx.saveGState()
        ctx.clip(to: rect)
        drawUpright(ctx, image, in: fill)
        ctx.restoreGState()
    }

    /// Which photo of the neighbor slideshow the transitions use.
    private enum PhotoEdge {
        case first
        case last
    }

    /// Photo shown by the slideshow segment at `index` — first or last asset —
    /// used for the map↔media transitions (dive photo on the arrival side,
    /// fading photo on the departure side). Travel legs are always sandwiched
    /// between slideshows, so the neighbors are the slideshow segments.
    private func neighborPhoto(
        at index: Int,
        edge: PhotoEdge,
        timeline: RoadTripTimeline,
        clusterByID: [String: RoadTripCluster],
        images: [String: CGImage]
    ) -> CGImage? {
        guard timeline.segments.indices.contains(index),
              case .slideshow(let slideshow) = timeline.segments[index],
              let cluster = clusterByID[slideshow.clusterID],
              let position = edge == .first ? slideshow.assetIndices.first : slideshow.assetIndices.last,
              cluster.assets.indices.contains(position) else { return nil }
        return images[cluster.assets[position].id]
    }

    private func drawTravel(
        _ ctx: CGContext,
        travel: RoadTripTimeline.Travel,
        segmentIndex: Int,
        localTime: TimeInterval,
        timeline: RoadTripTimeline,
        map: ExportMap,
        legLabel: CGImage?,
        canvas: CGSize,
        outgoingPhoto: CGImage?,
        divePhoto: CGImage?
    ) {
        guard travel.route.count >= 2, let shots = map.legs[segmentIndex], !shots.isEmpty else {
            ctx.setFillColor(UIColor(white: 0.06, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: canvas))
            return
        }
        let aspect = Double(canvas.width / max(canvas.height, 1))
        let rect = RoadTripAerialCamera.legRect(travel: travel, localTime: localTime, aspect: aspect)
        let timing = RoadTripTravelTiming.frame(travel: travel, localTime: localTime)
        let fraction = min(max(timing.routeDrawnFraction, 0), 1)
        let dive = RoadTripSegue.diveProgress(localTime: localTime, legDuration: travel.duration)

        // The ground, the trip's line (every leg already driven, this one up
        // to the car), the stops reached and the one ahead.
        drawMap(ctx, shots: shots, rect: rect, canvas: canvas)
        drawRoads(ctx, map: map, rect: rect, canvas: canvas, alpha: 1) { segment in
            segment < segmentIndex ? 1 : (segment == segmentIndex ? fraction : 0)
        }
        let destination = map.stops.firstIndex { $0.clusterID == travel.toClusterID } ?? (map.stops.count - 1)
        drawStops(ctx, map: map, upTo: destination, rect: rect, canvas: canvas)

        // The car, nose along the road (north-up: heading = screen angle).
        let car = RoadTripAerialCamera.project(MKMapPoint(timing.carCoordinate.coordinate), in: rect, canvas: canvas)
        let heading = RoadTripAerialCamera.carHeading(travel: travel, localTime: localTime)
        drawTopCar(ctx, at: car, heading: heading, size: canvas.width * CGFloat(RoadTripMapStyle.carSpriteSize))

        // The road counter and the leg's pill.
        drawCounter(ctx, meters: timeline.drivenMeters(at: timeline.segmentStartTimes[segmentIndex] + localTime), canvas: canvas)
        if let legLabel {
            let size = CGSize(width: legLabel.width, height: legLabel.height)
            drawUpright(ctx, legLabel, in: CGRect(
                x: (canvas.width - size.width) / 2, y: canvas.height * 0.86 - size.height / 2,
                width: size.width, height: size.height
            ))
        }

        // Arrival dive: the map dims out as the destination photo takes over.
        if dive > 0 {
            let fade = RoadTripSegue.mapFade(dive)
            if fade > 0 {
                ctx.saveGState()
                ctx.setAlpha(CGFloat(fade * 0.92))
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(CGRect(origin: .zero, size: canvas))
                ctx.restoreGState()
            }
            if let destination = travel.route.last?.coordinate {
                let point = RoadTripSegue.clampedToMargins(
                    RoadTripAerialCamera.project(MKMapPoint(destination), in: rect, canvas: canvas), canvas: canvas
                )
                let pop = RoadTripSegue.pinPop(dive)
                drawDot(ctx, at: point, radius: canvas.width * CGFloat(RoadTripMapStyle.pinRingDiameter) * 0.7 * CGFloat(pop), color: .white)
                drawDot(ctx, at: point, radius: canvas.width * CGFloat(RoadTripMapStyle.pinDotDiameter) * 0.7 * CGFloat(pop), color: RoadTripMapStyle.pin)
                if let divePhoto {
                    let pinSize = CGSize(width: canvas.width * RoadTripSegue.thumbSizeFraction,
                                         height: canvas.width * RoadTripSegue.thumbSizeFraction * 0.75)
                    let thumb = RoadTripSegue.thumbnailRect(pinCenter: point, pinSize: pinSize, canvas: canvas, dive: dive)
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(RoadTripSegue.thumbnailAlpha(dive)))
                    let radius: CGFloat = dive >= 0.99 ? 0 : 18 * (1 - dive)
                    ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: radius, cornerHeight: radius, transform: nil))
                    ctx.clip()
                    drawFilled(ctx, divePhoto, in: thumb)
                    ctx.restoreGState()
                }
            }
        }

        // Slideshow→travel: the outgoing photo fades out over the map.
        if let outgoingPhoto {
            let alpha = RoadTripSegue.outgoingPhotoAlpha(localTime: localTime)
            if alpha > 0 {
                ctx.saveGState()
                ctx.setAlpha(CGFloat(alpha))
                drawFilled(ctx, outgoingPhoto, in: CGRect(origin: .zero, size: canvas))
                ctx.restoreGState()
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
    private func drawMap(_ ctx: CGContext, shots: [MapShot], rect: MKMapRect, canvas: CGSize) {
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
        guard !source.isEmpty, let cropped = image.cropping(to: source) else { return }
        // Where the cropped pixels lie on the ground, then on the canvas.
        let topLeft = RoadTripAerialCamera.project(MKMapPoint(
            x: shot.rect.minX + Double(source.minX) / pixelsPerX,
            y: shot.rect.minY + Double(source.minY) / pixelsPerY
        ), in: rect, canvas: canvas)
        let bottomRight = RoadTripAerialCamera.project(MKMapPoint(
            x: shot.rect.minX + Double(source.maxX) / pixelsPerX,
            y: shot.rect.minY + Double(source.maxY) / pixelsPerY
        ), in: rect, canvas: canvas)
        ctx.saveGState()
        ctx.interpolationQuality = .high
        drawUpright(ctx, cropped, in: CGRect(
            x: topLeft.x, y: topLeft.y,
            width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y
        ))
        ctx.restoreGState()
    }

    /// The trip's line: each leg drawn up to `drawn(segmentIndex)` of its arc,
    /// glow under white casing under color, at `alpha`.
    private func drawRoads(
        _ ctx: CGContext, map: ExportMap, rect: MKMapRect, canvas: CGSize, alpha: CGFloat,
        drawn: (Int) -> Double
    ) {
        var paths: [CGPath] = []
        for segment in map.roads.keys.sorted() {
            guard let road = map.roads[segment] else { continue }
            let end = drawn(segment)
            guard end > 0 else { continue }
            var points: [CGPoint] = []
            for (i, point) in road.points.enumerated() {
                let projected = RoadTripAerialCamera.project(point, in: rect, canvas: canvas)
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
            guard points.count >= 2 else { continue }
            let path = CGMutablePath()
            path.addLines(between: points)
            paths.append(path)
        }
        guard !paths.isEmpty else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let strokes: [(UIColor, Double)] = [
            (RoadTripMapStyle.routeGlow, RoadTripMapStyle.glowWidth),
            (RoadTripMapStyle.casing, RoadTripMapStyle.casingWidth),
            (RoadTripMapStyle.route, RoadTripMapStyle.lineWidth)
        ]
        for (color, width) in strokes {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(canvas.width * CGFloat(width))
            for path in paths {
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The pins of the stops up to `last` (film order).
    private func drawStops(_ ctx: CGContext, map: ExportMap, upTo last: Int, rect: MKMapRect, canvas: CGSize) {
        guard last >= 0 else { return }
        for stop in map.stops.prefix(last + 1) {
            let point = RoadTripAerialCamera.project(MKMapPoint(stop.coordinate.coordinate), in: rect, canvas: canvas)
            drawDot(ctx, at: point, radius: canvas.width * CGFloat(RoadTripMapStyle.pinRingDiameter) / 2, color: .white)
            drawDot(ctx, at: point, radius: canvas.width * CGFloat(RoadTripMapStyle.pinDotDiameter) / 2, color: RoadTripMapStyle.pin)
        }
    }

    /// The ending's photo pins: each stop's hero photo popping in, one after
    /// the other, in a white-rimmed circle above its pin.
    private func drawPhotoPins(_ ctx: CGContext, map: ExportMap, progress: Double, rect: MKMapRect, canvas: CGSize) {
        let diameter = canvas.width * CGFloat(RoadTripMapStyle.photoPinDiameter)
        let border = canvas.width * CGFloat(RoadTripMapStyle.photoPinBorder)
        for (index, stop) in map.stops.enumerated() {
            let pop = CGFloat(RoadTripMapStyle.photoPinPop(index: index, count: map.stops.count, endingProgress: progress))
            guard pop > 0.01, let image = map.heroes[stop.clusterID] else { continue }
            let point = RoadTripAerialCamera.project(MKMapPoint(stop.coordinate.coordinate), in: rect, canvas: canvas)
            let center = CGPoint(x: point.x, y: point.y - diameter * 0.62)
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: pop, y: pop)
            let circle = CGRect(x: -diameter / 2, y: -diameter / 2, width: diameter, height: diameter)
            ctx.setShadow(offset: CGSize(width: 0, height: -diameter * 0.04), blur: diameter * 0.12,
                          color: UIColor.black.withAlphaComponent(0.45).cgColor)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillEllipse(in: circle.insetBy(dx: -border, dy: -border))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addEllipse(in: circle)
            ctx.clip()
            drawFilled(ctx, image, in: circle)
            ctx.restoreGState()
        }
    }

    /// The 3D car seen from above, nose on `heading` (radians, clockwise from
    /// screen-up), with its shadow.
    private func drawTopCar(_ ctx: CGContext, at point: CGPoint, heading: Double, size: CGFloat) {
        let step = 2 * Double.pi / Double(RoadTripCar3D.spriteCount)
        let nearest = (heading / step).rounded() * step
        let sprite = RoadTripCar3D.sprite(forBearing: nearest)
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        // Residual rotation keeps the turn continuous between sprite frames.
        ctx.rotate(by: CGFloat(heading - nearest))
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.03), blur: size * 0.08,
                      color: UIColor.black.withAlphaComponent(0.5).cgColor)
        drawUpright(ctx, sprite, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
        ctx.restoreGState()
    }

    /// The road driven so far, big over the top of the map.
    private func drawCounter(_ ctx: CGContext, meters: Double, canvas: CGSize) {
        let fontSize = canvas.width * 0.085
        let base = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: fontSize) } ?? base
        let string = NSAttributedString(string: RoadTripTimeline.distanceText(meters: meters), attributes: [
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

        UIGraphicsPushContext(ctx)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.05), blur: fontSize * 0.25,
                      color: UIColor.black.withAlphaComponent(0.6).cgColor)
        icon?.draw(in: CGRect(x: originX, y: top + (textSize.height - iconHeight) / 2, width: iconWidth, height: iconHeight))
        string.draw(at: CGPoint(x: originX + iconWidth + gap, y: top))
        ctx.restoreGState()
        UIGraphicsPopContext()
    }

    private func drawDot(_ ctx: CGContext, at point: CGPoint, radius: CGFloat, color: UIColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    private func drawCard(_ ctx: CGContext, _ image: CGImage, progress: Double, canvas: CGSize, fadeIn: Double, fadeOut: Double) {
        let p = min(max(progress, 0), 1)
        var alpha = 1.0
        if fadeIn > 0 { alpha = min(p / fadeIn, 1) }
        if fadeOut > 0 { alpha = min(alpha, max((1 - p) / fadeOut, 0)) }
        let scale = 0.94 + 0.06 * KenBurnsRecipe.smoothstep(min(p / max(fadeIn, 0.001), 1))
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        let w = canvas.width * CGFloat(scale), h = canvas.height * CGFloat(scale)
        drawUpright(ctx, image, in: CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h))
        ctx.restoreGState()
    }

    private func drawOverlayFade(_ ctx: CGContext, _ image: CGImage, localTime: Double, duration: Double, canvas: CGSize) {
        guard localTime < duration, duration > 0 else { return }
        let p = localTime / duration
        let alpha: Double = p < 0.25 ? p / 0.25 : (p > 0.75 ? max((1 - p) / 0.25, 0) : 1)
        let rise = (1 - KenBurnsRecipe.smoothstep(p < 0.25 ? p / 0.25 : 1)) * 24
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        drawUpright(ctx, image, in: CGRect(x: 0, y: -CGFloat(rise), width: canvas.width, height: canvas.height))
        ctx.restoreGState()
    }

    private func applyVignette(_ ctx: CGContext, canvas: CGSize) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.45).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.55, 1.0]) else { return }
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let radius = max(canvas.width, canvas.height) * 0.72
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
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
