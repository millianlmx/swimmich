import MapKit
import XCTest
@testable import ImmichSwiftUI

final class MapPosterStatsTests: XCTestCase {

    private func marker(_ id: String, _ lat: Double, _ lon: Double, city: String?, country: String?) -> MapPhoto {
        MapPhoto(from: MapMarkerResponseDto(id: id, lat: lat, lon: lon, city: city, state: nil, country: country))
    }

    // MARK: - Stats

    func test_make_countsCountriesCitiesHomeAndFurthest() {
        // Home is Paris (three photos); one in Lyon; one in Tokyo.
        let markers = [
            marker("1", 48.85, 2.35, city: "Paris", country: "France"),
            marker("2", 48.86, 2.34, city: "Paris", country: "France"),
            marker("3", 48.87, 2.30, city: "Paris", country: "France"),
            marker("4", 45.76, 4.84, city: "Lyon", country: "France"),
            marker("5", 35.68, 139.69, city: "Tokyo", country: "Japan"),
            marker("6", 39.47, -0.38, city: "Valencia", country: "Spain"),
            marker("7", 10.16, -67.99, city: "Valencia", country: "Venezuela"),
        ]
        let stats = MapPosterStats.make(markers)
        XCTAssertEqual(stats.photoCount, 7)
        XCTAssertEqual(stats.countries.map(\.name), ["France", "Japan", "Spain", "Venezuela"])
        XCTAssertEqual(stats.cityCount, 5, "two Valencias are two cities")
        XCTAssertEqual(stats.home?.latitude ?? 0, 48.86, accuracy: 0.01)
        XCTAssertEqual(stats.furthest?.shortLabel, "🇯🇵 Tokyo")
        XCTAssertEqual(stats.furthest?.kilometers ?? 0, 9_710, accuracy: 60)
        XCTAssertEqual(stats.worldShare, 4.0 / 195, accuracy: 0.0001)
    }

    func test_distance_parisToNewYork() {
        let paris = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        let newYork = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        XCTAssertEqual(MapPosterStats.distance(paris, newYork) / 1000, 5_837, accuracy: 15)
    }

    // MARK: - Flags

    func test_flag_fromEnglishNamesAndGeocoderAliases() {
        XCTAssertEqual(MapPosterStats.flag(forCountry: "France"), "🇫🇷")
        XCTAssertEqual(MapPosterStats.flag(forCountry: "Japan"), "🇯🇵")
        XCTAssertEqual(MapPosterStats.flag(forCountry: "United States of America"), "🇺🇸")
        XCTAssertEqual(MapPosterStats.flag(forCountry: "Russian Federation"), "🇷🇺")
        XCTAssertNil(MapPosterStats.flag(forCountry: "Atlantis"))
    }

    // MARK: - Map framing

    func test_mapRect_framesTheirPlacesAtTheMapShape() {
        let points = [CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35), CLLocationCoordinate2D(latitude: 45.76, longitude: 4.84)]
        let rect = MapPosterRenderer.mapRect(for: points, aspect: 0.96)
        XCTAssertEqual(rect.width / rect.height, 0.96, accuracy: 0.001)
        for point in points { XCTAssertTrue(rect.contains(MKMapPoint(point))) }
        XCTAssertLessThan(rect.width, MKMapRect.world.width / 4)
    }

    func test_mapRect_wholeWorldOncePlacesSpanHalfOfIt() {
        let points = [CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35), CLLocationCoordinate2D(latitude: 35.68, longitude: 139.69),
                      CLLocationCoordinate2D(latitude: 40.71, longitude: -74.0)]
        let rect = MapPosterRenderer.mapRect(for: points, aspect: 0.96)
        XCTAssertEqual(rect.width / rect.height, 0.96, accuracy: 0.001)
        XCTAssertGreaterThan(rect.width, MKMapRect.world.width * 0.9)
    }

    // MARK: - Scope

    func test_scope_filterCoversTheWholeYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18))!
        let filter = MapPosterScope.lastYear.filter(now: now, calendar: calendar)
        XCTAssertEqual(filter.from.map { calendar.component(.year, from: $0) }, 2025)
        XCTAssertEqual(filter.to.map { calendar.dateComponents([.month, .day], from: $0) }, DateComponents(month: 12, day: 31))
        XCTAssertEqual(MapPosterScope.allTime.filter(now: now, calendar: calendar), .all)
    }
}
