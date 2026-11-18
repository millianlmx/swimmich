import UIKit
import XCTest
@testable import ImmichSwiftUI

/// Answers every request with a 4×4 PNG, or with a 500 when `failing`.
private final class RoadTripPreviewProtocol: URLProtocol {
    nonisolated(unsafe) static var failing = false

    static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
        UIColor.green.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let failing = Self.failing
        let response = HTTPURLResponse(
            url: request.url!, statusCode: failing ? 500 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": failing ? "text/plain" : "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: failing ? Data("boom".utf8) : Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The preparation builds the one timeline the film plays, keeps the photos
/// it shows decoded, and keeps its error on screen.
@MainActor
final class RoadTripPreparationTests: XCTestCase {

    override func tearDown() {
        RoadTripPreviewProtocol.failing = false
        super.tearDown()
    }

    private func makeAsset(id: String, isFavorite: Bool = false) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T10:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-07-01T10:00:00.000Z", ownerId: "owner", originalPath: "/x.jpg",
            originalFileName: "x.jpg", fileCreatedAt: "2024-07-01T10:00:00.000Z",
            fileModifiedAt: "2024-07-01T10:00:00.000Z", updatedAt: "2024-07-01T10:00:00.000Z",
            isFavorite: isFavorite, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    private func makeVM(
        assetIDs: [String],
        screenshots: Set<String> = [],
        places: [String: (latitude: Double, longitude: Double, time: String)] = [:]
    ) -> (RoadTripViewModel, MockImmichClient) {
        let mock = MockImmichClient()
        let items = assetIDs.map { id -> AssetResponseDto in
            var asset = makeAsset(id: id)
            // A camera photo names its camera; a screenshot names none.
            asset.exifInfo = screenshots.contains(id) ? ExifResponseDto() : ExifResponseDto(make: "Apple", model: "iPhone 15")
            if let place = places[id] {
                asset.exifInfo?.latitude = place.latitude
                asset.exifInfo?.longitude = place.longitude
                asset.fileCreatedAt = place.time
            }
            return asset
        }
        mock.searchMetadataResponse = SearchResponseDto(assets: SearchAssetResponseDto(
            count: assetIDs.count, items: items, nextPage: nil
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoadTripPreviewProtocol.self]
        let session = URLSession(configuration: configuration)
        let vm = RoadTripViewModel(
            client: mock, albumId: "album", selectedAssetIds: nil, albumTitle: "Trip",
            baseURL: { URL(string: "https://photos.example.org")! }, token: "tok",
            photos: MockPhotoLibraryService(), session: { session }
        )
        return (vm, mock)
    }

    func test_preparationKeepsTheDecodedPhotosOfTheFilm() async throws {
        let ids = ["a1", "a2", "a3"]
        let (vm, _) = makeVM(assetIDs: ids)

        await vm.prepare()

        XCTAssertFalse(vm.isPreparing)
        XCTAssertNil(vm.errorMessage)
        let timeline = try XCTUnwrap(vm.timeline)
        let shown = RoadTripViewModel.shownAssets(in: timeline, clusters: vm.clusters).map(\.id)
        XCTAssertEqual(Set(shown), Set(ids))
        XCTAssertEqual(Set(vm.slideImages.keys), Set(shown), "every photo of the film is held decoded, and only those")
        for asset in vm.clusters.flatMap(\.assets) {
            XCTAssertNotNil(vm.slideImage(for: asset), "no preloaded image for \(asset.id)")
        }
    }

    func test_preparationRunsOnce() async {
        let (vm, mock) = makeVM(assetIDs: ["a1", "a2"])

        await vm.prepare()
        let timeline = vm.timeline
        await vm.prepare()

        XCTAssertEqual(mock.searchMetadataCalls.count, 1, "a second appearance must not rebuild the film")
        XCTAssertEqual(vm.timeline, timeline)
    }

    func test_preparationKeepsTheErrorWhenNoPhotoLoads() async {
        RoadTripPreviewProtocol.failing = true
        let (vm, _) = makeVM(assetIDs: ["a1", "a2"])

        await vm.prepare()

        XCTAssertFalse(vm.isPreparing)
        XCTAssertNil(vm.timeline, "no film made of black frames")
        XCTAssertEqual(vm.errorMessage, String(localized: "No displayable photos."))
        XCTAssertTrue(vm.slideImages.isEmpty)
    }

    func test_straightLegsJoinConsecutiveLocatedStops() {
        func stop(_ id: String, _ lat: Double?, _ lon: Double?) -> RoadTripCluster {
            RoadTripCluster(id: id, assets: [], latitude: lat, longitude: lon, placeName: nil, startDate: nil, endDate: nil)
        }
        let legs = RoadTripViewModel.straightLegs(between: [
            stop("paris", 48.85, 2.35), stop("versailles", 48.80, 2.13), stop("nowhere", nil, nil), stop("lyon", 45.76, 4.84)
        ])

        XCTAssertEqual(legs.map(\.fromClusterID), ["paris"])
        XCTAssertEqual(legs.first?.toClusterID, "versailles")
        XCTAssertEqual(legs.first?.route.count, 2)
    }

    func test_anchoringPutsEveryStopWhereTheCarArrives() {
        func stop(_ id: String, _ lat: Double, _ lon: Double) -> RoadTripCluster {
            RoadTripCluster(id: id, assets: [], latitude: lat, longitude: lon, placeName: nil, startDate: nil, endDate: nil)
        }
        func point(_ lat: Double, _ lon: Double) -> RoutePoint { RoutePoint(latitude: lat, longitude: lon) }
        // Routes start and end on the road, off the photo spots; the second
        // route leaves from a road point a little away from the first's end.
        let legs = [
            RoadTripLeg(fromClusterID: "a", toClusterID: "b", distanceMeters: 1_000,
                        route: [point(48.001, 2.001), point(48.05, 2.05), point(48.101, 2.101)]),
            RoadTripLeg(fromClusterID: "b", toClusterID: "c", distanceMeters: 1_000,
                        route: [point(48.102, 2.102), point(48.15, 2.15), point(48.199, 2.199)])
        ]
        let result = RoadTripAnchoring.anchored(
            clusters: [stop("a", 48.0, 2.0), stop("b", 48.1, 2.1), stop("c", 48.2, 2.2)],
            legs: legs
        )

        XCTAssertEqual(result.clusters.map(\.latitude), [48.001, 48.101, 48.199])
        XCTAssertEqual(result.clusters.map(\.longitude), [2.001, 2.101, 2.199])
        // The car leaves "b" from where it stopped, then joins its road.
        XCTAssertEqual(result.legs[1].route.first, point(48.101, 2.101))
        XCTAssertEqual(Array(result.legs[1].route.dropFirst()), legs[1].route)
        XCTAssertEqual(result.legs[0].route, legs[0].route)
    }

    func test_anchoringKeepsAStopWithoutLegs() {
        let lone = RoadTripCluster(id: "a", assets: [], latitude: 48.0, longitude: 2.0, placeName: nil, startDate: nil, endDate: nil)
        let result = RoadTripAnchoring.anchored(clusters: [lone], legs: [])
        XCTAssertEqual(result.clusters, [lone])
    }

    func test_scoreSinksNightSkiesBlurAndUtilityShots() {
        let good = RoadTripPhotoScore.Look(sharpness: 0.8, brightness: 0.55, colorfulness: 0.6)
        let night = RoadTripPhotoScore.Look(sharpness: 0.8, brightness: 0.08, colorfulness: 0.6)
        let blurred = RoadTripPhotoScore.Look(sharpness: 0.1, brightness: 0.55, colorfulness: 0.6)
        let base = RoadTripPhotoScore.combine(look: good, aesthetics: 0.7, isUtility: false, faces: 0)

        XCTAssertLessThan(RoadTripPhotoScore.combine(look: night, aesthetics: 0.7, isUtility: false, faces: 0), base)
        XCTAssertLessThan(RoadTripPhotoScore.combine(look: blurred, aesthetics: 0.7, isUtility: false, faces: 0), base)
        XCTAssertLessThan(RoadTripPhotoScore.combine(look: good, aesthetics: 0.7, isUtility: true, faces: 0), base / 2)
        XCTAssertGreaterThan(RoadTripPhotoScore.combine(look: good, aesthetics: 0.7, isUtility: false, faces: 2), base)
        XCTAssertGreaterThan(RoadTripPhotoScore.combine(look: good, aesthetics: 0.9, isUtility: false, faces: 0), base)
        XCTAssertEqual(RoadTripPhotoScore.combine(look: good, aesthetics: nil, isUtility: false, faces: 0), good.score, accuracy: 1e-9)
    }

    func test_scoringSampleSpreadsOverEveryStop() {
        func asset(_ id: String, favorite: Bool = false) -> AssetReactItem {
            AssetReactItem(from: makeAsset(id: id, isFavorite: favorite))
        }
        let big = RoadTripCluster(
            id: "big", assets: (0..<100).map { asset("b\($0)", favorite: $0 == 57) },
            latitude: nil, longitude: nil, placeName: nil, startDate: nil, endDate: nil
        )
        let small = RoadTripCluster(
            id: "small", assets: (0..<3).map { asset("s\($0)") },
            latitude: nil, longitude: nil, placeName: nil, startDate: nil, endDate: nil
        )
        let sample = RoadTripViewModel.scoringSample(of: [big, small]).map(\.id)

        XCTAssertTrue(sample.contains("b0") && sample.contains("b99"), "a long stop is looked at from end to end")
        XCTAssertTrue(sample.contains("b57"), "favorites are always scored")
        XCTAssertTrue(["s0", "s1", "s2"].allSatisfy(sample.contains), "a small stop is scored whole")
        XCTAssertLessThanOrEqual(sample.count, RoadTripViewModel.scoringSamplePerStop + 1 + 3)
    }

    func test_preparationLeavesScreenshotsOut() async throws {
        let (vm, _) = makeVM(assetIDs: ["a1", "a2", "story"], screenshots: ["story"])

        await vm.prepare()

        let ids = vm.editableStops.flatMap(\.assets).map(\.id)
        XCTAssertEqual(Set(ids), ["a1", "a2"], "an image saved from an app is not a photo of the trip")
        XCTAssertNotNil(vm.timeline)
    }

    func test_applyRebuildsTheFilmWithoutTheLeftOutPhotos() async throws {
        let (vm, _) = makeVM(assetIDs: ["a1", "a2", "a3"])
        await vm.prepare()
        XCTAssertEqual(vm.shownAssetIDs, ["a1", "a2", "a3"])

        var settings = vm.settings
        settings.excluded = ["a2"]
        settings.photosPerStop = 2
        await vm.apply(settings)
        defer { RoadTripSettingsStore(albumId: "album").save(RoadTripSettings()) }

        XCTAssertFalse(vm.isPreparing)
        XCTAssertEqual(vm.shownAssetIDs, ["a1", "a3"])
        XCTAssertEqual(Set(vm.slideImages.keys), ["a1", "a3"], "only the photos of the film stay decoded")
        XCTAssertEqual(vm.editableStops.flatMap(\.assets).count, 3, "a photo left out stays listed, to bring it back")
    }

    func test_settingsCycleAndPersist() {
        var settings = RoadTripSettings()
        settings.cycleChoice(for: "x")
        XCTAssertEqual(settings.choice(for: "x"), .pinned)
        settings.cycleChoice(for: "x")
        XCTAssertEqual(settings.choice(for: "x"), .excluded)
        settings.cycleChoice(for: "x")
        XCTAssertEqual(settings.choice(for: "x"), .auto)

        let defaults = UserDefaults(suiteName: "roadtrip-settings-test")!
        defer { defaults.removePersistentDomain(forName: "roadtrip-settings-test") }
        let store = RoadTripSettingsStore(albumId: "trip", defaults: defaults)
        XCTAssertEqual(store.load(), RoadTripSettings())
        settings.length = .long
        settings.collages = .max
        settings.carColor = .red
        settings.pinned = ["p"]
        store.save(settings)
        XCTAssertEqual(store.load(), settings)
        XCTAssertEqual(store.load().builderOptions.targetDuration, 60)
        XCTAssertEqual(RoadTripSettingsStore(albumId: "other", defaults: defaults).load(), RoadTripSettings(), "settings are per album")
    }

    /// A stop that leaves the film makes its neighbours neighbours: their
    /// road is asked for then (here read from the route cache, no network).
    func test_stopsThatBecomeNeighboursGetTheirRoad() async throws {
        let a = RoutePoint(latitude: 48.80, longitude: 2.30)
        let b = RoutePoint(latitude: 48.90, longitude: 2.40)
        let c = RoutePoint(latitude: 49.00, longitude: 2.50)
        let roads: [(RoutePoint, RoutePoint, [RoutePoint])] = [
            (a, b, [a, RoutePoint(latitude: 48.85, longitude: 2.32), b]),
            (b, c, [b, RoutePoint(latitude: 48.95, longitude: 2.42), c]),
            (a, c, [a, RoutePoint(latitude: 48.90, longitude: 2.20), c])
        ]
        for (from, to, route) in roads { RoadTripRouteCache.store(route, from: from, to: to) }
        defer {
            for (from, to, _) in roads {
                if let url = RoadTripRouteCache.fileURL(from: from, to: to) { try? FileManager.default.removeItem(at: url) }
            }
            RoadTripSettingsStore(albumId: "album").save(RoadTripSettings())
        }
        let (vm, _) = makeVM(assetIDs: ["a", "b", "c"], places: [
            "a": (48.80, 2.30, "2024-07-01T10:00:00.000Z"),
            "b": (48.90, 2.40, "2024-07-01T12:00:00.000Z"),
            "c": (49.00, 2.50, "2024-07-01T14:00:00.000Z")
        ])
        await vm.prepare()
        XCTAssertEqual(vm.legs.map(\.route), [roads[0].2, roads[1].2])

        var settings = vm.settings
        settings.excluded = ["b"]
        await vm.apply(settings)

        XCTAssertEqual(vm.legs.count, 1)
        XCTAssertEqual(vm.legs.first?.route, roads[2].2, "the road from a to c, not a straight line")
    }
}
