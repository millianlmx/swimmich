import XCTest
@testable import ImmichSwiftUI

@MainActor
final class PhotoShareViewModelTests: XCTestCase {

    private let baseURL = URL(string: "https://example.com")!

    private func makeAsset(id: String = "a1", ownerId: String = "owner") -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: ownerId, ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func makeUser(id: String, name: String) -> UserResponseDto {
        UserResponseDto(
            id: id, name: name, email: "\(id)@example.com", profileImagePath: "",
            avatarColor: "#4250AF", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    private func makeAlbum(id: String, name: String, shared: Bool) -> AlbumResponseDto {
        AlbumResponseDto(
            id: id, albumName: name, description: "", createdAt: "2024-01-01T00:00:00.000Z",
            updatedAt: "2024-01-01T00:00:00.000Z", albumThumbnailAssetId: nil, shared: shared,
            hasSharedLink: false, assetCount: 3, isActivityEnabled: false, order: nil
        )
    }

    // MARK: - Load

    func test_load_filtersSelfAndExposesSharedAlbums() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [makeUser(id: "owner", name: "Me"), makeUser(id: "u1", name: "Alice")]
        mock.albumsResponse = [
            makeAlbum(id: "al-shared", name: "Trip", shared: true),
            makeAlbum(id: "al-private", name: "Private", shared: false)
        ]

        let vm = PhotoShareViewModel(asset: makeAsset(ownerId: "owner"), client: mock, baseURL: baseURL)
        await vm.load()

        XCTAssertEqual(vm.users.map(\.id), ["u1"], "self must be excluded from the picker")
        XCTAssertEqual(vm.sharedAlbums.map(\.id), ["al-shared"], "only shared albums are candidates")
    }

    func test_load_usersErrorDoesNotBreakAlbums() async {
        struct Boom: Error {}
        let mock = MockImmichClient()
        mock.getUsersError = Boom()
        mock.albumsResponse = [makeAlbum(id: "al", name: "Trip", shared: true)]

        let vm = PhotoShareViewModel(asset: makeAsset(), client: mock, baseURL: baseURL)
        await vm.load()

        XCTAssertTrue(vm.users.isEmpty, "user list failed but albums still load")
        XCTAssertEqual(vm.albums.count, 1)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - User selection

    func test_toggleUser() {
        let vm = PhotoShareViewModel(asset: makeAsset(), client: MockImmichClient(), baseURL: baseURL)
        vm.toggleUser("u1")
        XCTAssertTrue(vm.selectedUserIds.contains("u1"))
        vm.toggleUser("u1")
        XCTAssertFalse(vm.selectedUserIds.contains("u1"))
    }

    // MARK: - Create shared album

    func test_createSharedAlbum_dispatchesAlbumWithUsersAndAsset() async {
        let mock = MockImmichClient()
        let vm = PhotoShareViewModel(asset: makeAsset(), client: mock, baseURL: baseURL)
        vm.albumName = "Weekend"
        vm.selectedUserIds = ["u1", "u2"]

        await vm.createSharedAlbum()

        let dto = vm.lastCreateAlbumDto
        XCTAssertNotNil(dto)
        XCTAssertEqual(dto?.albumName, "Weekend")
        XCTAssertEqual(dto?.assetIds, ["a1"])
        XCTAssertEqual(Set(dto?.albumUsers?.map(\.userId) ?? []), ["u1", "u2"])
        XCTAssertEqual(dto?.albumUsers?.first?.role, .editor)
        XCTAssertNotNil(vm.lastCreatedAlbumId)
        XCTAssertTrue(vm.albumName.isEmpty, "form resets on success")
        XCTAssertTrue(vm.selectedUserIds.isEmpty, "selection resets on success")
    }

    func test_createSharedAlbum_requiresNameAndUsers() async {
        let mock = MockImmichClient()
        let vm = PhotoShareViewModel(asset: makeAsset(), client: mock, baseURL: baseURL)

        await vm.createSharedAlbum()
        XCTAssertNil(vm.lastCreateAlbumDto, "no dispatch without name + users")
        XCTAssertNil(vm.lastCreatedAlbumId)
    }

    func test_createSharedAlbum_errorPreservesState() async {
        struct Boom: Error {}
        let mock = MockImmichClient()
        mock.createAlbumError = Boom()
        let vm = PhotoShareViewModel(asset: makeAsset(), client: mock, baseURL: baseURL)
        vm.albumName = "Weekend"
        vm.selectedUserIds = ["u1"]

        await vm.createSharedAlbum()

        XCTAssertNil(vm.lastCreatedAlbumId)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.albumName, "Weekend", "keep inputs so the user can retry")
        XCTAssertEqual(vm.selectedUserIds, ["u1"])
    }

    // MARK: - Add to existing shared album

    func test_addToAlbum_dispatchesBulkAdd() async {
        let mock = MockImmichClient()
        let vm = PhotoShareViewModel(asset: makeAsset(), client: mock, baseURL: baseURL)

        await vm.addToAlbum(id: "al-shared")

        XCTAssertEqual(vm.lastAddAlbumId, "al-shared")
        XCTAssertEqual(mock.lastAddAssetsAlbumId, "al-shared")
        XCTAssertEqual(mock.lastAddAssetsIds, ["a1"])
        XCTAssertEqual(vm.lastAddedAlbumId, "al-shared")
    }

    func test_addToAlbum_errorClearsSuccess() async {
        struct Boom: Error {}
        let mock = MockImmichClient()
        mock.addAssetsError = Boom()
        let vm = PhotoShareViewModel(asset: makeAsset(), client: mock, baseURL: baseURL)

        await vm.addToAlbum(id: "al-shared")

        XCTAssertNil(vm.lastAddedAlbumId)
        XCTAssertNotNil(vm.errorMessage)
    }

    func test_AC_6_addToAlbum_duplicate_realClient_setsLastAdded() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let client = ImmichAPIClient(session: URLSession(configuration: config))
        client.configure(baseURL: baseURL, token: "tok")
        CapturingURLProtocol.nextData = Data(#"[{"id":"a1","success":false,"error":"duplicate"}]"#.utf8)
        defer { CapturingURLProtocol.reset() }
        let vm = PhotoShareViewModel(asset: makeAsset(), client: client, baseURL: baseURL)

        await vm.addToAlbum(id: "al-shared")

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.lastAddedAlbumId, "al-shared")
    }

    // MARK: - Public link

    func test_createPublicLink_buildsShareURLWithToggles() async {
        let mock = MockImmichClient()
        let vm = PhotoShareViewModel(asset: makeAsset(), client: mock, baseURL: baseURL)
        vm.allowDownload = false
        vm.showMetadata = true

        await vm.createPublicLink()

        let dto = vm.lastCreateLinkDto
        XCTAssertEqual(dto?.type, .individual)
        XCTAssertEqual(dto?.assetIds, ["a1"])
        XCTAssertEqual(dto?.allowDownload, false)
        XCTAssertEqual(dto?.showMetadata, true)
        XCTAssertEqual(vm.linkURL, "https://example.com/share/a2V5")
    }

    func test_createPublicLink_error() async {
        struct Boom: Error {}
        let mock = MockImmichClient()
        mock.createSharedLinkError = Boom()
        let vm = PhotoShareViewModel(asset: makeAsset(), client: mock, baseURL: baseURL)

        await vm.createPublicLink()

        XCTAssertNil(vm.linkURL)
        XCTAssertNotNil(vm.errorMessage)
    }
}
