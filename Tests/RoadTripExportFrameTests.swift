import CoreVideo
import MapKit
import UIKit
import XCTest
@testable import ImmichSwiftUI

/// The frames of the exported film, read back pixel by pixel: the renderer's
/// context is y-down, which `CGContext.draw` does not account for, and the map
/// legs are a perspective warp of a 2× snapshot computed in snapshot points.
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

    private func mapRect(_ region: MKCoordinateRegion) -> MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        ))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        ))
        return MKMapRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
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
            visuals: noCards, mapFrames: [:]
        )

        let top = rgb(buffer, x: 90, y: 60)
        let bottom = rgb(buffer, x: 90, y: 260)
        XCTAssertTrue(top.r > 150 && top.b < 100, "the top of the frame must show the top (red) of the photo: \(top)")
        XCTAssertTrue(bottom.b > 150 && bottom.r < 100, "the bottom of the frame must show its bottom (blue): \(bottom)")
    }

    func test_exportMapLegShowsTheGroundUnderTheChaseCamera() throws {
        let canvas = CGSize(width: 270, height: 480)
        let route = [RoutePoint(latitude: 48.80, longitude: 2.30), RoutePoint(latitude: 48.83, longitude: 2.30)]
        let travel = RoadTripTimeline.Travel(
            fromClusterID: "a", toClusterID: "b",
            distanceMeters: RoadTripClusterer.haversine(route[0].coordinate, route[1].coordinate),
            route: route, duration: 6
        )
        let window = try XCTUnwrap(RoadTripDriveCamera.windows(travel: travel, canvas: canvas).first)
        // The snapshot of the window as MKMapSnapshotter returns it: as many
        // points as the canvas, twice as many pixels (`options.scale = 2`).
        let rect = mapRect(window.region)
        let scaleX = canvas.width / rect.width
        let scaleY = canvas.height / rect.height
        let affine = RoadTripAffine(scaleX: scaleX, scaleY: scaleY, offsetX: -rect.minX * scaleX, offsetY: -rect.minY * scaleY)
        let snapshot = RoadTripVideoRenderer.MapFrame(
            base: positionCodedSnapshot(pointSize: canvas, scale: 2), pointSize: canvas,
            points: [], fractions: [], affine: affine, window: window
        )
        let timeline = RoadTripTimeline(segments: [.travel(travel)])
        let buffer = try makePixelBuffer(canvas)
        let localTime = 3.0

        RoadTripVideoRenderer(session: { .shared }).drawFrame(
            at: localTime, into: buffer, clusters: [], clusterByID: [:], timeline: timeline,
            config: makeConfig(canvas), images: [:], visuals: noCards, mapFrames: [0: [snapshot]]
        )

        // Ground points beside the road (away from the car, the route and the
        // horizon haze): each must show the snapshot's color of its own place.
        let drive = RoadTripDriveCamera.frame(travel: travel, localTime: localTime, canvas: canvas)
        let corners = drive.sourceCorners   // front-left, front-right, back-right, back-left
        let horizon = RoadTripDriveCamera.horizonFractionY(lookAheadMeters: drive.lookAheadMeters) * canvas.height
        var checked = 0
        for u in [0.06, 0.1, 0.14, 0.86, 0.9, 0.94] {
            for v in [0.1, 0.2, 0.3, 0.45] {
                let ground = lerp(lerp(corners[3], corners[2], u), lerp(corners[0], corners[1], u), v)
                let onCanvas = drive.matrix.transformed(ground)
                let inSnapshot = affine.point(ground)
                guard onCanvas.y > horizon + canvas.height * 0.2, onCanvas.y < canvas.height * 0.96,
                      onCanvas.x > 3, onCanvas.x < canvas.width - 3,
                      abs(onCanvas.x - canvas.width / 2) > canvas.width * 0.3,
                      inSnapshot.x > 2, inSnapshot.x < canvas.width - 2,
                      inSnapshot.y > 2, inSnapshot.y < canvas.height - 2 else { continue }
                let expectedRed = Int((inSnapshot.x / canvas.width * 255).rounded())
                let expectedGreen = Int((inSnapshot.y / canvas.height * 255).rounded())
                let actual = rgb(buffer, x: Int(onCanvas.x), y: Int(onCanvas.y))
                let place = "ground (u \(u), v \(v)) at \(onCanvas) on the frame, \(inSnapshot) in the snapshot"
                XCTAssertEqual(actual.r, expectedRed, accuracy: 14, "red of \(place): \(actual)")
                XCTAssertEqual(actual.g, expectedGreen, accuracy: 14, "green of \(place): \(actual)")
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 4, "too few ground points checked")
    }
}
