import MapKit
import XCTest
@testable import ImmichSwiftUI

/// The live map drives itself from the film clock: the car rides the leg as
/// time passes, the next leg is set up under the pictures, and the map goes
/// away after the last leg — with no SwiftUI update involved.
@MainActor
final class RoadTripLiveMapTests: XCTestCase {

    private let paris = RoutePoint(latitude: 48.8566, longitude: 2.3522)
    private let versailles = RoutePoint(latitude: 48.8049, longitude: 2.1204)

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

    private func makeMap(startedAt start: Date) -> RoadTripLiveMapView {
        let clock = RoadTripFilmClock()
        clock.start = start
        let view = RoadTripLiveMapView(
            timeline: makeTimeline(), clock: clock,
            photo: { _, _ in nil }, legLabel: { _ in "Paris → Versailles" }
        )
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        view.layoutIfNeeded()
        return view
    }

    func test_carRidesTheLegAsTheClockRuns() {
        let start = Date()
        let map = makeMap(startedAt: start)

        map.render(at: start.addingTimeInterval(3.2))
        let early = map.carCoordinate
        let earlyProgress = map.carProgress
        map.render(at: start.addingTimeInterval(6))
        let later = map.carCoordinate

        XCTAssertEqual(map.legIndex, 2)
        XCTAssertGreaterThan(map.carProgress, earlyProgress + 0.2, "the car must have driven a good part of the leg")
        XCTAssertGreaterThan(RoadTripClusterer.haversine(early, later), 1_000, "the car's coordinate must move on the map")
        XCTAssertTrue(map.isAccessibilityElement, "a leg being driven is read by VoiceOver")
        XCTAssertFalse(map.accessibilityElementsHidden)
        XCTAssertEqual(map.accessibilityLabel, "Paris → Versailles")

        map.render(at: start.addingTimeInterval(8.99))
        XCTAssertGreaterThan(map.carProgress, 0.98, "the car reaches the destination at the leg's end")
    }

    func test_cameraFollowsTheCar() {
        let start = Date()
        let map = makeMap(startedAt: start)

        map.render(at: start.addingTimeInterval(4))
        let first = map.cameraCenter
        map.render(at: start.addingTimeInterval(7))
        let second = map.cameraCenter

        XCTAssertGreaterThan(RoadTripClusterer.haversine(first, second), 1_000, "the camera must travel with the car")
    }

    func test_nextLegWaitsUnderThePictures() {
        let start = Date()
        let map = makeMap(startedAt: start)

        map.render(at: start.addingTimeInterval(0.5))

        XCTAssertEqual(map.legIndex, 2, "the leg is set up during the opening, before it plays")
        XCTAssertFalse(map.isHidden)
        XCTAssertEqual(map.carProgress, 0, accuracy: 1e-9, "the car waits on the start")
        XCTAssertFalse(map.isAccessibilityElement, "hidden under the pictures, the map is not read")
        XCTAssertTrue(map.accessibilityElementsHidden, "nor is anything inside it (MapKit's legal link)")
    }

    func test_mapGoesAwayAfterTheLastLeg() {
        let start = Date()
        let map = makeMap(startedAt: start)

        map.render(at: start.addingTimeInterval(11.5))

        XCTAssertTrue(map.isHidden)
        XCTAssertFalse(map.isAccessibilityElement)
        XCTAssertTrue(map.accessibilityElementsHidden)
    }

    func test_beforeTheFilmStartsTheMapHoldsTheFirstLegStart() {
        let clock = RoadTripFilmClock()
        XCTAssertEqual(clock.elapsed(at: Date()), 0)
        let map = RoadTripLiveMapView(timeline: makeTimeline(), clock: clock, photo: { _, _ in nil }, legLabel: { _ in "" })

        map.render(at: Date())

        XCTAssertEqual(map.legIndex, 2)
        XCTAssertEqual(map.carProgress, 0, accuracy: 1e-9)
    }
}
