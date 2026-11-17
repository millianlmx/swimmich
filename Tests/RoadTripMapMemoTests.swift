import MapKit
import XCTest
@testable import ImmichSwiftUI

/// The live map leg's polylines stay light whatever the leg's length, and only
/// a short tail of them changes from one frame to the next.
final class RoadTripMapMemoTests: XCTestCase {

    /// Straight line `meters` long due north of Paris (two points, as a leg
    /// whose driving route was not resolved).
    private func straightLeg(meters: Double) -> [RoutePoint] {
        [RoutePoint(latitude: 48.85, longitude: 2.35),
         RoutePoint(latitude: 48.85 + meters / 111_320, longitude: 2.35)]
    }

    func test_longLegIsDrawnWithABoundedNumberOfPoints() {
        let route = straightLeg(meters: 900_000)

        let drawn = RoadTripMapMemo.drawnRoute(route)

        XCTAssertLessThanOrEqual(drawn.coordinates.count, RoadTripMapMemo.maxDrawnPoints)
        XCTAssertEqual(drawn.coordinates.count, drawn.fractions.count)
        XCTAssertEqual(drawn.fractions.first, 0)
        XCTAssertEqual(drawn.fractions.last ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(drawn.coordinates.last?.latitude ?? 0, route[1].latitude, accuracy: 1e-9)
        XCTAssertEqual(zip(drawn.fractions, drawn.fractions.dropFirst()).filter { $0 > $1 }.count, 0, "fractions never go back")
    }

    func test_shortLegKeepsStreetLevelDetail() {
        let drawn = RoadTripMapMemo.drawnRoute(straightLeg(meters: 2_000))

        XCTAssertGreaterThanOrEqual(drawn.coordinates.count, 40, "about one point every 40 m")
    }

    func test_traveledBodyMovesBySteps_tailFollowsTheCar() {
        let drawn = RoadTripMapMemo.drawnRoute(straightLeg(meters: 900_000))
        var bodies = Set<Int>()
        for i in 0...300 {
            let fraction = Double(i) / 300
            let car = CLLocationCoordinate2D(latitude: 48.85 + fraction * 900_000 / 111_320, longitude: 2.35)
            let parts = RoadTripMapMemo.traveledParts(drawn, carFraction: fraction, car: car)
            bodies.insert(parts.body.count)
            XCTAssertEqual(parts.tail.last?.latitude ?? 0, car.latitude, accuracy: 1e-12, "the tail ends on the car")
            XCTAssertLessThanOrEqual(parts.tail.count, drawn.coordinates.count / RoadTripMapMemo.traveledSteps + 2)
            if let bodyEnd = parts.body.last, let tailStart = parts.tail.first {
                XCTAssertEqual(bodyEnd.latitude, tailStart.latitude, accuracy: 1e-12, "body and tail join")
            }
        }
        XCTAssertLessThanOrEqual(bodies.count, RoadTripMapMemo.traveledSteps + 2, "the long polyline changes a few dozen times per leg")
    }

    func test_smoothRailOfAVeryLongLegStaysBounded() {
        let route = straightLeg(meters: 1_500_000)

        let rail = RoadTripSmoothPath.make(route: route, sigma: RoadTripDriveCamera.cameraSigma)

        XCTAssertLessThanOrEqual(Double(rail.points.count), RoadTripSmoothPath.maxResampledPoints + 2)
        XCTAssertEqual(rail.total, RoadTripTravelTiming.cumulativeLengths(route).last ?? 0, accuracy: 1)
        XCTAssertEqual(rail.point(at: 1).latitude, route[1].latitude, accuracy: 1e-6)
    }
}
