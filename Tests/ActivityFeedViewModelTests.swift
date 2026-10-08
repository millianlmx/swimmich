import XCTest
@testable import ImmichSwiftUI

final class ActivityFeedViewModelTests: XCTestCase {

    private func makeUser(id: String) -> UserResponseDto {
        UserResponseDto(
            id: id, name: "User \(id)", email: "\(id)@example.com",
            profileImagePath: "", avatarColor: "#FF0000", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    private func makeActivity(
        id: String, createdAt: String, type: ReactionType,
        comment: String? = nil, assetId: String = "", userId: String = "u1"
    ) -> ActivityResponseDto {
        ActivityResponseDto(
            id: id, createdAt: createdAt, type: type,
            user: makeUser(id: userId), assetId: assetId, comment: comment
        )
    }

    @MainActor
    private func makeVM(mock: MockImmichClient) -> ActivityFeedViewModel {
        ActivityFeedViewModel(client: mock, albumId: "alb-1", currentUserId: "me")
    }

    // MARK: - Load / sort

    @MainActor
    func test_load_mapsSortedByCreatedAtDesc() async {
        let mock = MockImmichClient()
        mock.activitiesResponse = [
            makeActivity(id: "a1", createdAt: "2024-01-01T00:00:00.000Z", type: .comment, comment: "First"),
            makeActivity(id: "a2", createdAt: "2024-03-01T00:00:00.000Z", type: .comment, comment: "Later"),
            makeActivity(id: "a3", createdAt: "2024-02-01T00:00:00.000Z", type: .like, assetId: "ph1"),
        ]
        let vm = makeVM(mock: mock)
        await vm.load()

        XCTAssertEqual(vm.activities.map(\.id), ["a2", "a3", "a1"])
        XCTAssertEqual(mock.lastActivitiesAlbumId, "alb-1")
        XCTAssertNil(mock.lastActivitiesAssetId)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_load_failure_setsError() async {
        let mock = MockImmichClient()
        mock.activitiesError = Boom()
        let vm = makeVM(mock: mock)
        await vm.load()

        XCTAssertTrue(vm.activities.isEmpty)
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
    }

    // MARK: - Comments

    @MainActor
    func test_addComment_sendsAlbumCommentDto() async {
        let mock = MockImmichClient()
        mock.activitiesResponse = []
        let vm = makeVM(mock: mock)
        await vm.load()

        let ok = await vm.addComment("  Nice photo!  ")
        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastCreateActivityDto?.albumId, "alb-1")
        XCTAssertEqual(mock.lastCreateActivityDto?.type, .comment)
        XCTAssertEqual(mock.lastCreateActivityDto?.comment, "Nice photo!")
        XCTAssertNotNil(vm.activities.first { $0.id == mock.lastCreateActivityDto.map { _ in "act-new" } })
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_addComment_emptyIsNoOp() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock: mock)
        await vm.load()
        let before = mock.requestCount

        let ok = await vm.addComment("   ")
        XCTAssertFalse(ok)
        XCTAssertEqual(mock.requestCount, before)
        XCTAssertTrue(vm.activities.isEmpty)
    }

    @MainActor
    func test_addComment_failure_keepsClean() async {
        let mock = MockImmichClient()
        mock.activitiesError = Boom()
        let vm = makeVM(mock: mock)
        await vm.load()

        let ok = await vm.addComment("Will fail")
        XCTAssertFalse(ok)
        XCTAssertTrue(vm.activities.isEmpty)
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
    }

    // MARK: - Likes

    @MainActor
    func test_like_createsLikeForAsset() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock: mock)
        let other = makeActivity(id: "c1", createdAt: "2024-01-01T00:00:00.000Z", type: .comment, assetId: "ph1", userId: "u1")

        XCTAssertFalse(vm.hasMyLike(other))
        await vm.toggleLike(activity: other)

        XCTAssertEqual(mock.lastCreateActivityDto?.type, .like)
        XCTAssertEqual(mock.lastCreateActivityDto?.assetId, "ph1")
        XCTAssertNil(mock.lastCreateActivityDto?.comment)
    }

    @MainActor
    func test_like_removesOwnLike() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock: mock)
        let mine = makeActivity(id: "like1", createdAt: "2024-01-01T00:00:00.000Z", type: .like, assetId: "ph1", userId: "me")

        XCTAssertTrue(vm.hasMyLike(mine))
        await vm.toggleLike(activity: mine)

        XCTAssertEqual(mock.lastDeleteActivityId, "like1")
    }

    @MainActor
    func test_like_afterCreateReloadsFeed() async {
        let mock = MockImmichClient()
        mock.activitiesResponse = [
            makeActivity(id: "l1", createdAt: "2024-01-01T00:00:00.000Z", type: .like, assetId: "ph1", userId: "me")
        ]
        mock.createActivityResponse = makeActivity(
            id: "l1", createdAt: "2024-01-01T00:00:00.000Z", type: .like, assetId: "ph1", userId: "me"
        )
        let vm = makeVM(mock: mock)
        await vm.toggleLike(activity: makeActivity(id: "c2", createdAt: "2024-01-01T00:00:00.000Z", type: .comment, assetId: "ph1"))

        XCTAssertEqual(mock.lastCreateActivityDto?.type, .like)
        XCTAssertEqual(vm.activities.map(\.id), ["l1"])
    }

    // MARK: - Delete

    @MainActor
    func test_deleteOwnComment_callsAndRemoves() async {
        let mock = MockImmichClient()
        mock.activitiesResponse = [
            makeActivity(id: "c1", createdAt: "2024-01-01T00:00:00.000Z", type: .comment, comment: "Bye", userId: "me"),
            makeActivity(id: "c2", createdAt: "2024-01-01T00:00:00.000Z", type: .comment, comment: "Stay", userId: "u2"),
        ]
        let vm = makeVM(mock: mock)
        await vm.load()

        await vm.deleteActivity(id: "c1")
        XCTAssertEqual(mock.lastDeleteActivityId, "c1")
        XCTAssertEqual(vm.activities.map(\.id), ["c2"])
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_delete_failure_keepsRow() async {
        let mock = MockImmichClient()
        mock.activitiesResponse = [makeActivity(id: "c1", createdAt: "2024-01-01T00:00:00.000Z", type: .comment, comment: "X", userId: "me")]
        let vm = makeVM(mock: mock)
        await vm.load()

        mock.activitiesError = Boom()
        await vm.deleteActivity(id: "c1")
        XCTAssertEqual(vm.activities.map(\.id), ["c1"])
        XCTAssertEqual(vm.errorMessage, UserFacingError.genericMessage)
    }
}

/// Generic test error.
private struct Boom: Error {
    var localizedDescription: String { "Boom" }
}