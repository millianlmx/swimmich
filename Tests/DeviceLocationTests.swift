import XCTest
@testable import ImmichSwiftUI

/// "My Location" on the Search map and in the adjust-location sheet
/// (L-25, B-29.2 and B-29.3), against a scripted device position: the
/// permission, the answers to the two system prompts and the fix are all set
/// up front, so each test reads what the view models did with them.
@MainActor
final class DeviceLocationTests: XCTestCase {

    private let paris = DeviceCoordinate(latitude: 48.8584, longitude: 2.2945)

    // MARK: - Fixtures

    private func scripted(
        _ status: DeviceLocationStatus,
        fix: DeviceCoordinate? = DeviceCoordinate(latitude: 48.8584, longitude: 2.2945),
        prompt: ScriptedDeviceLocationService.PromptAnswer = .allow,
        grantsPrecise: Bool = true
    ) -> ScriptedDeviceLocationService {
        ScriptedDeviceLocationService(
            status: status, fix: fix, promptAnswer: prompt, grantsPreciseAccuracy: grantsPrecise
        )
    }

    private func makeMapVM(_ location: ScriptedDeviceLocationService) -> MapViewModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceLocationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return MapViewModel(
            client: MockImmichClient(),
            cache: MapMarkerCache(accountID: "test-account", directory: dir),
            location: location
        )
    }

    private func makeSheetVM(
        _ location: ScriptedDeviceLocationService,
        mock: MockImmichClient = MockImmichClient()
    ) -> AdjustLocationViewModel {
        let asset = AssetReactItem(
            id: "asset-1", ownerId: "owner", ratio: 1.0,
            isFavorite: false, visibility: "timeline", isTrashed: false,
            isImage: true, thumbhash: nil, createdAt: "2024-07-01T00:00:00.000Z",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: 45.5, longitude: 6.8, stack: []
        )
        let detail = AssetDetailViewModel(asset: asset, client: mock)
        detail.geocoder = MockLocationGeocoding()
        return AdjustLocationViewModel(detail: detail, location: location)
    }

    // MARK: - AC-48 / AC-230 / AC-231: the map

    func test_AC_48_centersTheMapOnTheDevicePosition() async {
        let location = scripted(.authorizedFull)
        let vm = makeMapVM(location)

        await vm.centerOnMyLocation()

        XCTAssertEqual(vm.centerRequest?.coordinate, paris)
        XCTAssertNil(vm.locationNotice)
    }

    func test_AC_48_refusedLeavesTheMapWhereItIsAndExplains() async {
        let vm = makeMapVM(scripted(.denied))

        await vm.centerOnMyLocation()

        XCTAssertNil(vm.centerRequest, "the map must not move")
        XCTAssertEqual(vm.locationNotice?.cause, .denied)
        XCTAssertFalse(vm.showsUserLocation)
    }

    func test_AC_230_openingTheMapAsksNothingThenTheTapAsksOnce() async {
        let location = scripted(.notDetermined)
        let vm = makeMapVM(location)

        await vm.refreshLocationAuthorization()

        XCTAssertEqual(location.authorizationPromptCount, 0, "opening the map must not prompt")
        XCTAssertFalse(vm.showsUserLocation)
        XCTAssertNil(vm.centerRequest)

        await vm.centerOnMyLocation()

        XCTAssertEqual(location.authorizationPromptCount, 1)
        XCTAssertEqual(vm.centerRequest?.coordinate, paris)
        XCTAssertTrue(vm.showsUserLocation, "the position dot appears once the permission is given")

        await vm.centerOnMyLocation()
        XCTAssertEqual(location.authorizationPromptCount, 1, "an answered prompt is never raised again")
    }

    func test_AC_230_alreadyAllowedShowsTheDotWithoutAnyPrompt() async {
        let location = scripted(.authorizedFull)
        let vm = makeMapVM(location)

        await vm.refreshLocationAuthorization()

        XCTAssertTrue(vm.showsUserLocation)
        XCTAssertEqual(location.authorizationPromptCount, 0)
    }

    func test_AC_230_servicesOffAndNoFixEachNameTheirCauseAndKeepTheMap() async {
        let off = makeMapVM(scripted(.servicesDisabled))
        await off.centerOnMyLocation()
        XCTAssertEqual(off.locationNotice?.cause, .servicesDisabled)
        XCTAssertNil(off.centerRequest)

        let noFix = makeMapVM(scripted(.authorizedFull, fix: nil))
        await noFix.centerOnMyLocation()
        XCTAssertEqual(noFix.locationNotice?.cause, .unavailable)
        XCTAssertNil(noFix.centerRequest)

        XCTAssertNotEqual(off.locationNotice?.message, noFix.locationNotice?.message)
        XCTAssertNotEqual(off.locationNotice?.title, noFix.locationNotice?.title)
    }

    func test_AC_230_everyTapIsANewOrderAndASuccessClearsTheNotice() async {
        let vm = makeMapVM(scripted(.authorizedFull))
        await vm.centerOnMyLocation()
        let first = vm.centerRequest?.id
        await vm.centerOnMyLocation()
        XCTAssertNotNil(first)
        XCTAssertNotEqual(vm.centerRequest?.id, first, "a second tap on the same spot recenters again")
        XCTAssertNil(vm.locationNotice)
    }

    func test_AC_231_deniedOffersSettingsAndAnsweringNoDoesNotPromptAgain() async {
        let location = scripted(.notDetermined, prompt: .deny)
        let vm = makeMapVM(location)

        await vm.centerOnMyLocation()
        XCTAssertEqual(location.authorizationPromptCount, 1)
        XCTAssertEqual(vm.locationNotice?.cause, .denied)
        XCTAssertEqual(vm.locationNotice?.offersSettings, true)
        XCTAssertNil(vm.centerRequest)

        vm.locationNotice = nil
        await vm.centerOnMyLocation()
        XCTAssertEqual(location.authorizationPromptCount, 1, "a refusal is lifted in Settings, not by asking again")
        XCTAssertEqual(vm.locationNotice?.cause, .denied)
    }

    func test_AC_231_onlyARefusalOffersTheSettingsShortcut() {
        XCTAssertTrue(MyLocationNotice(cause: .denied).offersSettings)
        XCTAssertTrue(MyLocationNotice(cause: .preciseRequired).offersSettings)
        XCTAssertFalse(MyLocationNotice(cause: .servicesDisabled).offersSettings)
        XCTAssertFalse(MyLocationNotice(cause: .unavailable).offersSettings)
    }

    // MARK: - AC-232 / AC-234: the sheet

    func test_AC_232_sheetTakesTheDevicePositionAndSendsNothingUntilSave() async {
        let mock = MockImmichClient()
        let vm = makeSheetVM(scripted(.authorizedFull), mock: mock)

        await vm.useMyLocation()

        XCTAssertEqual(vm.pin, PhotoCoordinate(latitude: 48.8584, longitude: 2.2945))
        XCTAssertEqual(vm.latitudeText, "48.8584")
        XCTAssertEqual(vm.longitudeText, "2.2945")
        XCTAssertTrue(mock.updateAssetCalls.isEmpty, "My Location only moves the pin")

        let saved = await vm.save()

        XCTAssertTrue(saved)
        XCTAssertEqual(mock.lastUpdateAssetBody?.latitude, 48.8584)
        XCTAssertEqual(mock.lastUpdateAssetBody?.longitude, 2.2945)
    }

    func test_AC_232_refusedLeavesPinAndFieldsAndExplains() async {
        let mock = MockImmichClient()
        let vm = makeSheetVM(scripted(.denied), mock: mock)

        await vm.useMyLocation()

        XCTAssertEqual(vm.pin, PhotoCoordinate(latitude: 45.5, longitude: 6.8))
        XCTAssertEqual(vm.latitudeText, "45.5")
        XCTAssertEqual(vm.longitudeText, "6.8")
        XCTAssertEqual(vm.locationNotice?.cause, .denied)
        XCTAssertTrue(mock.updateAssetCalls.isEmpty)
    }

    func test_AC_234_reducedAccuracyAsksForTheTemporaryPreciseOneAndUsesIt() async {
        let location = scripted(.authorizedReduced, grantsPrecise: true)
        let vm = makeSheetVM(location)

        await vm.useMyLocation()

        XCTAssertEqual(location.preciseAccuracyRequestCount, 1)
        XCTAssertEqual(vm.pin, PhotoCoordinate(latitude: 48.8584, longitude: 2.2945))
        XCTAssertEqual(vm.latitudeText, "48.8584")
        XCTAssertNil(vm.locationNotice)
    }

    func test_AC_234_reducedAccuracyKeptMeansMessageAndNothingMoves() async {
        let mock = MockImmichClient()
        let location = scripted(.authorizedReduced, grantsPrecise: false)
        let vm = makeSheetVM(location, mock: mock)

        await vm.useMyLocation()

        XCTAssertEqual(location.preciseAccuracyRequestCount, 1)
        XCTAssertEqual(vm.locationNotice?.cause, .preciseRequired)
        XCTAssertEqual(vm.pin, PhotoCoordinate(latitude: 45.5, longitude: 6.8))
        XCTAssertEqual(vm.latitudeText, "45.5")
        XCTAssertEqual(vm.longitudeText, "6.8")
        XCTAssertTrue(mock.updateAssetCalls.isEmpty)
    }

    func test_AC_234_theMapCentersOnReducedAccuracyWithoutAnyExtraRequest() async {
        let location = scripted(.authorizedReduced, grantsPrecise: false)
        let vm = makeMapVM(location)

        await vm.centerOnMyLocation()

        XCTAssertEqual(location.preciseAccuracyRequestCount, 0)
        XCTAssertEqual(vm.centerRequest?.coordinate, paris)
        XCTAssertNil(vm.locationNotice)
    }
}
