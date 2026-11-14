import XCTest
@testable import ImmichSwiftUI

final class AssetDetailViewModelTests: XCTestCase {

    // AC-010: toggleFavorite writes {isFavorite: true} through `updateAsset`.
    @MainActor
    func test_AC_010_toggleFavoriteSendsIsFavorite() async {
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
    func test_setLocation_sendsCoords() async {
        let mock = MockImmichClient()
        let vm = AssetDetailViewModel(asset: makeAssetWithLocation(), client: mock)
        await vm.setLocation(latitude: 45.5, longitude: 6.8)

        XCTAssertEqual(mock.lastUpdateAssetId, "asset-1")
        XCTAssertEqual(mock.lastUpdateAssetBody?.latitude, 45.5)
        XCTAssertEqual(mock.lastUpdateAssetBody?.longitude, 6.8)
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
        XCTAssertEqual(vm.detail?.exifInfo?.rating, 3, "the write response is the new local truth")
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
            await vm.loadDetail()
            let loadMessage = vm.loadError ?? ""
            XCTAssertFalse(loadMessage.isEmpty, "\(failure) must surface a load message")
            for leak in ["Decoding failed", "Network error", "HTTP", "secret-body", "SQL error"] {
                XCTAssertFalse(loadMessage.contains(leak), "\(failure) leaked \"\(leak)\" into the load error: \(loadMessage)")
            }
            XCTAssertFalse(message.isEmpty, "\(failure) must surface a message")
            for leak in ["Decoding failed", "Network error", "HTTP", "secret-body", "SQL error"] {
                XCTAssertFalse(message.contains(leak), "\(failure) leaked \"\(leak)\" into: \(message)")
            }
        }
    }

    // MARK: - Retry of the details (L-29, B-33.2)

    @MainActor
    func test_AC_57_5_failedLoadThenRetryShowsDetailsAndNoError() async {
        let item = makeItem()
        let mock = MockImmichClient()
        mock.getAssetResponse[item.id] = makeDetail()
        mock.globalError = APIError.serverError(500, "boom")
        let vm = AssetDetailViewModel(asset: item, client: mock)

        await vm.loadDetail()
        XCTAssertNotNil(vm.loadError)
        XCTAssertNil(vm.detail)
        XCTAssertNil(vm.errorMessage, "the load error never reaches the write-error slot")

        mock.globalError = nil
        await vm.loadDetail()
        XCTAssertNotNil(vm.detail)
        XCTAssertNil(vm.loadError)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_AC_57_5_retryAfterFailedLoadGeocodes() async {
        let item = makeItem()
        let mock = MockImmichClient()
        mock.getAssetResponse[item.id] = AssetResponseDto(
            id: item.id, type: "IMAGE", thumbhash: nil, localDateTime: "2020-06-14T10:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2020-06-14T10:00:00.000Z",
            ownerId: "me", originalPath: "/a1.jpg", originalFileName: "a1.jpg",
            fileCreatedAt: "2020-06-14T10:00:00.000Z", fileModifiedAt: "2020-06-14T10:00:00.000Z",
            updatedAt: "2020-06-14T10:00:00.000Z", isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false,
            exifInfo: ExifResponseDto(latitude: 48.85, longitude: 2.35)
        )
        let geocoder = MockLocationGeocoding()
        geocoder.placeNameResult = "Paris"
        let vm = AssetDetailViewModel(asset: item, client: mock)
        vm.geocoder = geocoder

        mock.globalError = APIError.serverError(500, "boom")
        await vm.loadDetail()
        XCTAssertEqual(geocoder.callCount, 0)

        mock.globalError = nil
        await vm.loadDetail()
        XCTAssertEqual(geocoder.callCount, 1)
        XCTAssertEqual(vm.placeName, "Paris")

        await vm.loadDetail()
        XCTAssertEqual(geocoder.callCount, 1, "a later reload does not geocode again")
    }

    @MainActor
    func test_AC_57_5_reloadFailureKeepsDetails() async {
        let item = makeItem()
        let mock = MockImmichClient()
        let vm = await loadedVM(item: item, detail: makeDetail(), mock: mock)
        XCTAssertNotNil(vm.detail)

        mock.globalError = APIError.serverError(500, "boom")
        await vm.loadDetail()

        XCTAssertNotNil(vm.detail, "details already on screen stay (decision #7)")
        XCTAssertNotNil(vm.loadError)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_AC_57_5_writeFailureDoesNotSetLoadError() async {
        let item = makeItem()
        let mock = MockImmichClient()
        let vm = await loadedVM(item: item, detail: makeDetail(), mock: mock)

        mock.globalError = APIError.serverError(500, "boom")
        await vm.setLocation(latitude: 45.5, longitude: 6.8)

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.loadError)
    }

    // MARK: - Age and owner (L-24, B-28)

    private let utc = TimeZone(identifier: "UTC")!

    private func makeItem(
        id: String = "a1", ownerId: String = "me", fileCreatedAt: String = "2020-06-14T10:00:00.000Z"
    ) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: ownerId, ratio: 1.0,
            isFavorite: false, visibility: "timeline", isTrashed: false,
            isImage: true, thumbhash: nil, createdAt: fileCreatedAt,
            fileCreatedAt: fileCreatedAt, localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func makeOwner(id: String = "p1", name: String = "Alice Partner") -> UserResponseDto {
        UserResponseDto(
            id: id, name: name, email: "\(id)@example.org", profileImagePath: "",
            avatarColor: "primary", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    private func makeDetail(
        id: String = "a1", ownerId: String = "me", owner: UserResponseDto? = nil,
        dateTimeOriginal: String? = "2020-06-14T10:00:00.000Z", fileCreatedAt: String = "2020-06-14T10:00:00.000Z"
    ) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: fileCreatedAt,
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: fileCreatedAt,
            ownerId: ownerId, originalPath: "/\(id).jpg", originalFileName: "\(id).jpg",
            fileCreatedAt: fileCreatedAt, fileModifiedAt: fileCreatedAt,
            updatedAt: fileCreatedAt, isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false,
            owner: owner, exifInfo: ExifResponseDto(dateTimeOriginal: dateTimeOriginal)
        )
    }

    private func makeFace(id: String = "f1", personId: String = "n1", birthDate: String?) -> AssetFaceResponseDto {
        AssetFaceResponseDto(
            id: id,
            person: PersonResponseDto(id: personId, name: "Nina", birthDate: birthDate, isHidden: false),
            boundingBoxX1: 0, boundingBoxX2: 10, boundingBoxY1: 0, boundingBoxY2: 10,
            imageHeight: 100, imageWidth: 100
        )
    }

    @MainActor
    private func loadedVM(
        item: AssetReactItem, detail: AssetResponseDto, faces: [AssetFaceResponseDto] = [], mock: MockImmichClient = MockImmichClient()
    ) async -> AssetDetailViewModel {
        mock.getAssetResponse[item.id] = detail
        mock.facesResponse = faces
        let vm = AssetDetailViewModel(asset: item, client: mock)
        await vm.loadDetail()
        return vm
    }

    @MainActor
    func test_AC_45_ageUnderNameAndNoneWithoutBirthday() async {
        let nina = makeFace(id: "f1", birthDate: "2000-06-15")
        let omar = makeFace(id: "f2", personId: "o1", birthDate: nil)
        let vm = await loadedVM(item: makeItem(), detail: makeDetail(), faces: [nina, omar])

        XCTAssertEqual(vm.age(for: nina, timeZone: utc), .years(19))
        XCTAssertNil(vm.age(for: omar, timeZone: utc), "no birthday, no age")
        XCTAssertNil(vm.age(for: makeFace(birthDate: "not-a-date"), timeZone: utc))
        let noPerson = AssetFaceResponseDto(
            id: "f3", person: nil, boundingBoxX1: 0, boundingBoxX2: 1, boundingBoxY1: 0, boundingBoxY2: 1,
            imageHeight: 1, imageWidth: 1
        )
        XCTAssertNil(vm.age(for: noPerson, timeZone: utc))
    }

    @MainActor
    func test_AC_220_birthdayCountsAndPhotoBeforeBirthHasNoAge() async {
        let face = makeFace(birthDate: "2000-06-15")
        let birthday = await loadedVM(
            item: makeItem(fileCreatedAt: "2020-06-15T10:00:00.000Z"),
            detail: makeDetail(dateTimeOriginal: "2020-06-15T10:00:00.000Z", fileCreatedAt: "2020-06-15T10:00:00.000Z"),
            faces: [face]
        )
        XCTAssertEqual(birthday.age(for: face, timeZone: utc), .years(20), "the birthday itself counts")

        let before = await loadedVM(
            item: makeItem(fileCreatedAt: "1999-12-01T10:00:00.000Z"),
            detail: makeDetail(dateTimeOriginal: "1999-12-01T10:00:00.000Z", fileCreatedAt: "1999-12-01T10:00:00.000Z"),
            faces: [face]
        )
        XCTAssertNil(before.age(for: face, timeZone: utc), "a photo before the birth shows no age")
    }

    @MainActor
    func test_AC_221_babyAgesAcrossPhotos() async throws {
        let (bundle, locale) = try language("fr")
        let face = makeFace(birthDate: "2024-01-10")
        let cases: [(day: String, label: String)] = [
            ("2024-02-12", "1 mois"), ("2024-04-20", "3 mois"), ("2025-01-10", "1 an"),
            ("2025-03-20", "1 an et 2 mois"), ("2026-02-01", "2 ans"),
        ]
        for (day, expected) in cases {
            let stamp = "\(day)T10:00:00.000Z"
            let vm = await loadedVM(
                item: makeItem(fileCreatedAt: stamp),
                detail: makeDetail(dateTimeOriginal: stamp, fileCreatedAt: stamp),
                faces: [face]
            )
            XCTAssertEqual(vm.age(for: face, timeZone: utc)?.label(bundle: bundle, locale: locale), expected, day)
        }
    }

    func test_AC_222_referenceDayFollowsHeaderInEachTimeZone() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let exif = "2020-06-14T22:00:00.000Z"
        let file = "2020-06-14T22:00:00.000Z"

        XCTAssertEqual(
            AssetDetailViewModel.referenceDay(dateTimeOriginal: exif, fileCreatedAt: file, timeZone: newYork),
            CalendarDay(year: 2020, month: 6, day: 14))
        XCTAssertEqual(
            AssetDetailViewModel.referenceDay(dateTimeOriginal: exif, fileCreatedAt: file, timeZone: tokyo),
            CalendarDay(year: 2020, month: 6, day: 15))
        // No EXIF date: the file's UTC day, in both zones.
        for zone in [newYork, tokyo] {
            XCTAssertEqual(
                AssetDetailViewModel.referenceDay(dateTimeOriginal: nil, fileCreatedAt: file, timeZone: zone),
                CalendarDay(year: 2020, month: 6, day: 14), zone.identifier)
        }
        // Unreadable EXIF date falls back to the file's day; no millisecond form reads too.
        XCTAssertEqual(
            AssetDetailViewModel.referenceDay(dateTimeOriginal: "garbage", fileCreatedAt: file, timeZone: tokyo),
            CalendarDay(year: 2020, month: 6, day: 14))
        XCTAssertEqual(
            AssetDetailViewModel.referenceDay(dateTimeOriginal: "2020-06-14T22:00:00Z", fileCreatedAt: "", timeZone: tokyo),
            CalendarDay(year: 2020, month: 6, day: 15))
        XCTAssertNil(AssetDetailViewModel.referenceDay(dateTimeOriginal: nil, fileCreatedAt: "", timeZone: tokyo))
    }

    @MainActor
    func test_AC_222_ageOnTheSamePhotoDiffersByTimeZone() async throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let face = makeFace(birthDate: "2000-06-15")
        let stamp = "2020-06-14T22:00:00.000Z"
        let vm = await loadedVM(
            item: makeItem(fileCreatedAt: stamp), detail: makeDetail(dateTimeOriginal: stamp, fileCreatedAt: stamp), faces: [face]
        )
        XCTAssertEqual(vm.age(for: face, timeZone: newYork), .years(19))
        XCTAssertEqual(vm.age(for: face, timeZone: tokyo), .years(20))

        let noExif = await loadedVM(
            item: makeItem(fileCreatedAt: stamp), detail: makeDetail(dateTimeOriginal: nil, fileCreatedAt: stamp), faces: [face]
        )
        XCTAssertEqual(noExif.age(for: face, timeZone: newYork), .years(19))
        XCTAssertEqual(noExif.age(for: face, timeZone: tokyo), .years(19))
    }

    @MainActor
    func test_AC_223_reassignedFaceShowsNewPersonAge() async {
        let mock = MockImmichClient()
        let before = makeFace(id: "f1", personId: "x1", birthDate: nil)
        let vm = await loadedVM(item: makeItem(), detail: makeDetail(), faces: [before], mock: mock)
        XCTAssertNil(vm.age(for: vm.faces[0], timeZone: utc))

        mock.facesResponse = [makeFace(id: "f1", personId: "n1", birthDate: "2000-06-15")]
        await vm.reassignFace(faceId: "f1", toPersonId: "n1")

        XCTAssertEqual(vm.faces.first?.person?.id, "n1")
        XCTAssertEqual(vm.age(for: vm.faces[0], timeZone: utc), .years(19))
    }

    @MainActor
    func test_AC_223_changingTheDateMovesTheAge() async {
        let face = makeFace(birthDate: "2000-06-15")
        let vm = await loadedVM(item: makeItem(), detail: makeDetail(), faces: [face])
        XCTAssertEqual(vm.age(for: face, timeZone: utc), .years(19))
        vm.detail?.exifInfo?.dateTimeOriginal = "2020-06-15T10:00:00.000Z"
        XCTAssertEqual(vm.age(for: face, timeZone: utc), .years(20))
    }

    @MainActor
    func test_AC_46_partnerPhotoHasOwnerOwnPhotoHasNone() async {
        let partner = makeOwner()
        let theirs = await loadedVM(
            item: makeItem(ownerId: "p1"), detail: makeDetail(ownerId: "p1", owner: partner))
        XCTAssertEqual(theirs.sharedByOwner(currentUserId: "me"), partner)

        let mine = await loadedVM(
            item: makeItem(ownerId: "me"), detail: makeDetail(ownerId: "me", owner: makeOwner(id: "me", name: "Me")))
        XCTAssertNil(mine.sharedByOwner(currentUserId: "me"))
    }

    @MainActor
    func test_AC_224_albumMemberPhotoHasOwner() async {
        let member = makeOwner(id: "m1", name: "Carla Member")
        let theirs = await loadedVM(
            item: makeItem(id: "alb-1", ownerId: "m1"), detail: makeDetail(id: "alb-1", ownerId: "m1", owner: member))
        XCTAssertEqual(theirs.sharedByOwner(currentUserId: "me")?.name, "Carla Member")

        let mine = await loadedVM(
            item: makeItem(id: "alb-2", ownerId: "me"),
            detail: makeDetail(id: "alb-2", ownerId: "me", owner: makeOwner(id: "me", name: "Me")))
        XCTAssertNil(mine.sharedByOwner(currentUserId: "me"))
    }

    @MainActor
    func test_AC_224_ownerRowCostsNoExtraRequest() async {
        let ownMock = MockImmichClient()
        _ = await loadedVM(item: makeItem(ownerId: "me"), detail: makeDetail(ownerId: "me"), mock: ownMock)
        let partnerMock = MockImmichClient()
        let partnerVM = await loadedVM(
            item: makeItem(ownerId: "p1"), detail: makeDetail(ownerId: "p1", owner: makeOwner()), mock: partnerMock)
        let before = partnerMock.requestCount
        _ = partnerVM.sharedByOwner(currentUserId: "me")

        XCTAssertEqual(partnerMock.requestCount, before, "reading the owner must not call the client")
        XCTAssertEqual(partnerMock.requestCount, ownMock.requestCount, "same calls as an own photo")
        XCTAssertNil(partnerVM.errorMessage)
    }

    @MainActor
    func test_AC_226_mapItemWithoutOwnerIdUsesDetailOwner() async {
        // Own copy, no owner id on the item: the detail names the user → no row.
        let own = await loadedVM(
            item: makeItem(ownerId: ""), detail: makeDetail(ownerId: "me", owner: makeOwner(id: "me", name: "Me")))
        XCTAssertNil(own.sharedByOwner(currentUserId: "me"))

        // Partner photo opened from the map: the detail names another account.
        let partner = makeOwner()
        let theirs = await loadedVM(item: makeItem(ownerId: ""), detail: makeDetail(ownerId: "p1", owner: partner))
        XCTAssertEqual(theirs.sharedByOwner(currentUserId: "me"), partner)

        // Item without owner id and no detail at all (offline copy, no network).
        let offline = AssetDetailViewModel(asset: makeItem(ownerId: ""), client: MockImmichClient())
        XCTAssertNil(offline.sharedByOwner(currentUserId: "me"))
    }

    @MainActor
    func test_AC_226_noRowWithoutOwnerOrWithBadInputs() async {
        let partner = makeOwner()
        // Response without `owner`.
        let noOwner = await loadedVM(item: makeItem(ownerId: "p1"), detail: makeDetail(ownerId: "p1", owner: nil))
        XCTAssertNil(noOwner.sharedByOwner(currentUserId: "me"))
        XCTAssertNil(noOwner.errorMessage)
        XCTAssertNotNil(noOwner.detail?.exifInfo, "the rest of the details still loads")

        // getAsset fails: no detail, no row.
        let failing = MockImmichClient()
        failing.getAssetGate = { _ in throw APIError.http(500) }
        let failed = AssetDetailViewModel(asset: makeItem(ownerId: "p1"), client: failing)
        await failed.loadDetail()
        XCTAssertNil(failed.detail)
        XCTAssertNil(failed.sharedByOwner(currentUserId: "me"))

        // Unknown signed-in user, blank name, owner that is not the expected one.
        let ok = await loadedVM(item: makeItem(ownerId: "p1"), detail: makeDetail(ownerId: "p1", owner: partner))
        XCTAssertNil(ok.sharedByOwner(currentUserId: nil))
        XCTAssertNil(ok.sharedByOwner(currentUserId: ""))
        let blank = await loadedVM(
            item: makeItem(ownerId: "p1"),
            detail: makeDetail(ownerId: "p1", owner: makeOwner(name: " \n ")))
        XCTAssertNil(blank.sharedByOwner(currentUserId: "me"))
        let mismatch = await loadedVM(
            item: makeItem(ownerId: "p1"), detail: makeDetail(ownerId: "p1", owner: makeOwner(id: "other")))
        XCTAssertNil(mismatch.sharedByOwner(currentUserId: "me"))
    }
}
