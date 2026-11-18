import MapKit
import XCTest
@testable import ImmichSwiftUI

/// The live map drives itself from the film clock: the opening shows the
/// whole trip, the car rides each leg as time passes while the trip's line
/// draws itself behind it, the next leg is set up under the pictures, and the
/// ending shows the whole route — with no SwiftUI update involved.
@MainActor
final class RoadTripLiveMapTests: XCTestCase {

    private let paris = RoutePoint(latitude: 48.8566, longitude: 2.3522)
    private let versailles = RoutePoint(latitude: 48.8049, longitude: 2.1204)

    private var stops: [RoadTripMapStop] {
        [RoadTripMapStop(clusterID: "paris", coordinate: paris), RoadTripMapStop(clusterID: "versailles", coordinate: versailles)]
    }

    /// Opening 1 s, Paris 2 s, the leg 6 s (from 3 s to 9 s), Versailles 2 s, ending 1 s.
    private func makeTimeline() -> RoadTripTimeline {
        let travel = RoadTripTimeline.Travel(
            fromClusterID: "paris", toClusterID: "versailles",
            distanceMeters: RoadTripClusterer.haversine(paris.coordinate, versailles.coordinate),
            route: [paris, versailles], duration: 6
        )
        func stop(_ id: String) -> RoadTripTimeline.Segment {
            .slideshow(RoadTripTimeline.Slideshow(clusterID: id, assetIndices: [0], photoDurations: [2], recipeOffset: 0, energy: 0.5))
        }
        return RoadTripTimeline(segments: [.opening(duration: 1), stop("paris"), .travel(travel), stop("versailles"), .ending(duration: 1)])
    }

    private func makeMap(startedAt start: Date?, stops: [RoadTripMapStop]? = nil) -> RoadTripLiveMapView {
        let clock = RoadTripFilmClock()
        clock.start = start
        let view = RoadTripLiveMapView(
            timeline: makeTimeline(), clock: clock, stops: stops ?? self.stops,
            photo: { _, _ in nil }, stopPhoto: { _ in nil }, legLabel: { _ in "Paris → Versailles" }
        )
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        view.layoutIfNeeded()
        return view
    }

    private func contains(_ rect: MKMapRect?, _ point: RoutePoint) -> Bool {
        rect?.contains(MKMapPoint(point.coordinate)) ?? false
    }

    func test_openingShowsTheWholeTripWithItsRoadFaint() {
        let start = Date()
        let map = makeMap(startedAt: start)

        map.render(at: start.addingTimeInterval(0.5))

        guard case .opening = map.shot else { return XCTFail("the opening shows the trip, not \(String(describing: map.shot))") }
        XCTAssertFalse(map.isHidden)
        XCTAssertTrue(contains(map.shotRect, paris) && contains(map.shotRect, versailles), "both stops in the frame")
        XCTAssertEqual(map.line(ofLeg: 2)?.end, 1, "the whole road previewed")
        XCTAssertEqual(Double(map.line(ofLeg: 2)?.alpha ?? 0), RoadTripMapStyle.previewAlpha, accuracy: 1e-6, "faint")
        XCTAssertFalse(map.showsCar)
        XCTAssertFalse(map.isAccessibilityElement, "the title is read, not the map")
    }

    func test_carRidesTheLegAsTheClockRuns() {
        let start = Date()
        let map = makeMap(startedAt: start)

        map.render(at: start.addingTimeInterval(3.2))
        let early = map.carCoordinate
        let earlyProgress = map.carProgress
        let earlyLine = map.line(ofLeg: 2)?.end ?? -1
        map.render(at: start.addingTimeInterval(6))
        let later = map.carCoordinate

        XCTAssertEqual(map.legIndex, 2)
        XCTAssertTrue(map.showsCar)
        XCTAssertGreaterThan(map.carProgress, earlyProgress + 0.2, "the car must have driven a good part of the leg")
        XCTAssertGreaterThan(RoadTripClusterer.haversine(early, later), 1_000, "the car's coordinate must move on the map")
        XCTAssertGreaterThan(map.line(ofLeg: 2)?.end ?? -1, earlyLine + 0.2, "the line draws itself behind the car")
        XCTAssertEqual(Double(map.line(ofLeg: 2)?.alpha ?? 0), 1, accuracy: 1e-6)
        XCTAssertTrue(map.isAccessibilityElement, "a leg being driven is read by VoiceOver")
        XCTAssertFalse(map.accessibilityElementsHidden)
        XCTAssertEqual(map.accessibilityLabel, "Paris → Versailles")

        map.render(at: start.addingTimeInterval(8.99))
        XCTAssertGreaterThan(map.carProgress, 0.98, "the car reaches the destination at the leg's end")
    }

    func test_cameraStartsCloseThenShowsTheWholeLeg() {
        let start = Date()
        let map = makeMap(startedAt: start)

        map.render(at: start.addingTimeInterval(3))
        let close = map.shotRect
        let first = map.cameraCenter
        map.render(at: start.addingTimeInterval(6))
        let wide = map.shotRect
        let second = map.cameraCenter

        XCTAssertLessThan(close?.size.width ?? .infinity, (wide?.size.width ?? 0) * 0.7, "close on the start, then pulled back")
        XCTAssertTrue(contains(wide, paris) && contains(wide, versailles), "mid-leg, the whole road shows")
        XCTAssertGreaterThan(RoadTripClusterer.haversine(first, second), 1_000, "the camera travels with the car")
    }

    func test_nextLegWaitsUnderThePictures() {
        let start = Date()
        let map = makeMap(startedAt: start)

        map.render(at: start.addingTimeInterval(1.5))

        XCTAssertEqual(map.legIndex, 2, "the leg is set up under the first stop's photos, before it plays")
        XCTAssertFalse(map.isHidden)
        XCTAssertEqual(map.carProgress, 0, accuracy: 1e-9, "the car waits on the start")
        XCTAssertEqual(map.line(ofLeg: 2)?.end, 0, "nothing of the road drawn yet")
        XCTAssertFalse(map.isAccessibilityElement, "hidden under the pictures, the map is not read")
        XCTAssertTrue(map.accessibilityElementsHidden, "nor is anything inside it (MapKit's legal link)")
    }

    func test_endingShowsTheWholeRouteDrawn() {
        let start = Date()
        let map = makeMap(startedAt: start)

        map.render(at: start.addingTimeInterval(11.5))

        guard case .ending = map.shot else { return XCTFail("the ending shows the trip, not \(String(describing: map.shot))") }
        XCTAssertFalse(map.isHidden)
        XCTAssertTrue(contains(map.shotRect, paris) && contains(map.shotRect, versailles))
        XCTAssertEqual(map.line(ofLeg: 2)?.end, 1)
        XCTAssertEqual(Double(map.line(ofLeg: 2)?.alpha ?? 0), 1, accuracy: 1e-6)
        XCTAssertFalse(map.showsCar)
        XCTAssertFalse(map.isAccessibilityElement)
        XCTAssertTrue(map.accessibilityElementsHidden)
    }

    /// Pulled back after a close-up, the road already driven shows whole — not
    /// just the bit that was on screen close up (MapKit overlay tiles were
    /// not redrawn while the camera kept moving).
    func test_lineDrivenShowsWholeAfterThePullBack() throws {
        let start = Date()
        let map = makeMap(startedAt: start)

        map.render(at: start.addingTimeInterval(8.95))
        map.render(at: start.addingTimeInterval(11.5))

        let rect = try XCTUnwrap(map.shotRect)
        let canvas = map.bounds.size
        let from = RoadTripAerialCamera.project(MKMapPoint(paris.coordinate), in: rect, canvas: canvas)
        let to = RoadTripAerialCamera.project(MKMapPoint(versailles.coordinate), in: rect, canvas: canvas)
        let line = map.drawnLineBounds
        XCTAssertFalse(line.isNull, "the line is drawn")
        XCTAssertEqual(line.minX, min(from.x, to.x), accuracy: 6, "the line reaches Versailles: \(line)")
        XCTAssertEqual(line.maxX, max(from.x, to.x), accuracy: 6, "the line reaches Paris: \(line)")
        XCTAssertEqual(line.minY, min(from.y, to.y), accuracy: 6)
        XCTAssertEqual(line.maxY, max(from.y, to.y), accuracy: 6)
    }

    func test_beforeTheFilmStartsTheMapHoldsTheOpening() {
        let clock = RoadTripFilmClock()
        XCTAssertEqual(clock.elapsed(at: Date()), 0)
        let map = RoadTripLiveMapView(
            timeline: makeTimeline(), clock: clock, stops: stops,
            photo: { _, _ in nil }, stopPhoto: { _ in nil }, legLabel: { _ in "" }
        )

        map.render(at: Date())

        XCTAssertEqual(map.shot, .opening(progress: 0))
        XCTAssertEqual(map.carProgress, 0, accuracy: 1e-9)
    }

    func test_nothingLocatedHidesTheMap() {
        let start = Date()
        let map = makeMap(startedAt: start, stops: [])
        let timeline = RoadTripTimeline(segments: [
            .opening(duration: 1),
            .slideshow(RoadTripTimeline.Slideshow(clusterID: "x", assetIndices: [0], photoDurations: [2], recipeOffset: 0, energy: 0.5)),
            .ending(duration: 1)
        ])
        map.update(timeline: timeline, stops: [], photo: { _, _ in nil }, stopPhoto: { _ in nil }, legLabel: { _ in "" })

        map.render(at: start.addingTimeInterval(0.5))

        XCTAssertTrue(map.isHidden, "no stop located: the title plays over black")
    }
}
