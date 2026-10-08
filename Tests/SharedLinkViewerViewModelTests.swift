import XCTest
@testable import ImmichSwiftUI

/// Behaviour of the public shared-link viewer (issue #22): what a visitor can
/// open, what each server verdict turns into, and what a guest upload does.
@MainActor
final class SharedLinkViewerViewModelTests: XCTestCase {

    private let key = "a2V5LXNlY3JldC1rZXktdmFsdWUtd2l0aC1sb25nLWJhc2U2NHVybA"
    private let server = URL(string: "https://photos.example.com")!

    private func makeVM(
        client: MockImmichClient = MockImmichClient(),
        externalDomain: String = ""
    ) -> SharedLinkViewerViewModel {
        SharedLinkViewerViewModel(client: client, baseURL: server, externalDomain: externalDomain)
    }

    /// A link the server hands out, with the two shapes that matter: an
    /// INDIVIDUAL link carries its assets inline, an ALBUM link only an album.
    private func link(
        type: SharedLinkType = .individual,
        assets: [AssetResponseDto] = [],
        albumId: String? = nil,
        allowUpload: Bool = true,
        slug: String? = nil,
        description: String? = "Holidays"
    ) -> SharedLinkResponseDto {
        SharedLinkResponseDto(
            id: "link-1",
            description: description,
            password: nil,
            userId: "owner",
            key: key,
            type: type,
            createdAt: "2024-01-01T00:00:00.000Z",
            expiresAt: nil,
            assets: assets,
            album: albumId.map {
                AlbumResponseDto(
                    id: $0, albumName: "Holidays", description: "",
                    createdAt: "2024-01-01T00:00:00.000Z", updatedAt: "2024-01-01T00:00:00.000Z",
                    albumThumbnailAssetId: nil, shared: true, hasSharedLink: true,
                    assetCount: 2, isActivityEnabled: false, order: nil
                )
            },
            allowUpload: allowUpload,
            allowDownload: true,
            showMetadata: true,
            slug: slug
        )
    }

    private func asset(_ id: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-01-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100,
            createdAt: "2024-01-01T00:00:00.000Z", ownerId: "owner", originalPath: "",
            originalFileName: "\(id).jpg", fileCreatedAt: "2024-01-01T00:00:00.000Z",
            fileModifiedAt: "2024-01-01T00:00:00.000Z", updatedAt: "2024-01-01T00:00:00.000Z",
            isFavorite: false, isArchived: false, isTrashed: false, isOffline: false,
            visibility: "timeline", checksum: "", isEdited: false
        )
    }

    private func searchPage(ids: [String], nextPage: String?) -> SearchResponseDto {
        SearchResponseDto(
            assets: SearchAssetResponseDto(count: ids.count, items: ids.map(asset), nextPage: nextPage)
        )
    }

    /// The server's 401 body, verbatim in shape: `APIError.serverError` carries
    /// it, and the message inside is the only discriminator the API offers.
    private func serverError(_ status: Int, message: String) -> APIError {
        .serverError(status, #"{"message":"\#(message)","error":"Unauthorized","statusCode":\#(status)}"#)
    }

    // MARK: - Entry

    func test_openLink_rejectsTextWithNoCredentialInIt() async {
        let client = MockImmichClient()
        let vm = makeVM(client: client)

        vm.linkText = "hello there"
        await vm.openLink()

        XCTAssertEqual(vm.phase, .entry, "a non-link stays on the form")
        XCTAssertNotNil(vm.message)
        XCTAssertTrue(client.sharedLinkMineCredentials.isEmpty, "nothing was sent")
    }

    /// A link that names another server is refused before anything is sent: the
    /// credential is a bearer-equivalent secret, and our server would not have
    /// the link anyway.
    func test_openLink_refusesALinkFromAnotherServer() async {
        let client = MockImmichClient()
        let vm = makeVM(client: client)

        vm.linkText = "https://someone-else.test/share/\(key)"
        await vm.openLink()

        XCTAssertTrue(vm.message?.contains("someone-else.test") == true)
        XCTAssertTrue(client.sharedLinkMineCredentials.isEmpty, "the key must not be sent to another host")
    }

    /// A received link is normally the *public* URL: `/s/<slug>` when the link
    /// has a custom slug, `/share/<key>` otherwise. Both must open, and the
    /// credential that goes out must match the path.
    func test_openLink_readsTheKeyFromAShareURL() async {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link(assets: [asset("a1")])
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/share/\(key)"
        await vm.openLink()

        XCTAssertEqual(vm.phase, .opened)
        XCTAssertEqual(client.sharedLinkMineCredentials, [.key(key)])
    }

    func test_openLink_readsTheSlugFromAnSURL() async {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link(slug: "summer-2024")
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/s/summer-2024"
        await vm.openLink()

        XCTAssertEqual(vm.phase, .opened)
        XCTAssertEqual(client.sharedLinkMineCredentials, [.slug("summer-2024")])
    }

    /// A reverse-proxied server advertises a public domain that differs from the
    /// API host the app dials; a link on that domain is still ours.
    func test_openLink_acceptsTheAdvertisedExternalDomain() async {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link()
        let vm = makeVM(client: client, externalDomain: "https://photos.public.test")

        vm.linkText = "https://photos.public.test/s/holidays"
        await vm.openLink()

        XCTAssertEqual(vm.phase, .opened)
    }

    // MARK: - Password

    func test_load_movesToThePasswordPhaseWhenTheServerAsks() async {
        let client = MockImmichClient()
        client.sharedLinkMineError = serverError(401, message: "Password required")
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()

        XCTAssertEqual(vm.phase, .passwordRequired)
        XCTAssertNil(vm.message, "asking for a password is not an error")
    }

    /// Wrong password: the prompt stays, with the server's refusal inline.
    func test_submitPassword_keepsThePromptOnAWrongPassword() async {
        let client = MockImmichClient()
        client.sharedLinkMineError = serverError(401, message: "Password required")
        client.sharedLinkLoginError = serverError(401, message: "Invalid password")
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()
        vm.password = "nope"
        await vm.submitPassword()

        XCTAssertEqual(vm.phase, .passwordRequired)
        XCTAssertEqual(client.sharedLinkLoginPasswords, ["nope"])
        XCTAssertEqual(vm.message, localizedString("That password is not right."))
    }

    /// A link revoked between the prompt and the typed password answers 401 on
    /// the login too — and that one is not a wrong password.
    func test_submitPassword_reportsADeadLink() async {
        let client = MockImmichClient()
        client.sharedLinkMineError = serverError(401, message: "Password required")
        client.sharedLinkLoginError = serverError(401, message: "Invalid share slug")
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()
        vm.password = "hunter2"
        await vm.submitPassword()

        XCTAssertEqual(vm.phase, .deadLink)
    }

    func test_submitPassword_opensTheLinkOnSuccess() async {
        let client = MockImmichClient()
        client.sharedLinkMineError = serverError(401, message: "Password required")
        client.sharedLinkLoginResponse = link(assets: [asset("a1"), asset("a2")])
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()
        vm.password = "hunter2"
        await vm.submitPassword()

        XCTAssertEqual(vm.phase, .opened)
        XCTAssertEqual(client.sharedLinkLoginCredentials, [.slug("holidays")])
        XCTAssertEqual(vm.assets.map(\.id), ["a1", "a2"], "an INDIVIDUAL link inlines its assets")
        XCTAssertNil(vm.message)
    }

    func test_submitPassword_requiresAPassword() async {
        let client = MockImmichClient()
        client.sharedLinkMineError = serverError(401, message: "Password required")
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()
        vm.password = "  "
        await vm.submitPassword()

        XCTAssertEqual(vm.phase, .passwordRequired)
        XCTAssertTrue(client.sharedLinkLoginPasswords.isEmpty, "an empty password is not sent")
        XCTAssertNotNil(vm.message)
    }

    /// A 401 that is not asking for a password is a dead link — revoked, expired
    /// or never issued by this server (`AuthService.isValidSharedLink` collapses
    /// all three into one message).
    func test_load_reportsADeadLink() async {
        let client = MockImmichClient()
        client.sharedLinkMineError = serverError(401, message: "Invalid share key")
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/share/\(key)"
        await vm.openLink()

        XCTAssertEqual(vm.phase, .deadLink)
    }

    /// Any other failure keeps the visitor on the form with the reason inline,
    /// and a retry re-runs the same request.
    func test_load_surfacesOtherFailuresAndRetries() async {
        let client = MockImmichClient()
        client.sharedLinkMineError = APIError.serverError(500, "boom")
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/share/\(key)"
        await vm.openLink()
        XCTAssertEqual(vm.phase, .failed(UserFacingError.serverErrorMessage))

        client.sharedLinkMineError = nil
        client.sharedLinkMineResponse = link(assets: [asset("a1")])
        await vm.load()

        XCTAssertEqual(vm.phase, .opened)
    }

    /// AC-3: a technical failure never reaches the visitor. The inline reason is
    /// the localized copy for its family, with no transport or response-body text.
    func test_AC3_technicalFailureShowsLocalizedCopyWithoutRawText() async {
        let client = MockImmichClient()
        client.sharedLinkMineError = APIError.serverError(500, "boom: stack trace")
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/share/\(key)"
        await vm.openLink()

        guard case .failed(let text) = vm.phase else {
            return XCTFail("expected .failed, got \(vm.phase)")
        }
        XCTAssertEqual(text, localizedString("The server ran into a problem. Please try again."))
        XCTAssertFalse(text.contains("boom"))
        XCTAssertFalse(text.contains("500"))
    }

    // MARK: - Album links

    /// An album link lists through `POST /search/metadata` — `AlbumResponseDto`
    /// has no `assets`, and the server rejects an unfiltered search under
    /// shared-link auth.
    func test_albumLink_listsThroughTheAlbumSearchAndPaginates() async {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link(type: .album, albumId: "alb-1")
        client.sharedLinkAlbumAssetsResponse = searchPage(ids: ["a1", "a2"], nextPage: "2")
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()

        XCTAssertEqual(client.sharedLinkAlbumIds, ["alb-1"])
        XCTAssertEqual(client.sharedLinkAlbumPages, [1])
        XCTAssertEqual(vm.assets.map(\.id), ["a1", "a2"])
        XCTAssertTrue(vm.hasMore)
        XCTAssertEqual(vm.title, "Holidays", "an album link is titled by its album")

        // Second page, and a server that repeats an id must not duplicate a cell.
        client.sharedLinkAlbumAssetsResponse = searchPage(ids: ["a2", "a3"], nextPage: nil)
        await vm.loadMoreAlbumAssets()

        XCTAssertEqual(vm.assets.map(\.id), ["a1", "a2", "a3"])
        XCTAssertFalse(vm.hasMore)
        XCTAssertEqual(client.sharedLinkAlbumPages, [1, 2])
    }

    func test_albumLink_emptyAlbumKeepsTheGridEmpty() async {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link(type: .album, albumId: "alb-1")
        client.sharedLinkAlbumAssetsResponse = searchPage(ids: [], nextPage: nil)
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()

        XCTAssertEqual(vm.phase, .opened)
        XCTAssertTrue(vm.assets.isEmpty)
        XCTAssertFalse(vm.hasMore)
    }

    /// A failing page never blanks what already rendered.
    func test_albumLink_pageFailureKeepsLoadedAssets() async {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link(type: .album, albumId: "alb-1")
        client.sharedLinkAlbumAssetsResponse = searchPage(ids: ["a1"], nextPage: "2")
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()
        XCTAssertEqual(vm.assets.map(\.id), ["a1"])

        client.sharedLinkAlbumAssetsError = APIError.serverError(500, "boom")
        await vm.loadMoreAlbumAssets()

        XCTAssertEqual(vm.assets.map(\.id), ["a1"])
        XCTAssertNotNil(vm.message)
        XCTAssertEqual(vm.phase, .opened)
    }

    // MARK: - Guest upload

    func test_upload_offersOnlyWhenTheLinkAllowsIt() async {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link(type: .album, albumId: "alb-1", allowUpload: false)
        client.sharedLinkAlbumAssetsResponse = searchPage(ids: [], nextPage: nil)
        let vm = makeVM(client: client)

        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()

        XCTAssertFalse(vm.canUpload)
    }

    func test_upload_putsThePhotoInTheLinkAndReloads() async throws {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link(type: .album, albumId: "alb-1")
        client.sharedLinkAlbumAssetsResponse = searchPage(ids: ["a1"], nextPage: nil)
        let vm = makeVM(client: client)
        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()

        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("slv-\(UUID().uuidString).jpg")
        try Data("jpeg-bytes".utf8).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }

        await vm.upload(fileURL: photo, filename: "holiday.jpg", deviceAssetId: "dev-asset")

        XCTAssertEqual(vm.uploadState, .done)
        XCTAssertEqual(client.sharedLinkUploadCredentials, [.slug("holidays")])
        XCTAssertEqual(client.sharedLinkUploadFilenames, ["holiday.jpg"])
        // The reload is what shows the visitor their own photo where it landed.
        XCTAssertEqual(client.sharedLinkAlbumPages, [1, 1])
    }

    /// `requireUploadAccess` refuses with a bare 401 when the link has
    /// `allowUpload: false`. Nothing the visitor can do on this screen changes
    /// that, so the message says so instead of echoing "Unauthorized (401)".
    func test_upload_explainsARefusedUpload() async throws {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link(type: .album, albumId: "alb-1")
        client.sharedLinkAlbumAssetsResponse = searchPage(ids: [], nextPage: nil)
        client.sharedLinkUploadError = serverError(401, message: "Unauthorized")
        let vm = makeVM(client: client)
        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()

        let photo = FileManager.default.temporaryDirectory.appendingPathComponent("slv-\(UUID().uuidString).jpg")
        try Data("jpeg-bytes".utf8).write(to: photo)
        defer { try? FileManager.default.removeItem(at: photo) }

        await vm.upload(fileURL: photo, filename: "holiday.jpg", deviceAssetId: "dev-asset")

        XCTAssertEqual(vm.uploadState, .failed("This link does not allow uploads."))
        XCTAssertEqual(vm.message, "This link does not allow uploads.")
    }

    // MARK: - Reset and derived values

    func test_reset_returnsToAnEmptyForm() async {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link(assets: [asset("a1")])
        let vm = makeVM(client: client)
        vm.linkText = "https://photos.example.com/s/holidays"
        await vm.openLink()

        vm.reset()

        XCTAssertEqual(vm.phase, .entry)
        XCTAssertNil(vm.link)
        XCTAssertTrue(vm.assets.isEmpty)
        XCTAssertNil(vm.credential)
        XCTAssertEqual(vm.linkText, "")
    }

    func test_publicURL_prefersTheSlugAndTheExternalDomain() async {
        let client = MockImmichClient()
        client.sharedLinkMineResponse = link(slug: "summer-2024")
        let vm = makeVM(client: client, externalDomain: "https://photos.public.test")
        vm.linkText = "https://photos.public.test/s/summer-2024"
        await vm.openLink()

        XCTAssertEqual(vm.publicURL?.absoluteString, "https://photos.public.test/s/summer-2024")
    }
}
