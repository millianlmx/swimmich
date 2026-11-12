import XCTest
@testable import ImmichSwiftUI

final class ActivityFeedViewModelTests: XCTestCase {

    override func tearDown() {
        CapturingURLProtocol.reset()
    }

    private static let userJSON = ##"{"id": "u1", "name": "U", "email": "u@t", "profileImagePath": "", "avatarColor": "#000000", "profileChangedAt": "2024-01-01T00:00:00.000Z"}"##

    /// Real HTTP client behind the `CapturingURLProtocol` stub: exercises the
    /// actual JSON decoding of the server payload.
    @MainActor
    private func makeRealClientVM() -> ActivityFeedViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let client = ImmichAPIClient(session: URLSession(configuration: config))
        client.configure(baseURL: URL(string: "https://example.com")!, token: "tok")
        return ActivityFeedViewModel(client: client, albumId: "alb-1", currentUserId: "me")
    }

    private static let feedJSON = """
    [
      {"id": "l1", "createdAt": "2024-01-01T00:00:00.000Z", "type": "like", "user": \(userJSON), "assetId": "ph1"},
      {"id": "c1", "createdAt": "2024-01-02T00:00:00.000Z", "type": "comment", "user": \(userJSON), "assetId": null, "comment": "Hello"}
    ]
    """

    private func makeUser(id: String) -> UserResponseDto {
        UserResponseDto(
            id: id, name: "User \(id)", email: "\(id)@example.com",
            profileImagePath: "", avatarColor: "#FF0000", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    private func makeActivity(
        id: String, createdAt: String, type: ReactionType,
        comment: String? = nil, assetId: String? = nil, userId: String = "u1"
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
        XCTAssertEqual(vm.loadErrorMessage, UserFacingError.genericMessage)
        XCTAssertEqual(vm.renderState, .error(UserFacingError.genericMessage))
        XCTAssertNil(vm.errorMessage, "a failed read is not an action error")
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
    func test_AC_10_load_realClient_albumLevelActivities() async {
        let vm = makeRealClientVM()
        CapturingURLProtocol.nextData = Data(Self.feedJSON.utf8)

        await vm.load()

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.activities.map(\.id), ["c1", "l1"], "newest first")
        XCTAssertNil(vm.activities[0].assetId)
        XCTAssertEqual(vm.activities[1].assetId, "ph1")
    }

    @MainActor
    func test_AC_11_addComment_realClient_nullAssetId() async {
        let vm = makeRealClientVM()
        CapturingURLProtocol.nextStatus = 201
        CapturingURLProtocol.nextData = Data(
            """
            {"id": "c1", "createdAt": "2024-01-02T00:00:00.000Z", "type": "comment", "user": \(Self.userJSON), "assetId": null, "comment": "Hello"}
            """.utf8
        )

        let posted = await vm.addComment("Hello")

        XCTAssertTrue(posted)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.activities.map(\.id), ["c1"])
        XCTAssertNil(vm.activities.first?.assetId)

        CapturingURLProtocol.nextStatus = 200
        CapturingURLProtocol.nextData = Data(Self.feedJSON.utf8)
        await vm.load()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.activities.map(\.id), ["c1", "l1"])
    }

    @MainActor
    func test_AC_12_toggleLike_albumLevelOfOther_isNoOp() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock: mock)
        let albumComment = makeActivity(id: "c1", createdAt: "2024-01-01T00:00:00.000Z", type: .comment, comment: "Hi", userId: "u1")
        let albumLike = makeActivity(id: "l1", createdAt: "2024-01-02T00:00:00.000Z", type: .like, userId: "u1")
        vm.activities = [albumComment, albumLike]

        await vm.toggleLike(activity: albumComment)
        await vm.toggleLike(activity: albumLike)

        XCTAssertNil(mock.lastCreateActivityDto)
        XCTAssertNil(mock.lastDeleteActivityId)
        XCTAssertEqual(mock.requestCount, 0)
        XCTAssertEqual(vm.activities, [albumComment, albumLike])
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_AC_13_toggleLike_ownAlbumLike_deletes() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock: mock)
        let mine = makeActivity(id: "l1", createdAt: "2024-01-01T00:00:00.000Z", type: .like, userId: "me")
        vm.activities = [mine]

        await vm.toggleLike(activity: mine)

        XCTAssertEqual(mock.lastDeleteActivityId, "l1")
        XCTAssertNil(mock.lastCreateActivityDto)
    }

    @MainActor
    func test_AC_18_canToggleLike() {
        let vm = makeVM(mock: MockImmichClient())
        let at = "2024-01-01T00:00:00.000Z"
        XCTAssertTrue(vm.canToggleLike(makeActivity(id: "1", createdAt: at, type: .comment, assetId: "ph1", userId: "u1")))
        XCTAssertTrue(vm.canToggleLike(makeActivity(id: "2", createdAt: at, type: .like, assetId: "ph1", userId: "me")))
        XCTAssertTrue(vm.canToggleLike(makeActivity(id: "3", createdAt: at, type: .like, userId: "me")))
        XCTAssertFalse(vm.canToggleLike(makeActivity(id: "4", createdAt: at, type: .comment, comment: "x", userId: "me")))
        XCTAssertFalse(vm.canToggleLike(makeActivity(id: "5", createdAt: at, type: .like, userId: "u1")))
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

    // MARK: - List states (L-16)

    private let serverError = APIError.serverError(500, "x")

    private func someActivity() -> ActivityResponseDto {
        makeActivity(id: "c1", createdAt: "2024-01-01T00:00:00.000Z", type: .comment, comment: "Hi")
    }

    /// A gate whose first call waits for `latch`; the following ones pass.
    private func holdingFirstCall(_ latch: TestLatch) -> (() async throws -> Void) {
        let calls = TestBox(0)
        return {
            calls.value += 1
            if calls.value == 1 { try await latch.wait() }
        }
    }

    @MainActor
    func test_AC_142_activityFeed_loadingUntilFirstAnswer() async {
        let mock = MockImmichClient()
        mock.activitiesResponse = [someActivity()]
        let latch = TestLatch()
        mock.activitiesGate = { try await latch.wait() }
        let vm = makeVM(mock: mock)
        XCTAssertEqual(vm.renderState, .loading)

        let read = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }

        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await read.value
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_147_activityFeed_successfulEmptyReadIsEmptyState() async {
        let vm = makeVM(mock: MockImmichClient())

        await vm.load()

        XCTAssertEqual(vm.renderState, .empty)
        XCTAssertTrue(vm.hasLoaded)
    }

    @MainActor
    func test_AC_149_activityFeed_firstReadFailsShowsErrorNotEmpty() async {
        let mock = MockImmichClient()
        mock.activitiesError = serverError
        let vm = makeVM(mock: mock)

        await vm.load()

        XCTAssertEqual(vm.renderState, .error(UserFacingError.serverErrorMessage))
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertTrue(vm.activities.isEmpty)
        XCTAssertNil(vm.errorMessage, "the read never writes the action error")
    }

    @MainActor
    func test_AC_149_activityFeed_retryShowsLoadingThenData() async {
        let mock = MockImmichClient()
        mock.activitiesError = serverError
        let vm = makeVM(mock: mock)
        await vm.load()
        mock.activitiesError = nil
        mock.activitiesResponse = [someActivity()]
        let latch = TestLatch()
        mock.activitiesGate = { try await latch.wait() }
        let before = mock.requestCount

        let retry = Task { @MainActor in await vm.load() }
        await pollUntil("retry in flight") { mock.requestCount == before + 1 }

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .loading)
        latch.open()
        await retry.value
        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertEqual(vm.activities.map(\.id), ["c1"])
    }

    @MainActor
    func test_AC_152_activityFeed_refreshFailureKeepsDataThenRetryClears() async {
        let mock = MockImmichClient()
        mock.activitiesResponse = [someActivity()]
        let vm = makeVM(mock: mock)
        await vm.load()

        mock.activitiesError = serverError
        await vm.refresh()

        XCTAssertEqual(vm.renderState, .data(.failed(UserFacingError.serverErrorMessage)))
        XCTAssertEqual(vm.activities.map(\.id), ["c1"])

        mock.activitiesError = nil
        await vm.load()
        XCTAssertEqual(vm.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_activityFeed_refreshFromEmptyAndErrorReads() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock: mock)
        await vm.load()
        XCTAssertEqual(vm.renderState, .empty)

        // From the empty state.
        let emptyLatch = TestLatch()
        mock.activitiesGate = { try await emptyLatch.wait() }
        let emptyBefore = mock.requestCount
        let emptyPull = Task { @MainActor in await vm.refresh() }
        await pollUntil("pull from empty in flight") { mock.requestCount == emptyBefore + 1 }
        XCTAssertTrue(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .empty)
        mock.activitiesResponse = [someActivity()]
        emptyLatch.open()
        await emptyPull.value
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.renderState, .data(.idle))

        // From the error state.
        mock.activitiesGate = nil
        mock.activitiesResponse = nil
        let failing = makeVM(mock: mock)
        mock.activitiesError = serverError
        await failing.load()
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage))
        let errorLatch = TestLatch()
        mock.activitiesGate = { try await errorLatch.wait() }
        mock.activitiesResponse = [someActivity()]
        let errorBefore = mock.requestCount
        let errorPull = Task { @MainActor in await failing.refresh() }
        await pollUntil("pull from error in flight") { mock.requestCount == errorBefore + 1 }
        XCTAssertTrue(failing.isRefreshing)
        XCTAssertEqual(failing.renderState, .error(UserFacingError.serverErrorMessage),
                       "the error stays while the pull reads")
        mock.activitiesError = nil
        errorLatch.open()
        await errorPull.value
        XCTAssertEqual(failing.renderState, .data(.idle))
    }

    @MainActor
    func test_AC_154_activityFeed_refreshDuringReadIsNotIgnored() async {
        let mock = MockImmichClient()
        mock.activitiesResponse = [someActivity()]
        let latch = TestLatch()
        mock.activitiesGate = holdingFirstCall(latch)
        let vm = makeVM(mock: mock)

        let first = Task { @MainActor in await vm.load() }
        await pollUntil("first read in flight") { mock.requestCount == 1 }
        await vm.refresh()
        XCTAssertEqual(mock.requestCount, 2, "a pull during a read is a request of its own")
        XCTAssertEqual(vm.renderState, .data(.idle))

        // The superseded read fails late: it must not write.
        mock.activitiesError = serverError
        latch.open()
        await first.value

        XCTAssertEqual(vm.renderState, .data(.idle))
        XCTAssertFalse(vm.isLoading)
    }
}

/// Generic test error.
private struct Boom: Error {
    var localizedDescription: String { "Boom" }
}