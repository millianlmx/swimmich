import XCTest
import MapKit
import SwiftUI
@testable import ImmichSwiftUI

/// Adjust-location sheet (L-25, B-29.1): typed coordinates, pin sync, save.
@MainActor
final class AdjustLocationViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makeAsset(latitude: Double?, longitude: Double?) -> AssetReactItem {
        AssetReactItem(
            id: "asset-1", ownerId: "owner", ratio: 1.0,
            isFavorite: false, visibility: "timeline", isTrashed: false,
            isImage: true, thumbhash: nil, createdAt: "2024-07-01T00:00:00.000Z",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: latitude, longitude: longitude, stack: []
        )
    }

    private func makeDTO(latitude: Double?, longitude: Double?) -> AssetResponseDto {
        AssetResponseDto(
            id: "asset-1", type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2024-07-01T00:00:00.000Z",
            ownerId: "owner", originalPath: "/x.jpg", originalFileName: "x.jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", fileModifiedAt: "2024-07-01T00:00:00.000Z",
            updatedAt: "2024-07-01T00:00:00.000Z", isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false,
            exifInfo: ExifResponseDto(
                make: nil, model: nil, exifImageWidth: nil, exifImageHeight: nil,
                fileSizeInByte: nil, orientation: nil, dateTimeOriginal: nil,
                modifyDate: nil, timeZone: nil, lensModel: nil, fNumber: nil,
                focalLength: nil, iso: nil, exposureTime: nil, latitude: latitude,
                longitude: longitude, city: nil, state: nil, country: nil,
                description: nil, projectionType: nil, rating: nil
            )
        )
    }

    /// A detail view model for a photo at 45.5, 6.8 (`located`) or without a
    /// location. Every successful write answers with the coordinates it was sent.
    private func makeVM(
        located: Bool,
        client: (any ImmichClient)? = nil,
        mock: MockImmichClient = MockImmichClient()
    ) -> AdjustLocationViewModel {
        let detail = AssetDetailViewModel(
            asset: makeAsset(latitude: located ? 45.5 : nil, longitude: located ? 6.8 : nil),
            client: client ?? (mock as any ImmichClient)
        )
        detail.geocoder = MockLocationGeocoding()
        if located { detail.detail = makeDTO(latitude: 45.5, longitude: 6.8) }
        return AdjustLocationViewModel(detail: detail)
    }

    // MARK: - S-1 tables

    func test_AC_229_parseTable() {
        let lat = CoordinateAxis.latitude
        let lon = CoordinateAxis.longitude
        let values: [(String, CoordinateAxis, Double)] = [
            ("48,8584", lat, 48.8584), ("2.2945", lon, 2.2945), (" -33,8688 ", lat, -33.8688),
            ("+45", lat, 45), ("\u{2212}33.5", lat, -33.5), ("12.", lat, 12), (".5", lat, 0.5),
            ("90", lat, 90), ("-90", lat, -90), ("180", lon, 180), ("-180", lon, -180),
        ]
        for (text, axis, expected) in values {
            XCTAssertEqual(try? AdjustLocationViewModel.parse(text, axis: axis).get(), expected, "\(text)")
        }
        let failures: [(String, CoordinateAxis, CoordinateFieldError)] = [
            ("90.0001", lat, .outOfRange), ("95", lat, .outOfRange), ("180.5", lon, .outOfRange),
            ("abc", lat, .notNumeric), ("-", lat, .notNumeric), ("1e1", lat, .notNumeric),
            ("nan", lat, .notNumeric), ("1.2.3", lat, .notNumeric), ("1,234.5", lon, .notNumeric),
            ("--1", lat, .notNumeric), ("", lat, .empty), ("   ", lon, .empty),
        ]
        for (text, axis, expected) in failures {
            switch AdjustLocationViewModel.parse(text, axis: axis) {
            case .success(let v): XCTFail("\(text) read as \(v)")
            case .failure(let e): XCTAssertEqual(e, expected, "\(text)")
            }
        }
    }

    func test_AC_228_formatTable() {
        let table: [(Double, String)] = [
            (45.5, "45.5"), (6.8, "6.8"), (-33.8688, "-33.8688"), (2.294512345, "2.294512"),
            (90, "90"), (-0.0, "0"), (151.2093, "151.2093"),
        ]
        for (value, expected) in table {
            XCTAssertEqual(AdjustLocationViewModel.format(value), expected)
        }
        XCTAssertEqual(
            AdjustLocationViewModel.accessibilityValue(PhotoCoordinate(latitude: 48.8584, longitude: 2.2945)),
            "48.8584, 2.2945"
        )
    }

    func test_AC_229_messagesNameTheField() {
        let pairs: [(CoordinateFieldError, CoordinateAxis, String)] = [
            (.empty, .latitude, "Enter a latitude."),
            (.notNumeric, .latitude, "Latitude must be a number."),
            (.outOfRange, .latitude, "Latitude must be between -90 and 90."),
            (.empty, .longitude, "Enter a longitude."),
            (.notNumeric, .longitude, "Longitude must be a number."),
            (.outOfRange, .longitude, "Longitude must be between -180 and 180."),
        ]
        var seen = Set<String>()
        for (error, axis, key) in pairs {
            let message = AdjustLocationViewModel.message(for: error, axis: axis)
            XCTAssertEqual(message, localizedString(key))
            seen.insert(message)
        }
        XCTAssertEqual(seen.count, 6)
    }

    // MARK: - S-2/S-3 fields and pin

    func test_AC_228_prefillsFromExifAndMovesPinBeforeSave() async {
        let mock = MockImmichClient()
        let vm = makeVM(located: true, mock: mock)
        XCTAssertEqual(vm.latitudeText, "45.5")
        XCTAssertEqual(vm.longitudeText, "6.8")
        XCTAssertEqual(vm.pin, PhotoCoordinate(latitude: 45.5, longitude: 6.8))
        XCTAssertFalse(vm.startedWithoutLocation)

        vm.pinDragged(to: PhotoCoordinate(latitude: 46.123456789, longitude: 7.5))
        XCTAssertEqual(vm.latitudeText, "46.123457")
        XCTAssertEqual(vm.longitudeText, "7.5")
        XCTAssertEqual(vm.pin, PhotoCoordinate(latitude: 46.123456789, longitude: 7.5))

        vm.latitudeText = "-33,8688"
        vm.longitudeText = "151.2093"
        XCTAssertEqual(vm.pin, PhotoCoordinate(latitude: -33.8688, longitude: 151.2093))
        XCTAssertTrue(mock.updateAssetCalls.isEmpty)

        mock.updateAssetResponse = makeDTO(latitude: -33.8688, longitude: 151.2093)
        let saved = await vm.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(mock.updateAssetCalls.count, 1)
        XCTAssertEqual(mock.lastUpdateAssetBody?.latitude, -33.8688)
        XCTAssertEqual(mock.lastUpdateAssetBody?.longitude, 151.2093)
    }

    func test_AC_47_savesTypedValuesWithoutSubmit() async {
        let mock = MockImmichClient()
        let vm = makeVM(located: true, mock: mock)
        vm.latitudeText = "48,8584"
        vm.longitudeText = "2.2945"
        let saved = await vm.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(mock.lastUpdateAssetBody?.latitude, 48.8584)
        XCTAssertEqual(mock.lastUpdateAssetBody?.longitude, 2.2945)

        vm.latitudeText = "95"
        let refused = await vm.save()
        XCTAssertFalse(refused)
        XCTAssertEqual(vm.latitudeError, .outOfRange)
        XCTAssertEqual(mock.updateAssetCalls.count, 1)
    }

    func test_AC_47_staleDetailErrorDoesNotBlockSave() async {
        let mock = MockImmichClient()
        let vm = makeVM(located: true, mock: mock)
        vm.detail.errorMessage = "old"
        let saved = await vm.save()
        XCTAssertTrue(saved)
        XCTAssertNil(vm.detail.errorMessage)
    }

    func test_AC_47_serverErrorKeepsSheetOpen() async {
        let mock = MockImmichClient()
        mock.updateAssetError = APIError.serverError(500, "boom")
        let vm = makeVM(located: true, mock: mock)
        let saved = await vm.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(vm.detail.errorMessage, UserFacingError.serverErrorMessage)
        XCTAssertFalse(vm.isSaving)
    }

    func test_AC_229_invalidFieldsBlockSaveAndClearWhenFixed() async {
        let mock = MockImmichClient()
        let vm = makeVM(located: true, mock: mock)
        let start = vm.pin

        vm.longitudeText = "180.5"
        XCTAssertNil(vm.longitudeError, "an error never appears while typing")
        let first = await vm.save()
        XCTAssertFalse(first)
        XCTAssertEqual(vm.longitudeError, .outOfRange)
        XCTAssertNotEqual(vm.pin?.longitude, 180.5)
        XCTAssertTrue(mock.updateAssetCalls.isEmpty)
        vm.longitudeText = "179"
        XCTAssertNil(vm.longitudeError)

        vm.longitudeText = "6.8"
        XCTAssertEqual(vm.pin, start)
        vm.latitudeText = "abc"
        let second = await vm.save()
        XCTAssertFalse(second)
        XCTAssertEqual(vm.latitudeError, .notNumeric)
        XCTAssertEqual(vm.pin, start, "the pin keeps the last valid pair")
        vm.latitudeText = ""
        let third = await vm.save()
        XCTAssertFalse(third)
        XCTAssertEqual(vm.latitudeError, .empty)
        XCTAssertTrue(mock.updateAssetCalls.isEmpty)

        vm.latitudeText = "90"
        vm.longitudeText = "-180"
        XCTAssertNil(vm.latitudeError)
        let ok = await vm.save()
        XCTAssertTrue(ok)
        XCTAssertEqual(mock.updateAssetCalls.count, 1)
        XCTAssertEqual(mock.lastUpdateAssetBody?.latitude, 90)
        XCTAssertEqual(mock.lastUpdateAssetBody?.longitude, -180)

        let clean = makeVM(located: true, mock: mock)
        clean.latitudeText = "-"
        XCTAssertNil(clean.latitudeError)
    }

    // MARK: - Photo without a location (AC-233)

    func test_AC_233_photoWithoutLocationStartsEmptyAndAddsOne() async {
        let mock = MockImmichClient()
        mock.updateAssetResponse = makeDTO(latitude: 48.8584, longitude: 2.2945)
        let vm = makeVM(located: false, mock: mock)
        XCTAssertEqual(vm.latitudeText, "")
        XCTAssertEqual(vm.longitudeText, "")
        XCTAssertNil(vm.pin)
        XCTAssertTrue(vm.startedWithoutLocation)

        let empty = await vm.save()
        XCTAssertFalse(empty)
        XCTAssertEqual(vm.latitudeError, .empty)
        XCTAssertEqual(vm.longitudeError, .empty)
        XCTAssertTrue(mock.updateAssetCalls.isEmpty)

        vm.latitudeText = "48,8584"
        XCTAssertNil(vm.pin, "one valid value is not a location")
        vm.longitudeText = "2.2945"
        XCTAssertEqual(vm.pin, PhotoCoordinate(latitude: 48.8584, longitude: 2.2945))

        let saved = await vm.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(vm.detail.detail?.exifInfo?.latitude, 48.8584)
    }

    func test_AC_233_readOnlyRefusesWithoutRequest() async {
        let mock = MockImmichClient()
        let guarded = ReadOnlyGuardClient(inner: mock, isEnabled: { true })
        let vm = makeVM(located: false, client: guarded, mock: mock)
        vm.latitudeText = "48,8584"
        vm.longitudeText = "2.2945"
        let saved = await vm.save()
        XCTAssertFalse(saved)
        XCTAssertTrue(mock.updateAssetCalls.isEmpty)
        XCTAssertEqual(vm.detail.errorMessage, UserFacingError.readOnlyModeMessage)
    }

    // MARK: - Hosted views

    private func host<V: View>(_ view: V) -> (UIHostingController<V>, UIWindow) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    private func descendants<T: UIView>(of root: UIView, as type: T.Type) -> [T] {
        var found: [T] = []
        for sub in root.subviews {
            if let match = sub as? T { found.append(match) }
            found += descendants(of: sub, as: type)
        }
        return found
    }

    private func spin() async {
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func test_AC_228_hostedFieldsUseSignedKeyboardAndSaveTypedText() async throws {
        let mock = MockImmichClient()
        mock.updateAssetResponse = makeDTO(latitude: 48.8584, longitude: 2.2945)
        let vm = makeVM(located: true, mock: mock)
        let (controller, window) = host(AdjustLocationSheet(vm: vm, onDone: { _ in }))
        defer { window.isHidden = true }

        let root = controller.view!
        let fields = descendants(of: root, as: UITextField.self).sorted {
            let a = $0.convert($0.bounds, to: window)
            let b = $1.convert($1.bounds, to: window)
            return a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX
        }
        XCTAssertEqual(fields.count, 2)
        guard fields.count == 2 else { return }
        for field in fields {
            XCTAssertEqual(field.keyboardType, .numbersAndPunctuation)
        }

        func type(_ text: String, into field: UITextField) async {
            XCTAssertTrue(field.becomeFirstResponder())
            for _ in 0..<(field.text?.count ?? 0) { field.deleteBackward() }
            field.insertText(text)
            await spin()
        }
        await type("48,8584", into: fields[0])
        await type("2.2945", into: fields[1])
        XCTAssertEqual(vm.latitudeText, "48,8584")
        XCTAssertEqual(vm.longitudeText, "2.2945")
        XCTAssertEqual(vm.pin, PhotoCoordinate(latitude: 48.8584, longitude: 2.2945))

        let saved = await vm.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(mock.lastUpdateAssetBody?.latitude, 48.8584)
        XCTAssertEqual(mock.lastUpdateAssetBody?.longitude, 2.2945)
    }

    func test_AC_228_miniMapFollowsSavedCoordinates() throws {
        let (controller, window) = host(MiniMapView(latitude: 45.5, longitude: 6.8).frame(width: 300, height: 180))
        defer { window.isHidden = true }
        controller.rootView = MiniMapView(latitude: -33.8688, longitude: 151.2093).frame(width: 300, height: 180)
        controller.view.layoutIfNeeded()

        let map = try XCTUnwrap(descendants(of: controller.view, as: MKMapView.self).first)
        let pins = map.annotations.filter { !($0 is MKUserLocation) }
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins.first?.coordinate.latitude ?? 0, -33.8688, accuracy: 1e-9)
        XCTAssertEqual(pins.first?.coordinate.longitude ?? 0, 151.2093, accuracy: 1e-9)
        XCTAssertEqual(map.centerCoordinate.latitude, -33.8688, accuracy: 1e-4)
        XCTAssertEqual(map.centerCoordinate.longitude, 151.2093, accuracy: 1e-4)
    }
}
