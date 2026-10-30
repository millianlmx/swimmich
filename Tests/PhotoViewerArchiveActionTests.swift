import XCTest
@testable import ImmichSwiftUI

/// Which button the photo viewer offers (Archive / Unarchive / none), and how an
/// unknown visibility (map) is resolved.
final class PhotoViewerArchiveActionTests: XCTestCase {

    private func item(id: String, visibility: String) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "", ratio: 1, isFavorite: false, visibility: visibility,
            isTrashed: false, isImage: true, thumbhash: nil,
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
}
