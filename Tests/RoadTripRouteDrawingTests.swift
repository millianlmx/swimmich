import MapKit
import XCTest
@testable import ImmichSwiftUI

/// The live map leg's polylines stay light whatever the leg's length, and only
/// a short tail of them changes from one frame to the next.
final class RoadTripRouteDrawingTests: XCTestCase {

    /// Straight line `meters` long due north of Paris (two points, as a leg
    /// whose driving route was not resolved).
    private func straightLeg(meters: Double) -> [RoutePoint] {
        [RoutePoint(latitude: 48.85, longitude: 2.35),
         RoutePoint(latitude: 48.85 + meters / 111_320, longitude: 2.35)]
    }

    func test_longLegIsDrawnWithABoundedNumberOfPoints() {
        let route = straightLeg(meters: 900_000)

        let drawn = RoadTripRouteDrawing.drawnRoute(route)

        XCTAssertLessThanOrEqual(drawn.coordinates.count, RoadTripRouteDrawing.maxDrawnPoints)
        XCTAssertEqual(drawn.coordinates.count, drawn.fractions.count)
        XCTAssertEqual(drawn.fractions.first, 0)
        XCTAssertEqual(drawn.fractions.last ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(drawn.coordinates.last?.latitude ?? 0, route[1].latitude, accuracy: 1e-9)
        XCTAssertEqual(zip(drawn.fractions, drawn.fractions.dropFirst()).filter { $0 > $1 }.count, 0, "fractions never go back")
    }

    func test_shortLegKeepsStreetLevelDetail() {
        let drawn = RoadTripRouteDrawing.drawnRoute(straightLeg(meters: 2_000))

        XCTAssertGreaterThanOrEqual(drawn.coordinates.count, 40, "about one point every 40 m")
    }

    func test_smoothRailOfAVeryLongLegStaysBounded() {
        let route = straightLeg(meters: 1_500_000)

        let rail = RoadTripSmoothPath.make(route: route, sigma: RoadTripDriveCamera.cameraSigma)

        // The spacing is set at the route's mid-latitude: the Mercator scale
        // drifts along a 1 500 km north–south leg, hence the 5 % margin.
        XCTAssertLessThanOrEqual(Double(rail.points.count), RoadTripSmoothPath.maxResampledPoints * 1.05)
        XCTAssertEqual(rail.total, RoadTripTravelTiming.cumulativeLengths(route).last ?? 0, accuracy: 1)
        XCTAssertEqual(rail.point(at: 1).latitude, route[1].latitude, accuracy: 1e-6)
    }
}
