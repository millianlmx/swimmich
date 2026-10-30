import XCTest
import MapKit
@testable import ImmichSwiftUI

@MainActor
final class MapViewModelTests: XCTestCase {

    private func makeMarker(id: String, lat: Double, lon: Double, city: String? = nil) -> MapMarkerResponseDto {
        MapMarkerResponseDto(id: id, lat: lat, lon: lon, city: city, state: nil, country: nil)
    }

    /// Isolated cache per test — a throwaway temp directory so the file-backed
    /// cache never collides across tests.
    private func makeIsolatedCache() -> (MapMarkerCache, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapViewModelTests-\(UUID().uuidString)", isDirectory: true)
        return (MapMarkerCache(accountID: "test-account", directory: dir), dir)
    }

    // MARK: - Load (AC-710)

    func test_loadMarkers_success() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [
            makeMarker(id: "paris", lat: 48.8566, lon: 2.3522),
            makeMarker(id: "nyc", lat: 40.7128, lon: -74.0060)
        ]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)

        await vm.loadMarkers()

        XCTAssertEqual(mock.requestCount, 1)
        XCTAssertEqual(vm.markers.count, 2)
        XCTAssertEqual(vm.markers.map(\.id), ["paris", "nyc"])
        XCTAssertEqual(vm.markers.first?.placeName, "")
        XCTAssertNil(vm.errorMessage)
    }

    func test_loadMarkers_idempotent() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "a1", lat: 48.85, lon: 2.35)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)

        await vm.loadMarkers()
        await vm.loadMarkers()

        XCTAssertEqual(mock.requestCount, 1, "second call must no-op (loaded)")
    }

    func test_loadMarkers_error() async {
        let mock = MockImmichClient()
        struct Boom: Error {}
        mock.mapMarkersError = Boom()
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)

        await vm.loadMarkers()

        XCTAssertTrue(vm.markers.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Cache (AC-710 perf)

    func test_loadMarkers_servesCache_thenRefreshes() async {
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        cache.save([makeMarker(id: "c1", lat: 48.85, lon: 2.35)])

        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "c1", lat: 48.85, lon: 2.35)]
        let vm = MapViewModel(client: mock, cache: cache)
        vm.refreshTTL = .zero // force the stale-cache background refresh path

        await vm.loadMarkers()
        // The background refresh now runs fire-and-forget; give it a beat to
        // land before asserting the network request.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.markers.map(\.id), ["c1"], "cached markers rendered")
        XCTAssertEqual(mock.requestCount, 1, "stale cache triggers one background refresh")
        XCTAssertNil(vm.errorMessage)
    }

    func test_loadMarkers_freshCache_skipsRefresh() async {
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        cache.save([makeMarker(id: "c1", lat: 48.85, lon: 2.35)])

        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "c1", lat: 48.85, lon: 2.35)]
        let vm = MapViewModel(client: mock, cache: cache)
        // Default TTL (10 min): a just-saved cache is fresh → no refetch.

        await vm.loadMarkers()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.markers.map(\.id), ["c1"], "fresh cache rendered")
        XCTAssertEqual(mock.requestCount, 0, "fresh cache skips the background refresh")
        XCTAssertNil(vm.errorMessage)
    }

    func test_loadMarkers_cacheRefreshFailure_keepsCache() async {
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        cache.save([makeMarker(id: "c1", lat: 48.85, lon: 2.35)])

        let mock = MockImmichClient()
        struct Boom: Error {}
        mock.mapMarkersError = Boom()
        let vm = MapViewModel(client: mock, cache: cache)
        vm.refreshTTL = .zero // exercise the refresh path so its failure is tested

        await vm.loadMarkers()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.markers.map(\.id), ["c1"], "refresh failure keeps cached markers")
        XCTAssertNil(vm.errorMessage, "background refresh failure is silent")
    }

    func test_cache_roundTrip() {
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(cache.load(), "empty cache")

        cache.save([
            makeMarker(id: "a", lat: 1, lon: 2),
            makeMarker(id: "b", lat: 3, lon: 4, city: "Paris")
        ])
        let loaded = cache.load()
        XCTAssertEqual(loaded?.count, 2)
        XCTAssertEqual(loaded?.first?.id, "a")
        XCTAssertEqual(loaded?.last?.city, "Paris")

        cache.clear()
        XCTAssertNil(cache.load())
    }

    func test_cache_age_tracksFreshness() {
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(cache.age(), "no cache → no age")

        cache.save([makeMarker(id: "a", lat: 1, lon: 2)])
        let age = cache.age()
        XCTAssertNotNil(age, "saved cache has an age")
        XCTAssertLessThan(age ?? .infinity, 5, "just-saved cache is fresh")

        cache.clear()
        XCTAssertNil(cache.age(), "cleared cache → no age")
    }

    func test_reload_after_error_retries() async {
        let mock = MockImmichClient()
        struct Boom: Error {}
        mock.mapMarkersError = Boom()
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        await vm.loadMarkers()
        XCTAssertNotNil(vm.errorMessage)

        mock.mapMarkersError = nil
        mock.mapMarkersResponse = [makeMarker(id: "a1", lat: 48.85, lon: 2.35)]
        await vm.reload()

        XCTAssertEqual(mock.requestCount, 2)
        XCTAssertEqual(vm.markers.count, 1)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Visible region filtering

    func test_setVisibleRect_filters_markers_in_rect() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [
            makeMarker(id: "paris", lat: 48.8566, lon: 2.3522),
            makeMarker(id: "nyc", lat: 40.7128, lon: -74.0060)
        ]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        vm.debounceInterval = .zero
        await vm.loadMarkers()

        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522))
        let rect = MKMapRect(x: center.x - 1_000_000, y: center.y - 1_000_000, width: 2_000_000, height: 2_000_000)

        vm.setVisibleRect(rect)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(vm.visiblePhotos.map(\.id), ["paris"])
        XCTAssertEqual(vm.visibleAnnotations.map(\.id), ["paris"])
    }

    func test_setVisibleRect_empty_region() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "paris", lat: 48.8566, lon: 2.3522)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        vm.debounceInterval = .zero
        await vm.loadMarkers()

        let far = MKMapPoint(CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093))
        let rect = MKMapRect(x: far.x - 1_000, y: far.y - 1_000, width: 2_000, height: 2_000)

        vm.setVisibleRect(rect)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(vm.visiblePhotos.isEmpty)
        XCTAssertTrue(vm.visibleAnnotations.isEmpty)
    }

    func test_setVisibleRect_worldZoom_subsamplesAnnotations() async {
        let mock = MockImmichClient()
        // 3000 markers spread across the whole world (a real library can be
        // 10k+); at world zoom the annotation set must stay bounded so MapKit
        // ingestion stays fast, while the photo sheet keeps every marker.
        var dtos: [MapMarkerResponseDto] = []
        for i in 0..<3000 {
            let lat = Double(i % 60) * 3.0 - 90.0
            let lon = Double(i % 120) * 3.0 - 180.0
            dtos.append(makeMarker(id: "m\(i)", lat: lat, lon: lon))
        }
        mock.mapMarkersResponse = dtos
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        vm.debounceInterval = .zero
        await vm.loadMarkers()

        let world = MKMapRect(x: 0, y: 0, width: 268_435_456, height: 268_435_456)
        vm.setVisibleRect(world)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(vm.visiblePhotos.count, 3000, "photo sheet keeps every marker of the region")
        XCTAssertGreaterThan(vm.visibleAnnotations.count, 0)
        XCTAssertLessThanOrEqual(vm.visibleAnnotations.count, 44 * 44, "world zoom subsamples annotations")
    }

    func test_setVisibleRect_fineZoom_keepsAllMarkersInRegion() async {
        let mock = MockImmichClient()
        // Markers ~0.02° apart around Paris (≈23k MKMapPoint units at this
        // latitude — Mercator stretches y by ~1.13M units/°): a tight region's
        // grid cells are finer than the spacing, so every marker must show.
        var dtos: [MapMarkerResponseDto] = []
        for i in 0..<10 {
            dtos.append(makeMarker(id: "p\(i)", lat: 48.85 + Double(i) * 0.02, lon: 2.35))
        }
        mock.mapMarkersResponse = dtos
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        vm.debounceInterval = .zero
        await vm.loadMarkers()

        // Rect centred on the middle marker, ±120k units ≈ covers all 10
        // (spread over ~204k units) while cellWidth 240k/44 ≈ 5.4k < spacing.
        let midLat = 48.85 + 0.09
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: midLat, longitude: 2.35))
        let rect = MKMapRect(x: center.x - 120_000, y: center.y - 120_000, width: 240_000, height: 240_000)
        vm.setVisibleRect(rect)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(vm.visiblePhotos.count, 10)
        XCTAssertEqual(vm.visibleAnnotations.count, 10, "fine zoom shows every marker of the region")
    }

    func test_setVisibleRect_worldZoom_annotationCountsSumToPhotos() async {
        let mock = MockImmichClient()
        // Same world-spread library as the subsampling test: every marker in
        // the region must be accounted for by exactly one annotation badge.
        var dtos: [MapMarkerResponseDto] = []
        for i in 0..<3000 {
            let lat = Double(i % 60) * 3.0 - 90.0
            let lon = Double(i % 120) * 3.0 - 180.0
            dtos.append(makeMarker(id: "m\(i)", lat: lat, lon: lon))
        }
        mock.mapMarkersResponse = dtos
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        vm.debounceInterval = .zero
        await vm.loadMarkers()

        let world = MKMapRect(x: 0, y: 0, width: 268_435_456, height: 268_435_456)
        vm.setVisibleRect(world)
        try? await Task.sleep(for: .milliseconds(80))

        let badgeTotal = vm.visibleAnnotations.reduce(0) { $0 + $1.representedCount }
        XCTAssertEqual(vm.visiblePhotos.count, 3000)
        XCTAssertEqual(badgeTotal, vm.visiblePhotos.count, "cluster/marker badges sum to the sheet total")
        XCTAssertLessThanOrEqual(vm.visibleAnnotations.count, 44 * 44, "still subsampled for fast ingestion")
    }

    func test_selectMarker_filtersToCellPhotos() async {
        let mock = MockImmichClient()
        // Two markers in the same grid cell (tight cluster), one far away.
        mock.mapMarkersResponse = [
            makeMarker(id: "a", lat: 48.8566, lon: 2.3522),
            makeMarker(id: "b", lat: 48.8567, lon: 2.3523),
            makeMarker(id: "nyc", lat: 40.7128, lon: -74.0060)
        ]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        vm.debounceInterval = .zero
        await vm.loadMarkers()

        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522))
        let rect = MKMapRect(x: center.x - 1_000_000, y: center.y - 1_000_000, width: 2_000_000, height: 2_000_000)
        vm.setVisibleRect(rect)
        try? await Task.sleep(for: .milliseconds(80))

        let badge = vm.visibleAnnotations.first { $0.photo.id == "a" }?.representedCount
        XCTAssertEqual(badge, 2, "same-cell markers share the badge")

        vm.selectMarker("a")
        XCTAssertEqual(vm.selectedMarkerID, "a")
        XCTAssertEqual(Set(vm.selectedMarkerPhotos.map(\.id)), Set(["a", "b"]), "selection shows the marker's cell photos")

        vm.selectMarker("unknown")
        XCTAssertNil(vm.selectedMarkerID)
        XCTAssertTrue(vm.selectedMarkerPhotos.isEmpty, "unknown marker clears the filter")

        vm.selectMarker("a")
        vm.deselectMarker()
        XCTAssertNil(vm.selectedMarkerID)
        XCTAssertTrue(vm.selectedMarkerPhotos.isEmpty, "deselect returns to the area photos")
    }

    func test_zoomRect_boundsCellPhotos_andNilForUnknown() async {
        let mock = MockImmichClient()
        // Two markers in the same grid cell, one far away.
        mock.mapMarkersResponse = [
            makeMarker(id: "a", lat: 48.8566, lon: 2.3522),
            makeMarker(id: "b", lat: 48.8567, lon: 2.3523),
            makeMarker(id: "nyc", lat: 40.7128, lon: -74.0060)
        ]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        vm.debounceInterval = .zero
        await vm.loadMarkers()

        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522))
        let rect = MKMapRect(x: center.x - 1_000_000, y: center.y - 1_000_000, width: 2_000_000, height: 2_000_000)
        vm.setVisibleRect(rect)
        try? await Task.sleep(for: .milliseconds(80))

        let zoom = vm.zoomRect(forMarker: "a")
        XCTAssertNotNil(zoom, "a live high-count marker yields a drill-in rect")
        let ptA = MKMapPoint(CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522))
        let ptB = MKMapPoint(CLLocationCoordinate2D(latitude: 48.8567, longitude: 2.3523))
        XCTAssertTrue(zoom?.contains(ptA) ?? false, "rect bounds the first cell photo")
        XCTAssertTrue(zoom?.contains(ptB) ?? false, "rect bounds the second cell photo")

        XCTAssertNil(vm.zoomRect(forMarker: "unknown"), "unknown id → no zoom rect")
    }

    func test_selectMarker_dropsStaleSelectionAfterRefilter() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "a", lat: 48.8566, lon: 2.3522)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        vm.debounceInterval = .zero
        await vm.loadMarkers()

        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522))
        let rect = MKMapRect(x: center.x - 100_000, y: center.y - 100_000, width: 200_000, height: 200_000)
        vm.setVisibleRect(rect)
        try? await Task.sleep(for: .milliseconds(80))
        vm.selectMarker("a")
        XCTAssertEqual(vm.selectedMarkerPhotos.count, 1)

        // Pan far away: the selected marker leaves the region → filter drops.
        let far = MKMapPoint(CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093))
        let farRect = MKMapRect(x: far.x - 100_000, y: far.y - 100_000, width: 200_000, height: 200_000)
        vm.setVisibleRect(farRect)
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertNil(vm.selectedMarkerID, "selection cleared when its marker leaves the region")
        XCTAssertTrue(vm.selectedMarkerPhotos.isEmpty)
    }

    // MARK: - MapPhoto adapter

    func test_reload_preserves_visiblePhotos_until_refresh() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "paris", lat: 48.8566, lon: 2.3522)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        vm.debounceInterval = .zero
        await vm.loadMarkers()

        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522))
        let rect = MKMapRect(x: center.x - 1_000_000, y: center.y - 1_000_000, width: 2_000_000, height: 2_000_000)
        vm.setVisibleRect(rect)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(vm.visiblePhotos.map(\.id), ["paris"])

        // Reload with a temporarily failing server: the visible sets must
        // survive the failed refetch instead of churning to empty (which
        // tears down the map photo sheet mid-presentation).
        struct Boom: Error {}
        mock.mapMarkersError = Boom()
        await vm.reload()
        XCTAssertEqual(vm.visiblePhotos.map(\.id), ["paris"], "visiblePhotos survive a failed reload")
        XCTAssertEqual(vm.visibleAnnotations.map(\.id), ["paris"])

        // Once the server recovers, reload re-filters against the last rect.
        mock.mapMarkersError = nil
        mock.mapMarkersResponse = [
            makeMarker(id: "paris", lat: 48.8566, lon: 2.3522),
            makeMarker(id: "sydney", lat: -33.8688, lon: 151.2093)
        ]
        await vm.reload()
        XCTAssertEqual(vm.visiblePhotos.map(\.id), ["paris"], "re-filter after successful reload")
    }

    func test_refreshMarkers_updatesMarkersAndCacheWithoutClearing() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "a1", lat: 48.85, lon: 2.35)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        await vm.loadMarkers()
        XCTAssertEqual(vm.markers.map(\.id), ["a1"])

        mock.mapMarkersResponse = [makeMarker(id: "a2", lat: 40.71, lon: -74.0)]
        await vm.refreshMarkers()

        XCTAssertEqual(vm.markers.map(\.id), ["a2"])
        XCTAssertEqual(cache.load()?.map(\.id), ["a2"], "cache re-saved, never cleared")
        XCTAssertNil(vm.errorMessage)
    }

    func test_refreshMarkers_failure_keepsStaleMarkersAndCache() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "a1", lat: 48.85, lon: 2.35)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache)
        await vm.loadMarkers()

        struct Boom: Error {}
        mock.mapMarkersError = Boom()
        await vm.refreshMarkers()

        XCTAssertEqual(vm.markers.map(\.id), ["a1"], "stale markers survive a failed refresh")
        XCTAssertEqual(cache.load()?.map(\.id), ["a1"])
        XCTAssertNil(vm.errorMessage, "refresh is silent")
    }

    func test_mapPhoto_asAssetItem_keeps_identity_and_coords() {
        let dto = MapMarkerResponseDto(id: "a1", lat: 48.8566, lon: 2.3522, city: "Paris", state: "Île-de-France", country: "France")
        let photo = MapPhoto(from: dto)
        XCTAssertEqual(photo.placeName, "Paris, Île-de-France, France")

        let item = photo.asAssetItem
        XCTAssertEqual(item.id, "a1")
        XCTAssertEqual(item.latitude, 48.8566)
        XCTAssertEqual(item.longitude, 2.3522)
        XCTAssertEqual(item.visibility, AssetReactItem.unresolvedVisibility, "markers do not carry the visibility")
        XCTAssertEqual(item.city, "Paris")
    }

    // MARK: - Marker filter (AC-5140..AC-5146)

    /// Dedicated UserDefaults suite: the real app's store must not leak a
    /// filter into a filter test (and the reverse).
    private func makeIsolatedSettings(_ suiteName: String = "MapViewModelTests-\(UUID().uuidString)") -> MapSettingsStore {
        MapSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    func test_applyFilter_queriesTheRouteWithItAndCachesItUnderItsOwnVariant() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "paris", lat: 48.8566, lon: 2.3522)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache, settings: makeIsolatedSettings())
        await vm.loadMarkers()
        XCTAssertEqual(mock.lastMapMarkersFilter, .all)

        let filtered = MapMarkerFilter(onlyFavorites: true, relativeDays: 30)
        await vm.applyFilter(filtered)

        XCTAssertEqual(vm.filter, filtered)
        XCTAssertEqual(mock.lastMapMarkersFilter, filtered, "the marker route carries the filter")
        XCTAssertEqual(mock.requestCount, 2, "one reload — not one request per control")
        XCTAssertEqual(vm.markers.map(\.id), ["paris"])

        // The filtered payload gets its own file: a filtered response is not a
        // valid answer for another filter.
        let files = try? FileManager.default.contentsOfDirectory(
            atPath: dir.appendingPathComponent("MapMarkers").path
        )
        XCTAssertEqual(files?.sorted(), ["markers-f1-a0-p0-r30.json", "markers.json"])
    }

    func test_applyFilter_usesTheFilteredCacheOnTheNextLoad() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "favorite", lat: 48.85, lon: 2.35)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = makeIsolatedSettings()
        let vm = MapViewModel(client: mock, cache: cache, settings: settings)
        await vm.applyFilter(MapMarkerFilter(onlyFavorites: true))

        let reopened = MapViewModel(client: mock, cache: cache, settings: settings)
        await reopened.loadMarkers()

        XCTAssertEqual(reopened.markers.map(\.id), ["favorite"], "a relaunch serves the filter's own cache")
        XCTAssertEqual(mock.requestCount, 1, "the filtered cache is fresh — no second fetch")
    }

    func test_applyFilter_isANoOpForAnIdenticalFilter() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "a1", lat: 48.85, lon: 2.35)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache, settings: makeIsolatedSettings())
        await vm.loadMarkers()

        await vm.applyFilter(.all)

        XCTAssertEqual(mock.requestCount, 1, "an unchanged filter must not refetch the whole catalogue")
        XCTAssertEqual(vm.markers.map(\.id), ["a1"])
    }

    func test_applyFilter_makesTheMarkersOfTheNewFilterTheOnlyVisibleOnes() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "paris", lat: 48.8566, lon: 2.3522)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache, settings: makeIsolatedSettings())
        vm.debounceInterval = .zero
        await vm.loadMarkers()

        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522))
        vm.setVisibleRect(MKMapRect(x: center.x - 1_000_000, y: center.y - 1_000_000, width: 2_000_000, height: 2_000_000))
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(vm.visiblePhotos.map(\.id), ["paris"])
        vm.selectMarker(vm.visibleAnnotations[0].id)

        mock.mapMarkersResponse = [makeMarker(id: "nyc", lat: 40.7128, lon: -74.0060)]
        await vm.applyFilter(MapMarkerFilter(relativeDays: 7))

        // Nothing of the previous filter survives — a filtered map must never
        // keep showing photos the filter excluded.
        XCTAssertEqual(vm.markers.map(\.id), ["nyc"])
        XCTAssertTrue(vm.visiblePhotos.isEmpty, "the previous filter's region photos are gone")
        XCTAssertNil(vm.selectedMarkerID)
        XCTAssertNil(vm.errorMessage)
    }

    func test_applyFilter_summaryNamesTheActiveFilter() async {
        let mock = MockImmichClient()
        mock.mapMarkersResponse = [makeMarker(id: "a1", lat: 48.85, lon: 2.35)]
        let (cache, dir) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = MapViewModel(client: mock, cache: cache, settings: makeIsolatedSettings())

        await vm.applyFilter(MapMarkerFilter(onlyFavorites: true, relativeDays: 30))

        // Both surfaces (badge, photo-sheet banner) render this one string, and
        // it is resolved through the catalog — never a hard-coded English.
        XCTAssertEqual(
            vm.activeFilterSummary,
            "\(localizedString("30 days")), \(localizedString("Favorites only"))"
        )
    }

    // MARK: - Per-account cache through the production wiring (AC-12, AC-20)

    private var realCachesRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    func test_ACC_AC12_productionMapIgnoresLegacyCacheFile() async throws {
        let variant = DependencyContainer.shared.mapSettings.filter.cacheVariant
        // A file written by the version without accounts, still fresh.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapLegacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let accountID = UUID().uuidString
        let seed = MapMarkerCache(accountID: accountID, directory: scratch, variant: variant)
        seed.save([makeMarker(id: "legacy-1", lat: 48.85, lon: 2.35)])
        let seeded = scratch.appendingPathComponent("MapMarkers/\(SavedAccount.storageKey(forID: accountID))")
            .appendingPathComponent(variant.map { "markers-\($0).json" } ?? "markers.json")
        let legacyFolder = realCachesRoot.appendingPathComponent("MapMarkers", isDirectory: true)
        let legacy = legacyFolder.appendingPathComponent(seeded.lastPathComponent)
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: legacy)
        try FileManager.default.copyItem(at: seeded, to: legacy)
        defer { try? FileManager.default.removeItem(at: legacy) }

        let vm = DependencyContainer.shared.makeMapViewModel(accountID: UUID().uuidString)
        await vm.loadMarkers()

        XCTAssertFalse(vm.markers.contains { $0.id == "legacy-1" }, "legacy file must not be served")
    }

    func test_ACC_AC20_productionMapIsScopedPerAccount() async {
        let container = DependencyContainer.shared
        let variant = container.mapSettings.filter.cacheVariant
        let accountA = UUID().uuidString
        let accountB = UUID().uuidString
        let ids = ["a-1", "a-2", "a-3"]
        MapMarkerCache(accountID: accountA).variant(variant)
            .save(ids.map { makeMarker(id: $0, lat: 48.85, lon: 2.35) })
        defer {
            let folder = realCachesRoot.appendingPathComponent("MapMarkers", isDirectory: true)
            for account in [accountA, accountB] {
                try? FileManager.default.removeItem(
                    at: folder.appendingPathComponent(SavedAccount.storageKey(forID: account)))
            }
        }

        let mapB = container.makeMapViewModel(accountID: accountB)
        await mapB.loadMarkers()
        XCTAssertTrue(mapB.markers.filter { ids.contains($0.id) }.isEmpty, "B must not see A's markers")

        let mapA = container.makeMapViewModel(accountID: accountA)
        await mapA.loadMarkers()
        XCTAssertEqual(Set(mapA.markers.map(\.id)), Set(ids), "A is served from its own disk cache")
    }
}
