import MapKit
import XCTest
@testable import ImmichSwiftUI

/// The film's map camera, shared by the live player and the export: which
/// shot plays when, and what ground each frames.
final class RoadTripAerialCameraTests: XCTestCase {

    private let aspect = 1080.0 / 1920.0
    private let paris = RoutePoint(latitude: 48.8566, longitude: 2.3522)
    private let versailles = RoutePoint(latitude: 48.8049, longitude: 2.1204)
    private let chartres = RoutePoint(latitude: 48.4439, longitude: 1.4890)

    private func travel(_ from: RoutePoint, _ to: RoutePoint, _ ids: (String, String), duration: TimeInterval = 4) -> RoadTripTimeline.Travel {
        RoadTripTimeline.Travel(
            fromClusterID: ids.0, toClusterID: ids.1,
            distanceMeters: RoadTripClusterer.haversine(from.coordinate, to.coordinate),
            route: [from, to], duration: duration
        )
    }

    private func stop(_ id: String) -> RoadTripTimeline.Segment {
        .slideshow(RoadTripTimeline.Slideshow(clusterID: id, assetIndices: [0], photoDurations: [2], recipeOffset: 0, energy: 0.5))
    }

    /// opening 2 | paris 2 | leg 4 (4…8) | versailles 2 | leg 4 (10…14) | chartres 2 | ending 4
    private func makeTimeline() -> RoadTripTimeline {
        RoadTripTimeline(segments: [
            .opening(duration: 2), stop("p"), .travel(travel(paris, versailles, ("p", "v"))),
            stop("v"), .travel(travel(versailles, chartres, ("v", "c"))), stop("c"), .ending(duration: 4)
        ])
    }

    private var stops: [RoadTripMapStop] {
        [
            RoadTripMapStop(clusterID: "p", coordinate: paris),
            RoadTripMapStop(clusterID: "v", coordinate: versailles),
            RoadTripMapStop(clusterID: "c", coordinate: chartres)
        ]
    }

    func test_shotAt_followsTheFilm() {
        let timeline = makeTimeline()
        XCTAssertEqual(RoadTripMapShot.at(1, in: timeline), .opening(progress: 0.5))
        XCTAssertEqual(RoadTripMapShot.at(3, in: timeline), .leg(segmentIndex: 2, localTime: 0), "under Paris, the first leg waits")
        XCTAssertEqual(RoadTripMapShot.at(6, in: timeline), .leg(segmentIndex: 2, localTime: 2))
        XCTAssertEqual(RoadTripMapShot.at(9, in: timeline), .leg(segmentIndex: 4, localTime: 0), "under Versailles, the second leg waits")
        XCTAssertEqual(RoadTripMapShot.at(15, in: timeline), .ending(progress: 0), "under the last stop, the ending waits")
        XCTAssertEqual(RoadTripMapShot.at(18, in: timeline), .ending(progress: 0.5))
        XCTAssertEqual(RoadTripMapShot.at(100, in: timeline), .ending(progress: 1))
    }

    func test_overviewHoldsEveryStop() throws {
        let timeline = makeTimeline()
        let overview = try XCTUnwrap(RoadTripAerialCamera.overview(timeline: timeline, stops: stops, aspect: aspect))
        for stop in stops {
            XCTAssertTrue(overview.contains(MKMapPoint(stop.coordinate.coordinate)), "\(stop.clusterID) out of the overview")
        }
        XCTAssertEqual(overview.size.width / overview.size.height, aspect, accuracy: 1e-9)
        // The opening pushes in onto it, the ending pulls back onto it.
        let openingStart = RoadTripAerialCamera.openingRect(overview: overview, progress: 0)
        let openingEnd = RoadTripAerialCamera.openingRect(overview: overview, progress: 1)
        XCTAssertGreaterThan(openingStart.size.width, openingEnd.size.width)
        XCTAssertEqual(openingEnd.size.width, overview.size.width, accuracy: 1)
        let endingStart = RoadTripAerialCamera.endingRect(overview: overview, progress: 0)
        XCTAssertLessThan(endingStart.size.width, overview.size.width)
    }

    func test_nothingLocatedHasNoMap() {
        let timeline = RoadTripTimeline(segments: [.opening(duration: 2), stop("x"), .ending(duration: 4)])
        XCTAssertNil(RoadTripAerialCamera.rect(for: .opening(progress: 0), timeline: timeline, stops: [], aspect: aspect))
    }

    func test_legRect_alwaysHoldsTheCar_closeAtTheEndsWideInTheMiddle() {
        let leg = travel(versailles, chartres, ("v", "c"), duration: 3)
        let full = RoadTripAerialCamera.legFrame(leg, aspect: aspect)
        // What the export snapshots for the leg (its envelope, with its margin).
        let snapshot = RoadTripAerialCamera.scaled(RoadTripAerialCamera.legEnvelope(travel: leg, aspect: aspect), by: 1.06)
        for step in 0...30 {
            let time = leg.duration * Double(step) / 30
            let rect = RoadTripAerialCamera.legRect(travel: leg, localTime: time, aspect: aspect)
            let car = RoadTripTravelTiming.frame(travel: leg, localTime: time).carCoordinate
            XCTAssertTrue(rect.contains(MKMapPoint(car.coordinate)), "the car leaves the frame at \(time) s")
            XCTAssertEqual(rect.size.width / rect.size.height, aspect, accuracy: 1e-6)
            XCTAssertTrue(snapshot.contains(rect), "the export's snapshot of the leg holds the camera at \(time) s")
        }
        let start = RoadTripAerialCamera.legRect(travel: leg, localTime: 0, aspect: aspect)
        let middle = RoadTripAerialCamera.legRect(travel: leg, localTime: leg.duration / 2, aspect: aspect)
        let end = RoadTripAerialCamera.legRect(travel: leg, localTime: leg.duration, aspect: aspect)
        XCTAssertEqual(start.size.width, full.size.width * RoadTripAerialCamera.closeUpFactor, accuracy: 1)
        XCTAssertEqual(middle.size.width, full.size.width, accuracy: 1)
        XCTAssertEqual(end.size.width, full.size.width * RoadTripAerialCamera.closeUpFactor, accuracy: 1)
        XCTAssertTrue(middle.contains(MKMapPoint(versailles.coordinate)) && middle.contains(MKMapPoint(chartres.coordinate)))
    }

    func test_shortLegKeepsTheMinimumSpan() {
        let a = RoutePoint(latitude: 48.8566, longitude: 2.3522)
        let b = RoutePoint(latitude: 48.8570, longitude: 2.3530)
        let leg = travel(a, b, ("a", "b"))
        let rect = RoadTripAerialCamera.legRect(travel: leg, localTime: 0, aspect: aspect)
        let meters = rect.size.width / MKMapPointsPerMeterAtLatitude(a.latitude)
        XCTAssertEqual(meters, RoadTripAerialCamera.minimumSpanMeters, accuracy: 1, "a hop across town still shows its surroundings")
    }

    func test_projectMapsTheRectOntoTheCanvas() {
        let rect = MKMapRect(x: 1000, y: 2000, width: 400, height: 800)
        let canvas = CGSize(width: 100, height: 200)
        XCTAssertEqual(RoadTripAerialCamera.project(MKMapPoint(x: 1000, y: 2000), in: rect, canvas: canvas), .zero)
        XCTAssertEqual(RoadTripAerialCamera.project(MKMapPoint(x: 1200, y: 2400), in: rect, canvas: canvas), CGPoint(x: 50, y: 100))
    }

    func test_photoPinsPopOneAfterTheOther() {
        XCTAssertEqual(RoadTripMapStyle.photoPinPop(index: 0, count: 3, endingProgress: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(RoadTripMapStyle.photoPinPop(index: 0, count: 3, endingProgress: 0.2), 1, accuracy: 1e-9)
        XCTAssertEqual(RoadTripMapStyle.photoPinPop(index: 2, count: 3, endingProgress: 0.2), 0, accuracy: 1e-9, "the last pin waits")
        XCTAssertEqual(RoadTripMapStyle.photoPinPop(index: 2, count: 3, endingProgress: 1), 1, accuracy: 1e-9)
        let overshoot = (1...11).map { RoadTripMapStyle.photoPinPop(index: 0, count: 1, endingProgress: Double($0) * 0.01) }.max() ?? 0
        XCTAssertGreaterThan(overshoot, 1, "a pin pops a little past its size before settling")
    }

    func test_photoPinsNeverOverlapAndStayOnScreen() {
        let canvas = CGSize(width: 360, height: 640)
        let diameter: CGFloat = 60
        // Three stops a few pixels apart (Sóller, Fornalutx, Escorca) and one alone.
        let pins = [CGPoint(x: 100, y: 300), CGPoint(x: 110, y: 290), CGPoint(x: 112, y: 305), CGPoint(x: 300, y: 500)]
        let centers = RoadTripMapStyle.photoPinCenters(pins: pins, diameter: diameter, canvas: canvas)

        XCTAssertEqual(centers.count, pins.count)
        for i in centers.indices {
            for j in centers.indices where j > i {
                let d = hypot(centers[i].x - centers[j].x, centers[i].y - centers[j].y)
                XCTAssertGreaterThanOrEqual(d, diameter * 0.98, "photos \(i) and \(j) overlap")
            }
            XCTAssertGreaterThanOrEqual(centers[i].x, diameter / 2)
            XCTAssertLessThanOrEqual(centers[i].x, canvas.width - diameter / 2)
        }
        // The lone stop keeps its photo right above it, without a stem.
        XCTAssertEqual(centers[3].x, 300, accuracy: 0.5)
        XCTAssertEqual(centers[3].y, 500 - diameter * 0.62, accuracy: 0.5)
        XCTAssertFalse(RoadTripMapStyle.photoPinNeedsStem(center: centers[3], pin: pins[3], diameter: diameter))
        XCTAssertEqual(centers, RoadTripMapStyle.photoPinCenters(pins: pins, diameter: diameter, canvas: canvas))
    }
}
