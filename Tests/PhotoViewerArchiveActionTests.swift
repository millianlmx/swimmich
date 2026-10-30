import XCTest
@testable import ImmichSwiftUI

/// Which button the photo viewer offers (Archive / Unarchive / none), and how an
/// unknown visibility (map) is resolved.
final class PhotoViewerArchiveActionTests: XCTestCase {

    private func item(id: String, visibility: String, ownerId: String = "", isImage: Bool = true) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: ownerId, ratio: 1, isFavorite: false, visibility: visibility,
            isTrashed: false, isImage: isImage, thumbhash: nil,
            createdAt: "", fileCreatedAt: "", localOffsetHours: 0,
            duration: nil, livePhotoVideoId: nil, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func response(id: String, visibility: String) -> AssetResponseDto {
        AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2024-07-01T00:00:00.000Z",
            ownerId: "owner", originalPath: "/x.jpg", originalFileName: "x.jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", fileModifiedAt: "2024-07-01T00:00:00.000Z",
            updatedAt: "2024-07-01T00:00:00.000Z", isFavorite: false, isArchived: visibility == "archive",
            isTrashed: false, isOffline: false, visibility: visibility, checksum: "abc", isEdited: false
        )
    }

    func test_AC10_archivedVisibilityOffersUnarchive() {
        XCTAssertEqual(ViewerArchiveAction(visibility: "archive"), .unarchive)
        for visibility in ["timeline", "locked", "hidden"] {
            XCTAssertEqual(ViewerArchiveAction(visibility: visibility), .archive, visibility)
        }
    }

    func test_AC18_unresolvedVisibilityOffersNothing() {
        XCTAssertNil(ViewerArchiveAction(visibility: AssetReactItem.unresolvedVisibility))
    }

    func test_AC18_resolveVisibilityReadsServerOnlyWhenUnresolved() async {
        let mock = MockImmichClient()
        mock.getAssetResponse["A"] = response(id: "A", visibility: "archive")

        let before = mock.requestCount
        let resolved = await ViewerArchiveAction.resolveVisibility(
            of: item(id: "A", visibility: AssetReactItem.unresolvedVisibility), client: mock
        )
        XCTAssertEqual(resolved, "archive")
        XCTAssertEqual(mock.requestCount, before + 1)

        let afterRead = mock.requestCount
        let known = await ViewerArchiveAction.resolveVisibility(of: item(id: "A", visibility: "timeline"), client: mock)
        XCTAssertEqual(known, "timeline")
        XCTAssertEqual(mock.requestCount, afterRead, "a known visibility costs no request")

        mock.globalError = APIError.serverError(500, "boom")
        let failed = await ViewerArchiveAction.resolveVisibility(
            of: item(id: "A", visibility: AssetReactItem.unresolvedVisibility), client: mock
        )
        XCTAssertNil(failed)
    }

    // MARK: - Owner-only controls

    func test_ownerOnly_AC10_ownerActionPredicate() {
        let cases: [(owner: String, user: String?, allowed: Bool)] = [
            ("me", "me", true), ("partner", "me", false), ("", "me", true),
            ("partner", nil, true), ("partner", "", true),
        ]
        for c in cases {
            let asset = item(id: "A", visibility: "timeline", ownerId: c.owner)
            XCTAssertEqual(asset.allowsOwnerActions(currentUserId: c.user), c.allowed, "\(c.owner)/\(String(describing: c.user))")
        }
    }

    func test_ownerOnly_AC11_bottomBarHidesOwnerControlsForPartner() {
        let partner = ViewerActions(asset: item(id: "A", visibility: "timeline", ownerId: "partner"),
                                    visibility: "timeline", isTrash: false, currentUserId: "me")
        XCTAssertTrue(partner.showsShare)
        XCTAssertFalse(partner.showsFavorite)
        XCTAssertFalse(partner.showsEdit)
        XCTAssertNil(partner.archive)
        XCTAssertFalse(partner.showsDelete)

        let mine = ViewerActions(asset: item(id: "A", visibility: "timeline", ownerId: "me"),
                                 visibility: "timeline", isTrash: false, currentUserId: "me")
        XCTAssertEqual(mine, ViewerActions(asset: item(id: "A", visibility: "timeline", ownerId: ""),
                                           visibility: "timeline", isTrash: false, currentUserId: "me"),
                       "unknown owner keeps today's controls")
        XCTAssertTrue(mine.showsShare && mine.showsFavorite && mine.showsEdit && mine.showsDelete)
        XCTAssertEqual(mine.archive, .archive)

        let archived = ViewerActions(asset: item(id: "A", visibility: "archive", ownerId: "me"),
                                     visibility: "archive", isTrash: false, currentUserId: "me")
        XCTAssertEqual(archived.archive, .unarchive)

        let video = ViewerActions(asset: item(id: "V", visibility: "timeline", ownerId: "me", isImage: false),
                                  visibility: "timeline", isTrash: false, currentUserId: "me")
        XCTAssertTrue(video.showsFavorite)
        XCTAssertFalse(video.showsEdit, "videos have no editor")

        let unresolved = ViewerActions(asset: item(id: "M", visibility: AssetReactItem.unresolvedVisibility, ownerId: "me"),
                                       visibility: AssetReactItem.unresolvedVisibility, isTrash: false, currentUserId: "me")
        XCTAssertNil(unresolved.archive)

        for owner in ["me", "partner"] {
            let trash = ViewerActions(asset: item(id: "T", visibility: "timeline", ownerId: owner),
                                      visibility: "timeline", isTrash: true, currentUserId: "me")
            XCTAssertFalse(trash.showsShare || trash.showsFavorite || trash.showsEdit, owner)
            XCTAssertNil(trash.archive, owner)
            XCTAssertTrue(trash.showsDelete, "Trash keeps Delete Permanently for \(owner)")
        }
    }

    func test_ownerOnly_AC12_infoPanelEditsFollowOwnership() {
        func edits(owner: String, user: String?) -> Bool {
            ViewerActions(asset: item(id: "A", visibility: "timeline", ownerId: owner),
                          visibility: "timeline", isTrash: false, currentUserId: user).allowsInfoEdits
        }
        XCTAssertFalse(edits(owner: "partner", user: "me"))
        XCTAssertTrue(edits(owner: "me", user: "me"))
        XCTAssertTrue(edits(owner: "", user: "me"))
        XCTAssertTrue(edits(owner: "partner", user: nil))
    }
}
