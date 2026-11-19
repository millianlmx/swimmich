import XCTest
import CoreLocation
@testable import ImmichSwiftUI

final class RoadTripClustererTests: XCTestCase {

    private func makeAsset(
        id: String,
        time: String = "2024-07-01T00:00:00.000Z",
        lat: Double? = nil,
        lon: Double? = nil,
        city: String? = nil,
        country: String? = nil
    ) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: time, fileCreatedAt: time,
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil,
            projectionType: nil, city: city, country: country, latitude: lat, longitude: lon, stack: []
        )
    }

    // MARK: - Basic grouping

    func test_cluster_empty_returnsEmpty() {
        XCTAssertEqual(RoadTripClusterer.cluster([]), [])
    }

    func test_cluster_singleLocated() {
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", lat: 48.8584, lon: 2.2945, city: "Paris", country: "France")
        ])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].assets.map(\.id), ["a"])
        XCTAssertEqual(clusters[0].placeName, "Paris, France")
        XCTAssertEqual(clusters[0].latitude!, 48.8584, accuracy: 0.0001)
        XCTAssertEqual(clusters[0].longitude!, 2.2945, accuracy: 0.0001)
    }

    func test_cluster_nearbyMerges() {
        // ~0.005 deg lat apart (~555m) → same cluster.
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 48.8584, lon: 2.2945),
            makeAsset(id: "b", time: "2024-07-01T10:05:00.000Z", lat: 48.8634, lon: 2.2945)
        ])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].assets.map(\.id)), ["a", "b"])
    }

    func test_cluster_farApartSplits() {
        // ~0.05 deg lat apart (~5.5km) → two clusters (beyond the 2.5 km
        // greedy radius AND the 4 km consecutive-merge radius).
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 48.8584, lon: 2.2945),
            makeAsset(id: "b", time: "2024-07-01T11:00:00.000Z", lat: 48.9084, lon: 2.2945)
        ])
        XCTAssertEqual(clusters.count, 2)
    }

    func test_cluster_midGapSameDayMergesByDistance() {
        // ~3.3 km apart the same day: beyond the greedy radius but inside the
        // consecutive-merge radius — one stop (the anti "X → X" fix).
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 48.8584, lon: 2.2945),
            makeAsset(id: "b", time: "2024-07-01T11:00:00.000Z", lat: 48.8884, lon: 2.2945)
        ])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].assets.map(\.id)), ["a", "b"])
    }

    func test_cluster_chronologicalOrder() {
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "late", time: "2024-07-03T10:00:00.000Z", lat: 48.8584, lon: 2.2945),
            makeAsset(id: "early", time: "2024-07-01T10:00:00.000Z", lat: 48.8984, lon: 2.2945)
        ])
        XCTAssertEqual(clusters.map { $0.assets.first?.id }, ["early", "late"])
    }

    // MARK: - Unlocated attachment

    func test_cluster_unlocatedAttachesByTime() {
        let located = makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 48.8584, lon: 2.2945)
        let noGPS = makeAsset(id: "b", time: "2024-07-01T10:10:00.000Z")
        let clusters = RoadTripClusterer.cluster([located, noGPS])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].assets.map(\.id)), ["a", "b"])
    }

    func test_cluster_unlocatedFirstThenLocated_doesNotCrash() {
        // An unlocated photo far in time from the others gets a cluster of its
        // own before any located one: the located clusters' anchors must not
        // be looked up by the wrong index (crashed on the Immich demo album).
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "u", time: "2024-07-01T08:00:00.000Z"),
            makeAsset(id: "a", time: "2024-07-02T10:00:00.000Z", lat: 48.8584, lon: 2.2945),
            makeAsset(id: "b", time: "2024-07-02T10:05:00.000Z", lat: 48.8590, lon: 2.2950),
        ])
        XCTAssertEqual(Set(clusters.flatMap(\.assets).map(\.id)), ["u", "a", "b"])
        XCTAssertTrue(clusters.contains { Set($0.assets.map(\.id)) == ["a", "b"] }, "a and b are one stop")
    }

    func test_cluster_unlocatedFormsTrailingCluster() {
        let located = makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 48.8584, lon: 2.2945)
        let farNoGPS = makeAsset(id: "b", time: "2024-07-10T10:00:00.000Z")
        let clusters = RoadTripClusterer.cluster([located, farNoGPS], timeGapThreshold: 4 * 3600)
        XCTAssertEqual(clusters.count, 2)
        // The unlocated asset lands in its own trailing cluster.
        let trailing = clusters.first { $0.assets.map(\.id) == ["b"] }
        XCTAssertNotNil(trailing)
        XCTAssertNil(trailing?.latitude)
    }

    // MARK: - Medoid + determinism

    func test_cluster_sitsOnThePhotoNearestTheMean() {
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 48.8580, lon: 2.2940),
            makeAsset(id: "b", time: "2024-07-01T10:05:00.000Z", lat: 48.8583, lon: 2.2944),
            makeAsset(id: "c", time: "2024-07-01T10:10:00.000Z", lat: 48.8590, lon: 2.2950)
        ])
        // The mean (48.8584, 2.2945) is nobody's spot; "b" is the nearest photo.
        XCTAssertEqual(clusters[0].latitude!, 48.8583, accuracy: 0.000001)
        XCTAssertEqual(clusters[0].longitude!, 2.2944, accuracy: 0.000001)
    }

    func test_cluster_idDeterministic() {
        let assets = [
            makeAsset(id: "b", time: "2024-07-01T10:05:00.000Z", lat: 48.8584, lon: 2.2945),
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 48.8584, lon: 2.2945)
        ]
        let first = RoadTripClusterer.cluster(assets)
        let second = RoadTripClusterer.cluster(assets)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    // MARK: - Haversine

    func test_haversine_knownDistance() {
        let a = CLLocationCoordinate2D(latitude: 48.8584, longitude: 2.2945)
        let b = CLLocationCoordinate2D(latitude: 48.8634, longitude: 2.2945)
        let d = RoadTripClusterer.haversine(a, b)
        XCTAssertEqual(d, 556, accuracy: 20)
    }

    // MARK: - Consecutive merge (same-place fusion)

    /// Three spread-out clusters of the same city (each pair > 2.5 km, so the
    /// greedy pass keeps them apart): the merge pass fuses them into one stop —
    /// one "Sóller" in the film.
    func test_merge_samePlaceNameConsecutiveChains() {
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 39.7669, lon: 2.7152, city: "Sóller", country: "Spain"),
            makeAsset(id: "b", time: "2024-07-01T10:30:00.000Z", lat: 39.8000, lon: 2.7300, city: "Sóller", country: "Spain"),
            makeAsset(id: "c", time: "2024-07-01T11:00:00.000Z", lat: 39.8300, lon: 2.7400, city: "Sóller", country: "Spain")
        ])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].assets.map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(clusters[0].placeName, "Sóller, Spain")
        XCTAssertEqual(clusters[0].startDate, ISO8601.immichFormatter.date(from: "2024-07-01T10:00:00.000Z"))
        XCTAssertEqual(clusters[0].endDate, ISO8601.immichFormatter.date(from: "2024-07-01T11:00:00.000Z"))
    }

    func test_merge_distanceBringsDifferentPlacesTogether() {
        // Same-area clusters with different EXIF places merge by distance.
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 39.7669, lon: 2.7152, city: "Sóller", country: "Spain"),
            makeAsset(id: "b", time: "2024-07-01T10:30:00.000Z", lat: 39.7950, lon: 2.7300, city: "Port de Sóller", country: "Spain")
        ])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].assets.map(\.id)), ["a", "b"])
        XCTAssertEqual(clusters[0].placeName, "Sóller, Spain")
    }

    func test_merge_noMergeFarApart() {
        // Distinct towns far apart stay separate stops.
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 39.7669, lon: 2.7152, city: "Sóller", country: "Spain"),
            makeAsset(id: "b", time: "2024-07-01T11:00:00.000Z", lat: 39.6236, lon: 2.9064, city: "Sineu", country: "Spain")
        ])
        XCTAssertEqual(clusters.count, 2)
    }

    func test_merge_noMergeNonConsecutiveReturn() {
        // Palma → Sineu → Palma: the two Palma stops are ~3 km apart (beyond
        // the greedy radius, inside the merge radius) but NOT consecutive —
        // the story A → B → A survives as three stops.
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 39.5696, lon: 2.6502, city: "Palma", country: "Spain"),
            makeAsset(id: "b", time: "2024-07-01T12:00:00.000Z", lat: 39.6236, lon: 2.9064, city: "Sineu", country: "Spain"),
            makeAsset(id: "c", time: "2024-07-01T15:00:00.000Z", lat: 39.5950, lon: 2.6650, city: "Palma", country: "Spain")
        ])
        XCTAssertEqual(clusters.count, 3)
    }

    func test_merge_timeGapBlocksSamePlace() {
        // Same city, but the photos are days apart — a different visit.
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 39.7669, lon: 2.7152, city: "Sóller", country: "Spain"),
            makeAsset(id: "b", time: "2024-07-03T10:00:00.000Z", lat: 39.8200, lon: 2.7200, city: "Sóller", country: "Spain")
        ])
        XCTAssertEqual(clusters.count, 2)
    }

    func test_merge_samePlaceNameFusesDespiteDistance() {
        // Same EXIF place name ~12 km apart within the time window: the
        // consecutive-merge pass fuses on place-name (OR distance), so one
        // town shot from far viewpoints stays a single stop.
        let clusters = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 39.7669, lon: 2.7152, city: "Sóller", country: "Spain"),
            makeAsset(id: "b", time: "2024-07-01T11:00:00.000Z", lat: 39.87, lon: 2.72, city: "Sóller", country: "Spain")
        ])
        XCTAssertEqual(clusters.count, 1)
    }

    func test_merge_idDeterministicAndStable() {
        let first = RoadTripClusterer.cluster([
            makeAsset(id: "b", time: "2024-07-01T10:30:00.000Z", lat: 39.7700, lon: 2.7220, city: "Sóller", country: "Spain"),
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 39.7669, lon: 2.7152, city: "Sóller", country: "Spain")
        ])
        let second = RoadTripClusterer.cluster([
            makeAsset(id: "a", time: "2024-07-01T10:00:00.000Z", lat: 39.7669, lon: 2.7152, city: "Sóller", country: "Spain"),
            makeAsset(id: "b", time: "2024-07-01T10:30:00.000Z", lat: 39.7700, lon: 2.7220, city: "Sóller", country: "Spain")
        ])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }
}
