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

/// Renders the deterministic road-trip timeline into an H.264 `.mp4`.
///
/// Pipeline (optimized):
/// 1. Photos downloaded once (authenticated), decoded once to `CGImage`.
/// 2. Map legs snapshotted once via `MKMapSnapshotter` — a chain of window
///    regions per leg covering the whole route (portrait, night-mode overlay
///    applied at draw time).
/// 3. Title cards pre-rendered once via `ImageRenderer`.
/// 4. Frame loop draws straight into `CVPixelBuffer`s from a reuse pool with
///    Core Graphics (no per-frame SwiftUI layout), streamed to `AVAssetWriter`.
/// The live player shares the same timing math and the same chase-camera
/// geometry (`RoadTripDriveCamera`); the player renders real 3D MapKit while
/// the export warps the 2D snapshots into that driving perspective, so car
/// positions, headings and motion match.
final class RoadTripVideoRenderer: @unchecked Sendable {

    /// The process-wide road-trip session (`ServerSessions.roadTrip`): trust
    /// store aware, never built per call.
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    // MARK: - Prepared visuals

    /// One snapshot window of a map leg: the image, the route points mapped
    /// into its pixel space (parallel `fractions` of the route arc length),
    /// and the exact map-point → pixel affine.
    private struct MapFrame {
        let base: CGImage
        let points: [CGPoint]
        let fractions: [Double]
        let affine: RoadTripAffine
        let window: RoadTripDriveWindow
    }

    private struct VisualAssets {
        let opening: CGImage?
        let ending: CGImage?
        let intertitles: [String: CGImage]
    }

    /// Reused across every frame of the map warp (no per-frame CALayer alloc).
    private let warpLayer = CALayer()

    // MARK: - Public entry point

    func render(
        clusters: [RoadTripCluster],
        timeline: RoadTripTimeline,
        config: RoadTripRenderConfig,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let images = try await preloadImages(clusters: clusters, timeline: timeline, config: config)
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
        config: RoadTripRenderConfig
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
        let ids = Array(needed)
        var result: [String: CGImage] = [:]
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
        session: URLSession
    ) async -> (String, CGImage?) {
        guard let asset else { return (id, nil) }
        let url = ImmichAssetURL.thumbnail(
            assetId: id, thumbhash: asset.thumbhash ?? "", baseURL: config.baseURL, size: .preview
        )
        do {
            let (data, _) = try await AssetFileTransfer.fetchData(from: url, token: config.token, session: session)
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
        for (i, cluster) in clusters.enumerated() {
            let name = cluster.placeName?.isEmpty == false ? cluster.placeName! : String(localized: "Stop \(i + 1)")
            intertitles[cluster.id] = Self.intertitleCard(placeName: name, size: config.size)
        }

        let photoCount = clusters.reduce(0) { $0 + $1.assets.count }
        let placeNames = RoadTripTimeline.dedupedPlaceNames(clusters.map { $0.placeName ?? "" })
        RoadTripCar3D.warm()
        return VisualAssets(
            opening: Self.openingCard(
                albumTitle: config.albumTitle, photoCount: photoCount,
                placeCount: placeNames.count, size: config.size
            ),
            ending: Self.endingCard(
                albumTitle: config.albumTitle, places: placeNames, size: config.size
            ),
            intertitles: intertitles
        )
    }

    /// Snapshots a single travel leg's map windows. Called lazily per leg (not
    /// all at once) so the export's peak memory stays bounded to one leg's
    /// snapshots instead of the whole trip's.
    @MainActor
    private func snapshotLeg(
        travel: RoadTripTimeline.Travel,
        config: RoadTripRenderConfig
    ) async -> [MapFrame] {
        guard travel.route.count >= 2 else { return [] }
        // Densify once per leg so the warped polylines stay smooth at the
        // driving view's zoom level.
        let cumulative = RoadTripTravelTiming.cumulativeLengths(travel.route)
        let total = cumulative.last ?? 0
        let fractions = cumulative.map { total > 0 ? $0 / total : 0 }
        let dense = RoadTripDriveCamera.densified(route: travel.route, fractions: fractions, spacing: 40)
        let windows = RoadTripDriveCamera.windows(travel: travel, canvas: config.size)
        var frames: [MapFrame] = []
        for window in windows {
            do {
                let snapshot = try await makeSnapshot(region: window.region, size: config.size)
                guard let cg = snapshot.image.cgImage else { continue }
                let affine = Self.affine(for: snapshot, region: window.region)
                var points: [CGPoint] = []
                var denseFracs: [Double] = []
                for (i, point) in dense.points.enumerated() {
                    guard dense.fractions[i] >= window.startFraction - 0.05 else { continue }
                    let mp = MKMapPoint(point.coordinate)
                    points.append(affine.point(CGPoint(x: mp.x, y: mp.y)))
                    denseFracs.append(dense.fractions[i])
                }
                frames.append(MapFrame(
                    base: cg, points: points, fractions: denseFracs,
                    affine: affine, window: window
                ))
            } catch {
                // Fallback: no map — drawTravel renders a dark frame.
            }
        }
        return frames
    }

    @MainActor
    private func makeSnapshot(region: MKCoordinateRegion, size: CGSize) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.size = size
        // 2× so the street-level chase view (which magnifies the snapshot's
        // lower half ~6×) stays crisp instead of soft. Peak memory stays
        // bounded: windows are snapshotted lazily per leg.
        options.scale = 2.0
        options.mapType = .mutedStandard
        options.pointOfInterestFilter = .excludingAll
        // options.showsTraffic = false  // removed in iOS 26
        options.region = region
        let snapshotter = MKMapSnapshotter(options: options)
        return try await withTaskCancellationHandler {
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
    }

    /// Exact map-point → snapshot-pixel affine, derived from the snapshot's own
    /// `point(for:)` at the region center and a corner (no region rounding).
    private static func affine(for snapshot: MKMapSnapshotter.Snapshot, region: MKCoordinateRegion) -> RoadTripAffine {
        let center = region.center
        let corner = CLLocationCoordinate2D(
            latitude: center.latitude + region.span.latitudeDelta / 2,
            longitude: center.longitude + region.span.longitudeDelta / 2
        )
        let p0 = snapshot.point(for: center)
        let p1 = snapshot.point(for: corner)
        let m0 = MKMapPoint(center)
        let m1 = MKMapPoint(corner)
        let scaleX = (p1.x - p0.x) / max(m1.x - m0.x, 1e-9)
        let scaleY = (p1.y - p0.y) / max(m1.y - m0.y, 1e-9)
        return RoadTripAffine(
            scaleX: scaleX, scaleY: scaleY,
            offsetX: p0.x - m0.x * scaleX, offsetY: p0.y - m0.y * scaleY
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
    private static func drawCentered(_ items: [(NSAttributedString, CGFloat)], in size: CGSize, gap: CGFloat, centerY: CGFloat) {
        let inset: CGFloat = 64
        let width = size.width - inset * 2
        let totalHeight = items.reduce(0) { $0 + $1.1 } + gap * CGFloat(max(items.count - 1, 0))
        var y = centerY - totalHeight / 2
        for (string, h) in items {
            string.draw(in: CGRect(x: inset, y: y, width: width, height: h))
            y += h + gap
        }
    }

    private static func openingCard(albumTitle: String, photoCount: Int, placeCount: Int, size: CGSize) -> CGImage? {
        render(size, opaque: true) { canvas in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: canvas))
            let kicker = text("ROAD TRIP", font: .systemFont(ofSize: 28, weight: .semibold), color: .white.withAlphaComponent(0.7), kern: 6)
            let title = text(albumTitle, font: .systemFont(ofSize: 72, weight: .bold), color: .white)
            let sub = text(String(localized: "\(photoCount) photos · \(placeCount) places"), font: .systemFont(ofSize: 30, weight: .regular), color: .white.withAlphaComponent(0.85))
            let width = canvas.width - 128
            drawCentered(
                [(kicker, height(kicker, width: width)), (title, height(title, width: width)), (sub, height(sub, width: width))],
                in: canvas, gap: 48, centerY: canvas.height / 2
            )
        }
    }

    private static func endingCard(albumTitle: String, places: [String], size: CGSize) -> CGImage? {
        render(size, opaque: true) { canvas in
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
            let kicker = text("ROAD TRIP", font: .systemFont(ofSize: 28, weight: .semibold), color: UIColor(red: 1, green: 0.82, blue: 0.62, alpha: 0.9), kern: 6)
            let title = text(albumTitle, font: .systemFont(ofSize: 64, weight: .bold), color: .white)
            let width = canvas.width - 128
            var items: [(NSAttributedString, CGFloat)] = [
                (kicker, height(kicker, width: width)),
                (title, height(title, width: width))
            ]
            for place in places.filter({ !$0.isEmpty }) {
                let line = text(place, font: .systemFont(ofSize: 30, weight: .regular), color: .white.withAlphaComponent(0.85))
                items.append((line, height(line, width: width)))
            }
            drawCentered(items, in: canvas, gap: 28, centerY: canvas.height / 2)
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

        // Map windows are snapshotted lazily per leg and released when the
        // player leaves it, bounding peak memory to one leg's snapshots.
        var mapFrames: [Int: [MapFrame]] = [:]
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
                            mapFrames[previous] = nil
                        }
                        activeTravelIndex = segmentIndex
                    }
                    if mapFrames[segmentIndex] == nil {
                        mapFrames[segmentIndex] = await snapshotLeg(travel: travel, config: config)
                    }
                } else if let previous = activeTravelIndex {
                    mapFrames[previous] = nil
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
                    config: config, images: images, visuals: visuals, mapFrames: mapFrames
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

    // MARK: - Frame drawing

    private func drawFrame(
        at time: TimeInterval,
        into pixelBuffer: CVPixelBuffer,
        clusters: [RoadTripCluster],
        clusterByID: [String: RoadTripCluster],
        timeline: RoadTripTimeline,
        config: RoadTripRenderConfig,
        images: [String: CGImage],
        visuals: VisualAssets,
        mapFrames: [Int: [MapFrame]]
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

        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: canvas))

        let (segmentIndex, local) = timeline.localTime(at: time)
        switch timeline.segments[segmentIndex] {
        case .opening(let duration):
            if let card = visuals.opening {
                drawCard(ctx, card, progress: local / max(duration, 0.001), canvas: canvas, fadeIn: 0.6, fadeOut: 0.5)
            }
        case .slideshow(let slideshow):
            drawSlideshow(ctx, slideshow: slideshow, clusterByID: clusterByID, localTime: local, config: config, images: images, canvas: canvas)
            if let title = visuals.intertitles[slideshow.clusterID] {
                drawOverlayFade(ctx, title, localTime: local, duration: 1.5, canvas: canvas)
            }
        case .travel(let travel):
            drawTravel(
                ctx, travel: travel, segmentIndex: segmentIndex, localTime: local,
                mapFrames: mapFrames, canvas: canvas,
                outgoingPhoto: neighborPhoto(at: segmentIndex - 1, edge: .last, timeline: timeline, clusterByID: clusterByID, images: images),
                divePhoto: neighborPhoto(at: segmentIndex + 1, edge: .first, timeline: timeline, clusterByID: clusterByID, images: images)
            )
        case .ending(let duration):
            if let card = visuals.ending {
                drawCard(ctx, card, progress: local / max(duration, 0.001), canvas: canvas, fadeIn: 0.8, fadeOut: 0)
            }
        }

        // The map legs keep their clean daylight look — no vignette.
        if case .travel = timeline.segments[segmentIndex] { return }
        applyVignette(ctx, canvas: canvas)
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
        ctx.draw(image, in: rect)
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
        mapFrames: [Int: [MapFrame]],
        canvas: CGSize,
        outgoingPhoto: CGImage?,
        divePhoto: CGImage?
    ) {
        let timing = RoadTripTravelTiming.frame(travel: travel, localTime: localTime)
        guard let windows = mapFrames[segmentIndex],
              let active = activeWindow(fraction: timing.progress, windows: windows) else {
            ctx.setFillColor(UIColor(white: 0.06, alpha: 1).cgColor)
            ctx.fill(CGRect(origin: .zero, size: canvas))
            return
        }

        // Chase-camera homography: the look-ahead rect ahead of the car
        // (rotated to the bearing, in map space) projected onto the canvas
        // trapezoid. Same geometry the live player uses.
        let drive = RoadTripDriveCamera.frame(travel: travel, localTime: localTime, canvas: canvas)
        let pixelCorners = drive.sourceCorners.map { active.affine.point($0) }
        let matrix = RoadTripMatrix3.homography(from: pixelCorners, to: drive.destinationCorners)
        let cumulative = RoadTripTravelTiming.cumulativeLengths(travel.route)
        let total = cumulative.last ?? 0
        let dive = RoadTripSegue.diveProgress(localTime: localTime, legDuration: travel.duration)

        // Sky + dark base (the trapezoid leaves the top corners uncovered).
        drawSky(ctx, canvas: canvas, lookAheadMeters: drive.lookAheadMeters)

        // Warped map plane, crossfaded onto the following window near the end
        // of this one so the snapshot switch never pops.
        drawWarpedMap(ctx, image: active.base, matrix: matrix, canvas: canvas)
        if let next = windows.first(where: { $0.window.startFraction > active.window.startFraction + 0.001 }) {
            let fadeSpan = min(0.12, RoadTripDriveCamera.windowOverlapMeters / max(total, 1))
            let fadeStart = active.window.endFraction - fadeSpan
            if timing.progress > fadeStart {
                let alpha = min(max((timing.progress - fadeStart) / fadeSpan, 0), 1)
                let nextCorners = drive.sourceCorners.map { next.affine.point($0) }
                let nextMatrix = RoadTripMatrix3.homography(from: nextCorners, to: drive.destinationCorners)
                ctx.saveGState()
                ctx.setAlpha(CGFloat(alpha))
                drawWarpedMap(ctx, image: next.base, matrix: nextMatrix, canvas: canvas)
                ctx.restoreGState()
            }
        }

        // Atmospheric haze just below the horizon: masks the far-field
        // minification aliasing of the warp and adds depth.
        drawHorizonHaze(ctx, canvas: canvas, lookAheadMeters: drive.lookAheadMeters)

        // Route strokes in the warped space: history up to the car (bright),
        // upcoming road (gray, lights up under the wheels as the car passes).
        // Bounded to the visible fraction range so the path stays short.
        let carFraction = timing.routeDrawnFraction
        let backFloor = max(0, carFraction - 0.04)
        let lookAheadFraction = min(1, carFraction + drive.lookAheadMeters / max(total, 1))
        let carMP = MKMapPoint(timing.carCoordinate.coordinate)
        let carPixel = active.affine.point(CGPoint(x: carMP.x, y: carMP.y))
        let car = matrix.transformed(carPixel)

        var history: [CGPoint] = []
        var ahead: [CGPoint] = []
        for (i, point) in active.points.enumerated() {
            let fraction = active.fractions[i]
            guard fraction >= backFloor else { continue }
            let mapped = matrix.transformed(point)
            if fraction <= carFraction + 1e-9 {
                history.append(mapped)
            } else if fraction <= lookAheadFraction + 1e-9 {
                ahead.append(mapped)
            }
        }
        if history.last != car { history.append(car) }
        if !ahead.isEmpty { ahead.insert(car, at: 0) }

        if history.count >= 2 { strokeRoute(ctx, points: history, style: .history) }
        if ahead.count >= 2 {
            ctx.saveGState()
            ctx.setAlpha(0.8)
            strokeRoute(ctx, points: ahead, style: .upcoming)
            ctx.restoreGState()
        }

        // Pulsing departure dot at the route start.
        if let first = history.first, within(first, canvas: canvas) {
            let pulse = 0.5 + 0.5 * sin(2 * .pi * localTime * 1.2)
            ctx.saveGState()
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.25 + 0.3 * pulse).cgColor)
            ctx.fillEllipse(in: CGRect(x: first.x - 16 - pulse * 5, y: first.y - 16 - pulse * 5, width: 32 + pulse * 10, height: 32 + pulse * 10))
            ctx.restoreGState()
            drawDot(ctx, at: first, radius: 10, color: .white)
        }

        // The car's on-screen yaw comes from the SAME heading rail as the
        // camera (sampled ahead of the car), so it noses into corners early
        // without a second, differently-smoothed rail fighting the camera —
        // the old dual-rail yaw swung tens of degrees through hairpins.
        let roadAngle = RoadTripDriveCamera.carYaw(travel: travel, localTime: localTime, bearing: drive.bearing)
        let carSize = canvas.width * 0.38 * RoadTripDriveCamera.carSpriteScale(lookAheadMeters: drive.lookAheadMeters)
        drawChaseCar(ctx, at: car, roadAngle: roadAngle, size: carSize)

        // Static destination ring during the leg; the animated pin + dive take
        // over in the arrival window.
        if dive == 0, let end = ahead.last, within(end, canvas: canvas) {
            drawDot(ctx, at: end, radius: 12, color: .white)
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
                let destMP = MKMapPoint(destination)
                let dest = matrix.transformed(active.affine.point(CGPoint(x: destMP.x, y: destMP.y)))
                let clamped = CGPoint(
                    x: min(max(dest.x, canvas.width * 0.12), canvas.width * 0.88),
                    y: min(max(dest.y, canvas.height * 0.15), canvas.height * 0.85)
                )
                let pop = RoadTripSegue.pinPop(dive)
                drawDot(ctx, at: clamped, radius: 16 * pop, color: .white)
                drawDot(ctx, at: clamped, radius: 10 * pop, color: UIColor(red: 0.95, green: 0.25, blue: 0.22, alpha: 1))
                if let divePhoto {
                    let pinSize = CGSize(width: canvas.width * RoadTripSegue.thumbSizeFraction,
                                         height: canvas.width * RoadTripSegue.thumbSizeFraction * 0.75)
                    let rect = RoadTripSegue.thumbnailRect(pinCenter: clamped, pinSize: pinSize, canvas: canvas, dive: dive)
                    ctx.saveGState()
                    ctx.setAlpha(CGFloat(RoadTripSegue.thumbnailAlpha(dive)))
                    let radius: CGFloat = dive >= 0.99 ? 0 : 18 * (1 - dive)
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                    ctx.clip()
                    ctx.draw(divePhoto, in: rect)
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
                ctx.draw(outgoingPhoto, in: CGRect(origin: .zero, size: canvas))
                ctx.restoreGState()
            }
        }
    }

    /// Snapshot window whose fraction range contains `fraction` (nearest as
    /// fallback, e.g. at the leg boundaries).
    private func activeWindow(fraction: Double, windows: [MapFrame]) -> MapFrame? {
        guard !windows.isEmpty else { return nil }
        if let hit = windows.first(where: {
            fraction >= $0.window.startFraction - 0.001 && fraction <= $0.window.endFraction + 0.001
        }) {
            return hit
        }
        return windows.min { abs(fraction - $0.window.midFraction) < abs(fraction - $1.window.midFraction) }
    }

    /// Daylight sky: a soft blue → horizon-haze gradient above the horizon
    /// line, over a matching full-canvas base (the ground/corners the
    /// trapezoid doesn't cover) so the map keeps its clean daytime look. The
    /// horizon follows the aerial blend — almost no sky at full zoom-out.
    private func drawSky(_ ctx: CGContext, canvas: CGSize, lookAheadMeters: Double) {
        let horizonY = CGFloat(RoadTripDriveCamera.horizonFractionY(lookAheadMeters: lookAheadMeters)) * canvas.height
        let haze = UIColor(red: 0.78, green: 0.82, blue: 0.87, alpha: 1).cgColor
        ctx.setFillColor(haze)
        ctx.fill(CGRect(origin: .zero, size: canvas))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let colors = [
            UIColor(red: 0.52, green: 0.62, blue: 0.74, alpha: 1).cgColor,
            haze
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: horizonY), options: [])
    }

    /// Soft band of horizon haze fading out below the horizon line — hides the
    /// warp's far-field aliasing (the map is minified ~7× there) and reads as
    /// atmospheric depth.
    private func drawHorizonHaze(_ ctx: CGContext, canvas: CGSize, lookAheadMeters: Double) {
        let horizonY = CGFloat(RoadTripDriveCamera.horizonFractionY(lookAheadMeters: lookAheadMeters)) * canvas.height
        let bandHeight = canvas.height * 0.18
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let haze = UIColor(red: 0.78, green: 0.82, blue: 0.87, alpha: 1)
        let colors = [
            haze.withAlphaComponent(0.85).cgColor,
            haze.withAlphaComponent(0).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: horizonY - 1, width: canvas.width, height: bandHeight + 1))
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: horizonY),
            end: CGPoint(x: 0, y: horizonY + bandHeight),
            options: []
        )
        ctx.restoreGState()
    }

    /// Rasterizes the snapshot into the canvas trapezoid via a 3D layer
    /// transform (CALayer honors the projective divide, so the warp is exact).
    private func drawWarpedMap(_ ctx: CGContext, image: CGImage, matrix: RoadTripMatrix3, canvas: CGSize) {
        warpLayer.bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        warpLayer.position = .zero
        warpLayer.anchorPoint = .zero
        warpLayer.contents = image
        // CALayer content space is y-up; the homography is y-down (image
        // pixels / CG context), so flip before warping.
        let flip = RoadTripMatrix3(1, 0, 0, 0, -1, Double(image.height), 0, 0, 1)
        warpLayer.transform = matrix.multiplied(by: flip).catTransform3D
        warpLayer.render(in: ctx)
    }

    private func drawChaseCar(_ ctx: CGContext, at point: CGPoint, roadAngle: Double, size: CGFloat) {
        let contact = RoadTripCar3D.chaseContactFraction
        // The sprite's own yaw carries the on-screen direction: the chase
        // camera is pitched, so the yaw is the inverse-compressed road angle.
        let yaw = RoadTripCar3D.chaseYaw(forScreenAngle: roadAngle)
        let frameYaw = RoadTripCar3D.chaseNearestYaw(yaw)
        let sprite = RoadTripCar3D.chaseSprite(forBearing: frameYaw)
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        // Soft ground shadow under the car (rotated with it).
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.25).cgColor)
        ctx.fillEllipse(in: CGRect(x: -size * 0.40, y: -size * 0.05, width: size * 0.80, height: size * 0.14))
        // Residual rotation around the ground contact keeps the turn
        // continuous between the quantized sprite frames (≤ half a step).
        ctx.rotate(by: CGFloat(yaw - frameYaw))
        ctx.draw(sprite, in: CGRect(x: -size / 2, y: -contact * size, width: size, height: size))
        ctx.restoreGState()
    }

    /// Stroke style for the route: history is the bright traveled line, the
    /// upcoming road stays gray and lights up as the car passes over it.
    private enum RouteStrokeStyle {
        case history
        case upcoming
    }

    /// White-on-black route casing (history style), smoothed with quadratic
    /// curves through segment midpoints.
    private func strokeRoute(_ ctx: CGContext, points: [CGPoint], style: RouteStrokeStyle) {
        guard points.count >= 2 else { return }
        let path = CGMutablePath()
        path.move(to: points[0])
        if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(
                    x: (points[i].x + points[i + 1].x) / 2,
                    y: (points[i].y + points[i + 1].y) / 2
                )
                path.addQuadCurve(to: mid, control: points[i])
            }
            path.addLine(to: points[points.count - 1])
        }
        let mainColor: UIColor
        switch style {
        case .history:
            mainColor = UIColor(red: 0.10, green: 0.42, blue: 0.90, alpha: 1)
        case .upcoming:
            mainColor = UIColor(white: 0.62, alpha: 1)
        }
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(20)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        if case .history = style {
            ctx.saveGState()
            ctx.setStrokeColor(UIColor(red: 0.10, green: 0.42, blue: 0.90, alpha: 0.28).cgColor)
            ctx.setLineWidth(14)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.setStrokeColor(mainColor.cgColor)
        ctx.setLineWidth(9)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func within(_ point: CGPoint, canvas: CGSize) -> Bool {
        point.x >= -40 && point.x <= canvas.width + 40 && point.y >= -40 && point.y <= canvas.height + 40
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
        ctx.draw(image, in: CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h))
        ctx.restoreGState()
    }

    private func drawOverlayFade(_ ctx: CGContext, _ image: CGImage, localTime: Double, duration: Double, canvas: CGSize) {
        guard localTime < duration, duration > 0 else { return }
        let p = localTime / duration
        let alpha: Double = p < 0.25 ? p / 0.25 : (p > 0.75 ? max((1 - p) / 0.25, 0) : 1)
        let rise = (1 - KenBurnsRecipe.smoothstep(p < 0.25 ? p / 0.25 : 1)) * 24
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.draw(image, in: CGRect(x: 0, y: -CGFloat(rise), width: canvas.width, height: canvas.height))
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

extension RoadTripMatrix3 {
    /// 4×4 Core Animation form: maps (x, y, 0, 1) → (x′, y′, 0, w′) with the
    /// same projective divide as `transformed(_:)`.
    var catTransform3D: CATransform3D {
        CATransform3D(
            m11: m00, m12: m01, m13: 0, m14: m02,
            m21: m10, m22: m11, m23: 0, m24: m12,
            m31: 0, m32: 0, m33: 1, m34: 0,
            m41: m20, m42: m21, m43: 0, m44: m22
        )
    }
}
