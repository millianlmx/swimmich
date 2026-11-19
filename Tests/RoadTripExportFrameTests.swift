import AVFoundation
import CoreVideo
import MapKit
import UIKit
import XCTest
@testable import ImmichSwiftUI

/// The frames of the exported film, read back pixel by pixel: the renderer's
/// context is y-down, which `CGContext.draw` does not account for, and the map
/// frames are crops of satellite snapshots placed by their map rects.
final class RoadTripExportFrameTests: XCTestCase {

    private func makeAsset(_ id: String) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func makeConfig(_ size: CGSize) -> RoadTripRenderConfig {
        RoadTripRenderConfig(
            size: size, fps: 30, baseURL: URL(string: "https://photos.example.org")!,
            token: nil, albumTitle: "Trip", reduceMotion: true
        )
    }

    private let noCards = RoadTripVideoRenderer.VisualAssets(opening: nil, ending: nil, intertitles: [:])

    private func makePixelBuffer(_ size: CGSize) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    /// RGB of the pixel `y` rows below the TOP of the frame: row 0 of a
    /// pixel buffer is the top of the video frame.
    private func rgb(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let pixel = base + y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
    }

    /// An opaque photo: red on its top half, blue on its bottom half.
    private func twoTonePhoto(width: Int, height: Int) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }.cgImage!
    }

    /// A snapshot stand-in, `scale` pixels per point, each pixel colored by
    /// where it sits: red grows left → right, green top → bottom.
    private func positionCodedSnapshot(pointSize: CGSize, scale: Int) -> CGImage {
        let width = Int(pointSize.width) * scale
        let height = Int(pointSize.height) * scale
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                let pixel = bytes + row * width * 4 + column * 4
                pixel[0] = UInt8(column * 255 / (width - 1))
                pixel[1] = UInt8(row * 255 / (height - 1))
                pixel[2] = 128
                pixel[3] = 255
            }
        }
        return context.makeImage()!
    }

    func test_exportDrawsThePhotosUpright() throws {
        let canvas = CGSize(width: 180, height: 320)
        let asset = makeAsset("p1")
        let cluster = RoadTripCluster(
            id: "c1", assets: [asset], latitude: nil, longitude: nil,
            placeName: nil, startDate: nil, endDate: nil
        )
        let timeline = RoadTripTimeline(segments: [
            .slideshow(RoadTripTimeline.Slideshow(
                clusterID: "c1", assetIndices: [0], photoDurations: [4], recipeOffset: 0, energy: 0.5
            ))
        ])
        let buffer = try makePixelBuffer(canvas)

        RoadTripVideoRenderer(session: { .shared }).drawFrame(
            at: 2, into: buffer, clusters: [cluster], clusterByID: ["c1": cluster], timeline: timeline,
            config: makeConfig(canvas), images: ["p1": twoTonePhoto(width: 90, height: 160)],
            visuals: noCards, map: .empty
        )

        let top = rgb(buffer, x: 90, y: 60)
        let bottom = rgb(buffer, x: 90, y: 260)
        XCTAssertTrue(top.r > 150 && top.b < 100, "the top of the frame must show the top (red) of the photo: \(top)")
        XCTAssertTrue(bottom.b > 150 && bottom.r < 100, "the bottom of the frame must show its bottom (blue): \(bottom)")
    }

    func test_exportMapLegShowsTheGroundUnderTheCamera() throws {
        let canvas = CGSize(width: 270, height: 480)
        let aspect = Double(canvas.width / canvas.height)
        let route = [RoutePoint(latitude: 48.80, longitude: 2.30), RoutePoint(latitude: 48.83, longitude: 2.30)]
        let travel = RoadTripTimeline.Travel(
            fromClusterID: "a", toClusterID: "b",
            distanceMeters: RoadTripClusterer.haversine(route[0].coordinate, route[1].coordinate),
            route: route, duration: 6
        )
        let localTime = 3.0
        let camera = RoadTripAerialCamera.legRect(travel: travel, localTime: localTime, aspect: aspect)
        // The snapshot as the export takes it: more ground than the camera
        // shows, twice the canvas in pixels.
        let shotRect = RoadTripAerialCamera.scaled(camera, by: 1.5)
        let shot = RoadTripVideoRenderer.MapShot(
            image: positionCodedSnapshot(pointSize: canvas, scale: 2), rect: shotRect
        )
        var map = RoadTripVideoRenderer.ExportMap()
        map.legs = [0: [shot]]
        let timeline = RoadTripTimeline(segments: [.travel(travel)])
        let buffer = try makePixelBuffer(canvas)

        RoadTripVideoRenderer(session: { .shared }).drawFrame(
            at: localTime, into: buffer, clusters: [], clusterByID: [:], timeline: timeline,
            config: makeConfig(canvas), images: [:], visuals: noCards, map: map
        )

        // Ground beside the road (away from the car mid-frame and the counter
        // at the top): each point shows the snapshot's color of its own place.
        var checked = 0
        for u in [0.08, 0.15, 0.85, 0.92] {
            for v in [0.3, 0.5, 0.7] {
                let onCanvas = CGPoint(x: canvas.width * u, y: canvas.height * v)
                let ground = MKMapPoint(
                    x: camera.minX + Double(u) * camera.size.width,
                    y: camera.minY + Double(v) * camera.size.height
                )
                let inShot = CGPoint(
                    x: (ground.x - shotRect.minX) / shotRect.size.width,
                    y: (ground.y - shotRect.minY) / shotRect.size.height
                )
                let expectedRed = Int((inShot.x * 255).rounded())
                let expectedGreen = Int((inShot.y * 255).rounded())
                let actual = rgb(buffer, x: Int(onCanvas.x), y: Int(onCanvas.y))
                let place = "ground (u \(u), v \(v)) at \(onCanvas) on the frame, \(inShot) in the snapshot"
                XCTAssertEqual(actual.r, expectedRed, accuracy: 14, "red of \(place): \(actual)")
                XCTAssertEqual(actual.g, expectedGreen, accuracy: 14, "green of \(place): \(actual)")
                checked += 1
            }
        }
        XCTAssertEqual(checked, 12)
    }

    func test_exportDrawsTheDrivenRoadInTheTripColor() throws {
        let canvas = CGSize(width: 270, height: 480)
        let route = [RoutePoint(latitude: 48.80, longitude: 2.30), RoutePoint(latitude: 48.83, longitude: 2.30)]
        let travel = RoadTripTimeline.Travel(
            fromClusterID: "a", toClusterID: "b",
            distanceMeters: RoadTripClusterer.haversine(route[0].coordinate, route[1].coordinate),
            route: route, duration: 6
        )
        let localTime = 3.0
        let camera = RoadTripAerialCamera.legRect(travel: travel, localTime: localTime, aspect: Double(canvas.width / canvas.height))
        let timeline = RoadTripTimeline(segments: [.travel(travel)])
        var map = RoadTripVideoRenderer.ExportMap()
        map.legs = [0: [RoadTripVideoRenderer.MapShot(image: positionCodedSnapshot(pointSize: canvas, scale: 1), rect: camera)]]
        map.roads = RoadTripVideoRenderer.roads(of: timeline)
        let buffer = try makePixelBuffer(canvas)

        RoadTripVideoRenderer(session: { .shared }).drawFrame(
            at: localTime, into: buffer, clusters: [], clusterByID: [:], timeline: timeline,
            config: makeConfig(canvas), images: [:], visuals: noCards, map: map
        )

        // Halfway: a point of the road the car has passed is yellow, one
        // ahead of it is still the ground.
        let timing = RoadTripTravelTiming.frame(travel: travel, localTime: localTime)
        XCTAssertEqual(timing.routeDrawnFraction, 0.5, accuracy: 0.05)
        func pixel(atFraction fraction: Double) -> (r: Int, g: Int, b: Int) {
            let point = RoadTripTravelTiming.interpolate(route, fraction: fraction)
            let p = RoadTripAerialCamera.project(MKMapPoint(point.coordinate), in: camera, canvas: canvas)
            return rgb(buffer, x: Int(p.x.rounded()), y: Int(p.y.rounded()))
        }
        let driven = pixel(atFraction: 0.2)
        XCTAssertTrue(driven.r > 220 && driven.g > 170 && driven.b < 120, "the driven road is the trip's yellow: \(driven)")
        let ahead = pixel(atFraction: 0.8)
        XCTAssertFalse(ahead.r > 220 && ahead.g > 170 && ahead.b < 120, "the road ahead is not drawn yet: \(ahead)")
    }

    // MARK: - Map ↔ photo cuts

    /// slideshow a (one photo) → leg a→b → slideshow b (one photo), Ken Burns
    /// on: the photos open and close on a zoom or a pan, not on the plain
    /// frame.
    /// With `collage`, each stop opens on a two-photo collage instead (a 2 s
    /// slide, like the single photo), so the dive lands on its first tile and
    /// the outgoing photos are both its tiles.
    private func cutsFixture(canvas: CGSize, collage: Bool = false) -> (RoadTripTimeline, [RoadTripCluster], [String: CGImage], RoadTripVideoRenderer.ExportMap) {
        let route = [RoutePoint(latitude: 48.80, longitude: 2.30), RoutePoint(latitude: 48.83, longitude: 2.30)]
        let travel = RoadTripTimeline.Travel(
            fromClusterID: "a", toClusterID: "b",
            distanceMeters: RoadTripClusterer.haversine(route[0].coordinate, route[1].coordinate),
            route: route, duration: 3
        )
        // recipeOffset 2 → the first slideshow closes on a pan (offset),
        // 1 → the second opens on a zoom-out (×1.1).
        let tiles = collage ? RoadTripCollage.layout(aspects: [1.5, 1.5]).tiles : []
        let indices = collage ? [0, 1] : [0]
        XCTAssertEqual(RoadTripCollage.duration(tiles: 2), 2)
        let timeline = RoadTripTimeline(segments: [
            .slideshow(RoadTripTimeline.Slideshow(clusterID: "a", assetIndices: indices, photoDurations: [2], recipeOffset: 2, energy: 0.8, collage: tiles)),
            .travel(travel),
            .slideshow(RoadTripTimeline.Slideshow(clusterID: "b", assetIndices: indices, photoDurations: [2], recipeOffset: 1, energy: 0.8, collage: tiles))
        ])
        let clusters = [
            RoadTripCluster(id: "a", assets: [makeAsset("pa"), makeAsset("pa2")], latitude: 48.80, longitude: 2.30, placeName: nil, startDate: nil, endDate: nil),
            RoadTripCluster(id: "b", assets: [makeAsset("pb"), makeAsset("pb2")], latitude: 48.83, longitude: 2.30, placeName: nil, startDate: nil, endDate: nil)
        ]
        let photo = positionCodedSnapshot(pointSize: canvas, scale: 1)
        var map = RoadTripVideoRenderer.ExportMap()
        let camera = RoadTripAerialCamera.legEnvelope(travel: travel, aspect: Double(canvas.width / canvas.height))
        map.legs = [1: [RoadTripVideoRenderer.MapShot(
            image: positionCodedSnapshot(pointSize: canvas, scale: 1), rect: RoadTripAerialCamera.scaled(camera, by: 2)
        )]]
        let second = twoTonePhoto(width: Int(canvas.width), height: Int(canvas.height))
        return (timeline, clusters, ["pa": photo, "pb": photo, "pa2": second, "pb2": second], map)
    }

    private func drawCutFrame(at time: TimeInterval, canvas: CGSize, collage: Bool = false) throws -> CVPixelBuffer {
        let (timeline, clusters, images, map) = cutsFixture(canvas: canvas, collage: collage)
        let buffer = try makePixelBuffer(canvas)
        let config = RoadTripRenderConfig(
            size: canvas, fps: 30, baseURL: URL(string: "https://photos.example.org")!,
            token: nil, albumTitle: "Trip", reduceMotion: false
        )
        RoadTripVideoRenderer(session: { .shared }).drawFrame(
            at: time, into: buffer, clusters: clusters,
            clusterByID: Dictionary(uniqueKeysWithValues: clusters.map { ($0.id, $0) }),
            timeline: timeline, config: config, images: images, visuals: noCards, map: map
        )
        return buffer
    }

    /// The same photo pixels on both sides of a cut (centre band, clear of the
    /// slideshow's vignette).
    private func assertSamePicture(_ a: CVPixelBuffer, _ b: CVPixelBuffer, canvas: CGSize, _ what: String) {
        for u in [0.3, 0.5, 0.7] {
            for v in [0.35, 0.5, 0.65] {
                let x = Int(canvas.width * u), y = Int(canvas.height * v)
                let pa = rgb(a, x: x, y: y), pb = rgb(b, x: x, y: y)
                XCTAssertEqual(pa.r, pb.r, accuracy: 8, "\(what): red at (\(u), \(v)) \(pa) vs \(pb)")
                XCTAssertEqual(pa.g, pb.g, accuracy: 8, "\(what): green at (\(u), \(v)) \(pa) vs \(pb)")
            }
        }
    }

    /// The arrival dive lands on the framing the next slideshow opens on: the
    /// photo does not jump when the leg hands over to it.
    func test_exportDiveLandsOnTheSlideshowsFirstFrame() throws {
        let canvas = CGSize(width: 180, height: 320)
        let lastOfLeg = try drawCutFrame(at: 5 - 0.0001, canvas: canvas)
        let firstOfSlideshow = try drawCutFrame(at: 5, canvas: canvas)
        assertSamePicture(lastOfLeg, firstOfSlideshow, canvas: canvas, "dive → slideshow")
    }

    /// The outgoing photo leaves from the framing the slideshow closed on.
    func test_exportOutgoingPhotoLeavesFromTheSlideshowsLastFrame() throws {
        let canvas = CGSize(width: 180, height: 320)
        let lastOfSlideshow = try drawCutFrame(at: 2 - 0.0001, canvas: canvas)
        let firstOfLeg = try drawCutFrame(at: 2, canvas: canvas)
        assertSamePicture(lastOfSlideshow, firstOfLeg, canvas: canvas, "slideshow → leg")
    }

    /// A stop opening on a collage: the dive grows its first photo and fades
    /// the others in, landing on the whole collage.
    func test_exportDiveLandsOnTheWholeCollage() throws {
        let canvas = CGSize(width: 180, height: 320)
        let lastOfLeg = try drawCutFrame(at: 5 - 0.0001, canvas: canvas, collage: true)
        let firstOfSlideshow = try drawCutFrame(at: 5, canvas: canvas, collage: true)
        assertSamePicture(lastOfLeg, firstOfSlideshow, canvas: canvas, "dive → collage")
        for buffer in [lastOfLeg, firstOfSlideshow] {
            let below = rgb(buffer, x: 90, y: 280)
            XCTAssertGreaterThan(below.b, 150, "the second tile (the two-tone photo's blue half) is there: \(below)")
        }
    }

    /// A stop closing on its collage: every tile fades out from where it was.
    func test_exportOutgoingCollageLeavesFromItsLastFrame() throws {
        let canvas = CGSize(width: 180, height: 320)
        let lastOfSlideshow = try drawCutFrame(at: 2 - 0.0001, canvas: canvas, collage: true)
        let firstOfLeg = try drawCutFrame(at: 2, canvas: canvas, collage: true)
        assertSamePicture(lastOfSlideshow, firstOfLeg, canvas: canvas, "collage → leg")
        let lower = rgb(firstOfLeg, x: 90, y: 280)
        XCTAssertGreaterThan(lower.b, 150, "the second tile (the two-tone photo's blue half) leaves too: \(lower)")
    }

    /// The writer settings AVFoundation accepts: refused ones raise inside
    /// `AVAssetWriterInput.init` and abort the app on Save.
    func test_videoSettingsAreAcceptedByTheWriter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings = RoadTripVideoRenderer.videoSettings(makeConfig(CGSize(width: 1080, height: 1920)))
        XCTAssertTrue(writer.canApply(outputSettings: settings, forMediaType: .video))
        XCTAssertNil(settings[AVVideoAverageBitRateKey], "the bitrate belongs under AVVideoCompressionPropertiesKey")
    }

    /// The whole export, end to end: a playable file holding every frame of
    /// the film (the map snapshots may fail offline; the frames still come).
    func test_exportWritesTheWholeFilm() async throws {
        let canvas = CGSize(width: 270, height: 480)
        let (timeline, clusters, images, _) = cutsFixture(canvas: canvas)
        let config = RoadTripRenderConfig(
            size: canvas, fps: 30, baseURL: URL(string: "https://photos.example.org")!,
            token: nil, albumTitle: "Trip", reduceMotion: false
        )
        let url = try await RoadTripVideoRenderer(session: { .shared }).render(
            clusters: clusters, timeline: timeline, config: config, preloaded: images
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, timeline.totalDuration, accuracy: 0.05)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, canvas)
        let reader = try AVAssetReader(asset: asset)
        // Decoded: the raw HEVC stream also carries samples that are not frames.
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        XCTAssertEqual(frames, Int((timeline.totalDuration * 30).rounded(.up)))
    }

    func test_bestShotIsTheSharpestHoldingTheCamera() {
        let image = positionCodedSnapshot(pointSize: CGSize(width: 4, height: 4), scale: 1)
        let wide = RoadTripVideoRenderer.MapShot(image: image, rect: MKMapRect(x: 0, y: 0, width: 1000, height: 1000))
        let close = RoadTripVideoRenderer.MapShot(image: image, rect: MKMapRect(x: 100, y: 100, width: 300, height: 300))
        let shots = [wide, close]

        XCTAssertEqual(RoadTripVideoRenderer.bestShot(shots, for: MKMapRect(x: 150, y: 150, width: 100, height: 100))?.rect.size.width, 300)
        XCTAssertEqual(RoadTripVideoRenderer.bestShot(shots, for: MKMapRect(x: 300, y: 300, width: 400, height: 400))?.rect.size.width, 1000)
    }

    /// The whole pipeline, frames drawn a batch at a time on every core and
    /// the legs' snapshots taken ahead: every frame lands in the file, in
    /// order, and the cut from the leg to the collage still matches.
    func test_exportWritesEveryFrameInOrder() async throws {
        let canvas = CGSize(width: 180, height: 320)
        let (timeline, clusters, images, _) = cutsFixture(canvas: canvas, collage: true)
        let config = RoadTripRenderConfig(
            size: canvas, fps: 10, baseURL: URL(string: "https://photos.example.org")!,
            token: nil, albumTitle: "Trip", reduceMotion: false
        )
        let url = try await RoadTripVideoRenderer(session: { .shared }).render(
            clusters: clusters, timeline: timeline, config: config, preloaded: images
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 {
                times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
        }
        let expected = Int((timeline.totalDuration * 10).rounded(.up))
        XCTAssertEqual(times.count, expected, "every frame is written")
        XCTAssertEqual(times.sorted(), (0..<expected).map { Double($0) / 10 }, "at its own time")
    }

    func test_routeCacheReadsBackWhatItStored() throws {
        let from = RoutePoint(latitude: 39.76351, longitude: 3.15203)
        let to = RoutePoint(latitude: 39.64250, longitude: 3.01050)
        let route = [from, RoutePoint(latitude: 39.7, longitude: 3.08), to]
        if let url = RoadTripRouteCache.fileURL(from: from, to: to) { try? FileManager.default.removeItem(at: url) }
        defer { if let url = RoadTripRouteCache.fileURL(from: from, to: to) { try? FileManager.default.removeItem(at: url) } }

        XCTAssertNil(RoadTripRouteCache.route(from: from, to: to))
        RoadTripRouteCache.store(route, from: from, to: to)
        XCTAssertEqual(RoadTripRouteCache.route(from: from, to: to), route)
        XCTAssertNil(RoadTripRouteCache.route(from: to, to: from), "a road one way is not the road back")
    }

    /// The GPU draws every frame as Core Graphics does: photos, collages,
    /// the map, the road, pins, the car, the dive and the outgoing photos —
    /// the same picture to a few levels of a channel (antialiased edges
    /// aside).
    func test_metalFramesMatchCoreGraphics() throws {
        let canvas = CGSize(width: 180, height: 320)
        let config = RoadTripRenderConfig(
            size: canvas, fps: 30, baseURL: URL(string: "https://photos.example.org")!,
            token: nil, albumTitle: "Trip", reduceMotion: false
        )
        XCTAssertNotNil(RoadTripMetalEngine.shared, "Metal and the app's shaders load")
        XCTAssertEqual(MemoryLayout<RoadTripMetalCanvas.Quad>.stride, 96, "the shader's Quad, byte for byte")
        XCTAssertEqual(MemoryLayout<RoadTripMetalCanvas.Segment>.stride, 32, "the shader's Segment, byte for byte")
        let renderer = RoadTripVideoRenderer(session: { .shared })
        for collage in [false, true] {
            let (timeline, clusters, images, map) = cutsFixture(canvas: canvas, collage: collage)
            let byID = Dictionary(uniqueKeysWithValues: clusters.map { ($0.id, $0) })
            // The opening photo, the outgoing fade, mid-leg, the dive, the arrival.
            for time in [0.5, 2.1, 3.2, 4.85, 5.4] {
                let viaMetal = try makePixelBuffer(canvas)
                let viaCG = try makePixelBuffer(canvas)
                renderer.drawFrame(at: time, into: viaMetal, clusters: clusters, clusterByID: byID, timeline: timeline,
                                   config: config, images: images, visuals: noCards, map: map, backend: .metal)
                renderer.drawFrame(at: time, into: viaCG, clusters: clusters, clusterByID: byID, timeline: timeline,
                                   config: config, images: images, visuals: noCards, map: map, backend: .coreGraphics)
                var off: [String] = []
                var samples = 0
                for u in stride(from: 0.05, through: 0.95, by: 0.1) {
                    for v in stride(from: 0.05, through: 0.95, by: 0.1) {
                        let x = Int(canvas.width * u), y = Int(canvas.height * v)
                        let a = rgb(viaMetal, x: x, y: y), b = rgb(viaCG, x: x, y: y)
                        samples += 1
                        if abs(a.r - b.r) > 14 || abs(a.g - b.g) > 14 || abs(a.b - b.b) > 14 {
                            off.append("(\(x),\(y)) \(a) vs \(b)")
                        }
                    }
                }
                XCTAssertLessThanOrEqual(off.count, samples / 20, "collage \(collage), t=\(time): \(off.prefix(6))")
            }
        }
    }
}
