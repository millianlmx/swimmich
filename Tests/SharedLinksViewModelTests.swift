import XCTest
@testable import ImmichSwiftUI

@MainActor
final class SharedLinksViewModelTests: XCTestCase {

    private struct Boom: Error {}

    // MARK: - Helpers

    private func makeSharedLink(id: String) -> SharedLinkResponseDto {
        SharedLinkResponseDto(
            id: id, description: nil, password: nil, userId: "owner", key: "k\(id)",
            type: .album, createdAt: "2024-01-01T00:00:00.000Z", expiresAt: nil,
            assets: [], album: nil, allowUpload: false, allowDownload: true,
            showMetadata: true, slug: nil
        )
    }

    // MARK: - Load (cross-album: albumId nil)

    func test_load_success() async {
        let mock = MockImmichClient()
        mock.sharedLinksResponse = [makeSharedLink(id: "l1"), makeSharedLink(id: "l2")]
        let vm = SharedLinksViewModel(client: mock)
        await vm.load()
        XCTAssertEqual(vm.sharedLinks.count, 2)
        XCTAssertEqual(vm.sharedLinks.map(\.id), ["l1", "l2"])
        XCTAssertNil(mock.lastSharedLinksAlbumId, "cross-album list must pass albumId: nil")
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.loadErrorMessage)
    }

    func test_load_error() async {
        let mock = MockImmichClient()
        mock.sharedLinksError = Boom()
        let vm = SharedLinksViewModel(client: mock)
        await vm.load()
        XCTAssertTrue(vm.sharedLinks.isEmpty)
        XCTAssertNotNil(vm.loadErrorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - Refresh

    func test_refresh_delegatesToLoad() async {
        let mock = MockImmichClient()
        mock.sharedLinksResponse = [makeSharedLink(id: "l1")]
        let vm = SharedLinksViewModel(client: mock)
        await vm.refresh()
        XCTAssertEqual(vm.sharedLinks.count, 1)
        XCTAssertNil(vm.loadErrorMessage)
    }

    // MARK: - Revoke

    func test_revoke_success_removesLink() async {
        let mock = MockImmichClient()
        mock.sharedLinksResponse = [makeSharedLink(id: "l1"), makeSharedLink(id: "l2")]
        let vm = SharedLinksViewModel(client: mock)
        await vm.load()
        let ok = await vm.revoke(id: "l1")
        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastDeleteSharedLinkId, "l1")
        XCTAssertEqual(vm.sharedLinks.map(\.id), ["l2"], "revoked link removed from list")
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_revoke_error_keepsLink() async {
        let mock = MockImmichClient()
        mock.sharedLinksResponse = [makeSharedLink(id: "l1")]
        let vm = SharedLinksViewModel(client: mock)
        await vm.load()
        mock.deleteSharedLinkError = Boom()
        let ok = await vm.revoke(id: "l1")
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.sharedLinks.count, 1, "failed revoke must keep the link")
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    // MARK: - Create album-typed link

    func test_createAlbumLink_success() async {
        let mock = MockImmichClient()
        let vm = SharedLinksViewModel(client: mock)
        let created = await vm.createAlbumLink(albumId: "a1", description: "Trip", password: nil)
        XCTAssertNotNil(created)
        XCTAssertEqual(mock.lastCreateSharedLinkDto?.type, .album)
        XCTAssertEqual(mock.lastCreateSharedLinkDto?.albumId, "a1")
        XCTAssertEqual(mock.lastCreateSharedLinkDto?.description, "Trip")
        XCTAssertNil(mock.lastCreateSharedLinkDto?.password)
        XCTAssertEqual(vm.sharedLinks.count, 1, "created link appended to list")
        XCTAssertNil(vm.actionErrorMessage)
    }

    /// The create sheet shows the link on a "link ready" panel, so the call must
    /// hand back the server's answer — with the slug it was given — not just a
    /// success flag.
    func test_createAlbumLink_sendsSlugAndExpiryAndReturnsLink() async {
        let mock = MockImmichClient()
        let vm = SharedLinksViewModel(client: mock)
        let expiry = Date().addingTimeInterval(24 * 60 * 60)

        let created = await vm.createAlbumLink(
            albumId: "a1",
            description: "Trip",
            password: nil,
            slug: "  trip-2026  ",
            expiresAt: expiry
        )

        XCTAssertEqual(created?.slug, "trip-2026", "the returned link carries the slug")
        XCTAssertEqual(mock.lastCreateSharedLinkDto?.slug, "trip-2026", "trimmed before the wire")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sent = try? XCTUnwrap(mock.lastCreateSharedLinkDto?.expiresAt)
        XCTAssertEqual(iso.date(from: sent ?? "")?.timeIntervalSince1970 ?? 0, expiry.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(vm.sharedLinks.first?.slug, "trip-2026", "the appended row is the created link")
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_createAlbumLink_whitespacePasswordTrimmedToNil() async {
        let mock = MockImmichClient()
        let vm = SharedLinksViewModel(client: mock)
        let created = await vm.createAlbumLink(albumId: "a1", description: nil, password: "   ")
        XCTAssertNotNil(created)
        XCTAssertNil(mock.lastCreateSharedLinkDto?.password, "whitespace-only password must be nil")
        XCTAssertNil(mock.lastCreateSharedLinkDto?.slug, "no slug requested, none sent")
        XCTAssertNil(mock.lastCreateSharedLinkDto?.expiresAt, "no expiry chosen, none sent")
    }

    func test_createAlbumLink_blankSlugIsNotASlug() async {
        let mock = MockImmichClient()
        let vm = SharedLinksViewModel(client: mock)
        _ = await vm.createAlbumLink(albumId: "a1", description: nil, password: nil, slug: "   ")
        // The server stores `dto.slug || null`; a blank string would be a
        // meaningless slug that still shadows the link's key in the URL.
        XCTAssertNil(mock.lastCreateSharedLinkDto?.slug)
    }

    func test_createAlbumLink_error_appendsNothing() async {
        let mock = MockImmichClient()
        mock.createSharedLinkError = Boom()
        let vm = SharedLinksViewModel(client: mock)
        let created = await vm.createAlbumLink(albumId: "a1", description: nil, password: nil)
        XCTAssertNil(created, "no link to show on the ready panel")
        XCTAssertTrue(vm.sharedLinks.isEmpty)
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    // MARK: - Edit link (AC-1090)

    func test_updateLink_sendsDtoAndReplacesRow() async {
        let mock = MockImmichClient()
        mock.sharedLinksResponse = [makeSharedLink(id: "l1")]
        let vm = SharedLinksViewModel(client: mock)
        await vm.load()

        let updated = SharedLinkResponseDto(
            id: "l1", description: "Trip photos", password: nil, userId: "owner", key: "kl1",
            type: .album, createdAt: "2024-01-01T00:00:00.000Z", expiresAt: nil,
            assets: [], album: nil, allowUpload: true, allowDownload: true,
            showMetadata: false, slug: nil
        )
        mock.updateSharedLinkResponse = updated
        let dto = SharedLinkEditDto(
            password: nil, expiresAt: "2025-12-31T23:59:59.000Z",
            allowUpload: true, allowDownload: true, showMetadata: false,
            description: "Trip photos"
        )
        let ok = await vm.updateLink(id: "l1", dto: dto)

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastUpdateSharedLinkId, "l1")
        XCTAssertEqual(mock.lastUpdateSharedLinkDto, dto)
        XCTAssertEqual(vm.sharedLinks[0].description, "Trip photos", "row replaced with server response")
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_updateLink_failure_keepsRow() async {
        let mock = MockImmichClient()
        mock.sharedLinksResponse = [makeSharedLink(id: "l1")]
        let vm = SharedLinksViewModel(client: mock)
        await vm.load()
        mock.sharedLinksError = Boom()

        let ok = await vm.updateLink(id: "l1", dto: SharedLinkEditDto())

        XCTAssertFalse(ok)
        XCTAssertEqual(vm.sharedLinks.count, 1, "failed edit must keep the row")
        XCTAssertEqual(vm.sharedLinks[0].id, "l1")
        XCTAssertNotNil(vm.actionErrorMessage)
    }
}
