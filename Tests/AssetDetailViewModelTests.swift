import XCTest
@testable import ImmichSwiftUI

final class AssetDetailViewModelTests: XCTestCase {

    // AC-010: toggleFavorite issues PATCH /api/assets/:id {isFavorite: true}.
    @MainActor
    func test_AC_010_toggleFavoriteUsesPATCH() async {
        let mock = MockImmichClient()
        let asset = AssetReactItem(
            id: "asset-1", ownerId: "owner", ratio: 1.0,
            isFavorite: false, visibility: "timeline", isTrashed: false,
            isImage: true, thumbhash: nil, createdAt: "2024-07-01T00:00:00.000Z",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
        let vm = AssetDetailViewModel(asset: asset, client: mock)
        await vm.toggleFavorite()

        XCTAssertEqual(mock.lastUpdateAssetId, "asset-1")
        XCTAssertEqual(mock.lastUpdateAssetBody?.isFavorite, true)
        XCTAssertEqual(mock.lastUpdateMethod, .PATCH)
        XCTAssertTrue(vm.isFavorite)
    }

    // MARK: - Adjust location (map-extras, AC-1023/1025)

    @MainActor
    private func makeAssetWithLocation() -> AssetReactItem {
        AssetReactItem(
            id: "asset-1", ownerId: "owner", ratio: 1.0,
            isFavorite: false, visibility: "timeline", isTrashed: false,
            isImage: true, thumbhash: nil, createdAt: "2024-07-01T00:00:00.000Z",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: 45.0, longitude: 6.0, stack: []
        )
    }

    @MainActor
    func test_setLocation_sendsPATCHWithCoords() async {
        let mock = MockImmichClient()
        let vm = AssetDetailViewModel(asset: makeAssetWithLocation(), client: mock)
        await vm.setLocation(latitude: 45.5, longitude: 6.8)

        XCTAssertEqual(mock.lastUpdateAssetId, "asset-1")
        XCTAssertEqual(mock.lastUpdateAssetBody?.latitude, 45.5)
        XCTAssertEqual(mock.lastUpdateAssetBody?.longitude, 6.8)
        XCTAssertEqual(mock.lastUpdateMethod, .PATCH)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_setLocation_rejectsOutOfBounds() async {
        let mock = MockImmichClient()
        let vm = AssetDetailViewModel(asset: makeAssetWithLocation(), client: mock)
        await vm.setLocation(latitude: 95, longitude: 200)

        XCTAssertNil(mock.lastUpdateAssetBody)
        XCTAssertEqual(vm.errorMessage, localizedString("Invalid coordinates."))
    }

    @MainActor
    func test_setLocation_regeocodesAfterUpdate() async {
        let mock = MockImmichClient()
        mock.updateAssetResponse = AssetResponseDto(
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
                focalLength: nil, iso: nil, exposureTime: nil, latitude: 48.85,
                longitude: 2.35, city: nil, state: nil, country: nil,
                description: nil, projectionType: nil, rating: nil
            )
        )
        let geocoder = MockLocationGeocoding()
        geocoder.placeNameResult = "Paris"
        let vm = AssetDetailViewModel(asset: makeAssetWithLocation(), client: mock)
        vm.geocoder = geocoder

        await vm.setLocation(latitude: 48.85, longitude: 2.35)

        XCTAssertEqual(vm.detail?.exifInfo?.latitude, 48.85)
        XCTAssertEqual(vm.placeName, "Paris")
        XCTAssertEqual(geocoder.callCount, 1)
    }

    @MainActor
    func test_setLocation_failureShowsError() async {
        let mock = MockImmichClient()
        mock.globalError = APIError.serverError(500, "boom")
        let vm = AssetDetailViewModel(asset: makeAssetWithLocation(), client: mock)
        await vm.setLocation(latitude: 45.5, longitude: 6.8)

        XCTAssertEqual(vm.errorMessage, UserFacingError.serverErrorMessage)
        XCTAssertNil(vm.detail)
    }

    // MARK: - Star ratings (star-ratings, AC-5062/AC-5063)

    @MainActor
    private func makeRatingAsset() -> AssetReactItem {
        AssetReactItem(
            id: "asset-1", ownerId: "owner", ratio: 1.0,
            isFavorite: false, visibility: "timeline", isTrashed: false,
            isImage: true, thumbhash: nil, createdAt: "2024-07-01T00:00:00.000Z",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    @MainActor
    func test_setRating_sendsValueAndAdoptsServerResponse() async {
        let mock = MockImmichClient()
        let vm = AssetDetailViewModel(asset: makeRatingAsset(), client: mock)

        await vm.setRating(3)

        XCTAssertEqual(mock.ratingUpdates.map(\.rating), [3])
        XCTAssertEqual(mock.ratingUpdates.first?.id, "asset-1")
        XCTAssertEqual(vm.rating, 3)
        XCTAssertEqual(vm.detail?.exifInfo?.rating, 3, "the PATCH response is the new local truth")
        XCTAssertEqual(vm.lastRatingSent, 3)
        XCTAssertEqual(vm.lastRatingAssetId, "asset-1")
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_setRating_nilSendsUnratedAndClearsLocally() async {
        let mock = MockImmichClient()
        let vm = AssetDetailViewModel(asset: makeRatingAsset(), client: mock)

        await vm.setRating(3)
        await vm.setRating(nil)

        XCTAssertEqual(mock.ratingUpdates.map(\.rating), [3, nil])
        XCTAssertNil(vm.rating)
        XCTAssertNil(vm.detail?.exifInfo?.rating)
    }

    @MainActor
    func test_setRating_revertsOnFailure() async {
        let mock = MockImmichClient()
        let vm = AssetDetailViewModel(asset: makeRatingAsset(), client: mock)

        await vm.setRating(3) // succeeds: the server now holds 3
        mock.ratingUpdateResults = [.failure(APIError.serverError(500, "boom"))]
        await vm.setRating(1) // fails: the bar must not keep the unconfirmed 1

        XCTAssertEqual(mock.ratingUpdates.map(\.rating), [3, 1])
        XCTAssertEqual(vm.rating, 3)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isSavingRating)
    }

    // AC-3: whatever the transport or the server failed with, the screen shows
    // only catalog copy: no decoding detail, transport text, HTTP code or body.
    @MainActor
    func test_AC3_technicalFailuresNeverReachTheScreen() async {
        let technical: [Error] = [
            APIError.decoding("Decoding failed: keyNotFound(isFavorite) <html>secret-body</html>"),
            APIError.serverError(500, "secret-body SQL error"),
            APIError.http(404),
        ]
        for failure in technical {
            let mock = MockImmichClient()
            mock.globalError = failure
            let vm = AssetDetailViewModel(asset: makeAssetWithLocation(), client: mock)
            await vm.setLocation(latitude: 45.5, longitude: 6.8)

            let message = vm.errorMessage ?? ""
            XCTAssertFalse(message.isEmpty, "\(failure) must surface a message")
            for leak in ["Decoding failed", "Network error", "HTTP", "secret-body", "SQL error"] {
                XCTAssertFalse(message.contains(leak), "\(failure) leaked \"\(leak)\" into: \(message)")
            }
        }
    }
}
