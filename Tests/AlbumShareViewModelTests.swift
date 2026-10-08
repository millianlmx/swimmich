import XCTest
@testable import ImmichSwiftUI

@MainActor
final class AlbumShareViewModelTests: XCTestCase {

    private struct Boom: Error {}

    private func makeUser(id: String, name: String) -> UserResponseDto {
        UserResponseDto(
            id: id, name: name, email: "\(id)@example.com",
            profileImagePath: "", avatarColor: "#FF0000", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    private func makeEntry(_ user: UserResponseDto, role: AlbumUserRole) -> AlbumUserResponseDto {
        AlbumUserResponseDto(user: user, role: role)
    }

    private func makeVM(
        mock: MockImmichClient,
        albumUsers: [AlbumUserResponseDto] = [],
        currentUserId: String = "me",
        isAdmin: Bool = true
    ) -> AlbumShareViewModel {
        AlbumShareViewModel(
            client: mock,
            albumId: "al",
            currentUserId: currentUserId,
            isAdmin: isAdmin,
            albumUsers: albumUsers
        )
    }

    // MARK: - Init + load

    func test_init_seedsRolesFromAlbumUsers() {
        let vm = makeVM(
            mock: MockImmichClient(),
            albumUsers: [
                makeEntry(makeUser(id: "owner", name: "Me"), role: .owner),
                makeEntry(makeUser(id: "u1", name: "Alice"), role: .viewer),
                makeEntry(makeUser(id: "u2", name: "Bob"), role: .editor),
            ],
            currentUserId: "owner"
        )
        XCTAssertEqual(vm.role(for: "u1"), .viewer)
        XCTAssertEqual(vm.role(for: "u2"), .editor)
        XCTAssertNil(vm.role(for: "owner"), "current user must never be listed")
    }

    func test_load_excludesCurrentUser() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [makeUser(id: "me", name: "Me"), makeUser(id: "u1", name: "Alice")]
        let vm = makeVM(mock: mock, currentUserId: "me")
        await vm.load()
        XCTAssertEqual(vm.users.map(\.id), ["u1"])
        XCTAssertNil(vm.loadErrorMessage)
    }

    func test_load_keepsGrantedUserMissingFromDirectory() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [makeUser(id: "u1", name: "Alice")]
        let vm = makeVM(
            mock: mock,
            albumUsers: [makeEntry(makeUser(id: "u9", name: "Ghost"), role: .viewer)],
            currentUserId: "me"
        )
        await vm.load()
        XCTAssertEqual(vm.users.map(\.id), ["u1", "u9"], "granted user must stay visible so access can be revoked")
        XCTAssertEqual(vm.role(for: "u9"), .viewer)
    }

    func test_load_error_surfacesButKeepsRoles() async {
        let mock = MockImmichClient()
        mock.getUsersError = Boom()
        let vm = makeVM(
            mock: mock,
            albumUsers: [makeEntry(makeUser(id: "u1", name: "Alice"), role: .editor)]
        )
        await vm.load()
        XCTAssertTrue(vm.users.isEmpty)
        XCTAssertNotNil(vm.loadErrorMessage)
        XCTAssertEqual(vm.role(for: "u1"), .editor, "roles must survive a directory failure")
    }

    // MARK: - Non-admin directory visibility

    func test_load_nonAdminWithOnlySelf_marksDirectoryHidden() async {
        let mock = MockImmichClient()
        // Server behavior for non-admins: GET /users returns only [self].
        mock.getUsersResponse = [makeUser(id: "me", name: "Me")]
        let vm = makeVM(mock: mock, currentUserId: "me", isAdmin: false)
        await vm.load()
        XCTAssertTrue(vm.users.isEmpty)
        XCTAssertTrue(vm.isDirectoryHidden, "non-admin without publicUsers gets an empty directory")
        XCTAssertNil(vm.loadErrorMessage, "empty directory is not an error")
        XCTAssertNil(vm.actionErrorMessage, "empty directory is not an error")
    }

    func test_load_adminWithEmptyInstance_notMarkedHidden() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [makeUser(id: "me", name: "Me")]
        let vm = makeVM(mock: mock, currentUserId: "me", isAdmin: true)
        await vm.load()
        XCTAssertTrue(vm.users.isEmpty)
        XCTAssertFalse(vm.isDirectoryHidden, "admin sees the true empty state, not a hidden directory")
    }

    func test_load_nonAdmin_keepsGrantedUsersVisible() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [makeUser(id: "me", name: "Me")]
        let vm = makeVM(
            mock: mock,
            albumUsers: [makeEntry(makeUser(id: "u9", name: "Ghost"), role: .viewer)],
            currentUserId: "me",
            isAdmin: false
        )
        await vm.load()
        XCTAssertEqual(vm.users.map(\.id), ["u9"], "granted collaborators stay manageable for non-admin owners")
        XCTAssertFalse(vm.isDirectoryHidden, "non-empty list is never 'hidden'")
    }

    // MARK: - Owner + people card lists

    func test_init_ownerSeededFromAlbumUsers() {
        let me = makeUser(id: "me", name: "Me")
        let vm = makeVM(
            mock: MockImmichClient(),
            albumUsers: [
                makeEntry(me, role: .owner),
                makeEntry(makeUser(id: "u1", name: "Alice"), role: .viewer),
            ]
        )
        XCTAssertEqual(vm.owner?.id, "me", "owner row must come from albumUsers")
        XCTAssertEqual(vm.owner?.name, "Me")
    }

    func test_init_ownerFallsBackToFirstEntry() {
        let vm = makeVM(
            mock: MockImmichClient(),
            albumUsers: [makeEntry(makeUser(id: "u1", name: "Alice"), role: .viewer)]
        )
        XCTAssertEqual(vm.owner?.id, "u1", "first entry is the owner per server contract")
    }

    func test_init_ownerNilWhenAlbumHasNoUsers() {
        let vm = makeVM(mock: MockImmichClient())
        XCTAssertNil(vm.owner)
    }

    func test_collaborators_excludesOwnerAndUngranted() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [
            makeUser(id: "me", name: "Me"),
            makeUser(id: "u1", name: "Alice"),
            makeUser(id: "u2", name: "Bob"),
        ]
        let vm = makeVM(
            mock: mock,
            albumUsers: [makeEntry(makeUser(id: "me", name: "Me"), role: .owner)],
            currentUserId: "me"
        )
        await vm.load()
        XCTAssertEqual(vm.collaborators.map(\.id), [], "no granted users yet")
        XCTAssertEqual(vm.inviteCandidates.map(\.id), ["u1", "u2"])

        await vm.grant(makeUser(id: "u1", name: "Alice"), role: .viewer)
        XCTAssertEqual(vm.collaborators.map(\.id), ["u1"])
        XCTAssertEqual(vm.inviteCandidates.map(\.id), ["u2"], "granted user leaves the invite list")
    }

    func test_revoke_movesUserBackToInviteCandidates() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [makeUser(id: "u1", name: "Alice"), makeUser(id: "u2", name: "Bob")]
        let vm = makeVM(
            mock: mock,
            albumUsers: [makeEntry(makeUser(id: "u1", name: "Alice"), role: .editor)]
        )
        await vm.load()
        XCTAssertEqual(vm.collaborators.map(\.id), ["u1"])

        await vm.revoke(userId: "u1")
        XCTAssertTrue(vm.collaborators.isEmpty)
        XCTAssertEqual(vm.inviteCandidates.map(\.id), ["u1", "u2"], "revoked user is invitable again")
    }

    // MARK: - Grant / revoke

    func test_grant_defaultsToViewer() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock: mock)
        let alice = makeUser(id: "u1", name: "Alice")
        await vm.grant(alice)
        XCTAssertEqual(vm.role(for: "u1"), .viewer)
        XCTAssertEqual(mock.lastAddUsersAlbumId, "al")
        XCTAssertEqual(mock.lastAddUsersDto?.albumUsers, [AlbumUserDto(userId: "u1", role: .viewer)])
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_grant_withExplicitRole() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock: mock)
        await vm.grant(makeUser(id: "u1", name: "Alice"), role: .editor)
        XCTAssertEqual(vm.role(for: "u1"), .editor)
        XCTAssertEqual(mock.lastAddUsersDto?.albumUsers, [AlbumUserDto(userId: "u1", role: .editor)])
    }

    func test_grant_error_keepsNoAccess() async {
        let mock = MockImmichClient()
        mock.addUsersError = Boom()
        let vm = makeVM(mock: mock)
        await vm.grant(makeUser(id: "u1", name: "Alice"))
        XCTAssertNil(vm.role(for: "u1"), "failed grant must not appear granted")
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    func test_revoke_removesRole() async {
        let mock = MockImmichClient()
        let vm = makeVM(
            mock: mock,
            albumUsers: [makeEntry(makeUser(id: "u1", name: "Alice"), role: .viewer)]
        )
        await vm.revoke(userId: "u1")
        XCTAssertNil(vm.role(for: "u1"))
        XCTAssertEqual(mock.lastRemovedUserAlbumId, "al")
        XCTAssertEqual(mock.lastRemovedUserId, "u1")
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_revoke_error_keepsRole() async {
        let mock = MockImmichClient()
        mock.removeUserError = Boom()
        let vm = makeVM(
            mock: mock,
            albumUsers: [makeEntry(makeUser(id: "u1", name: "Alice"), role: .viewer)]
        )
        await vm.revoke(userId: "u1")
        XCTAssertEqual(vm.role(for: "u1"), .viewer, "failed revoke must keep access")
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    func test_toggleAccess_grantsThenRevokes() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock: mock)
        let alice = makeUser(id: "u1", name: "Alice")
        await vm.toggleAccess(for: alice)
        XCTAssertEqual(vm.role(for: "u1"), .viewer)
        await vm.toggleAccess(for: alice)
        XCTAssertNil(vm.role(for: "u1"))
    }

    // MARK: - Role change

    func test_setRole_updatesOnlyOnSuccess() async {
        let mock = MockImmichClient()
        let vm = makeVM(
            mock: mock,
            albumUsers: [makeEntry(makeUser(id: "u1", name: "Alice"), role: .viewer)]
        )
        await vm.setRole(.editor, for: "u1")
        XCTAssertEqual(vm.role(for: "u1"), .editor)
        XCTAssertEqual(mock.lastRoleUpdateAlbumId, "al")
        XCTAssertEqual(mock.lastRoleUpdateUserId, "u1")
        XCTAssertEqual(mock.lastRoleUpdateDto, UpdateAlbumUserDto(role: .editor))
        XCTAssertNil(vm.actionErrorMessage)
    }

    func test_setRole_error_keepsOldRole() async {
        let mock = MockImmichClient()
        mock.updateRoleError = Boom()
        let vm = makeVM(
            mock: mock,
            albumUsers: [makeEntry(makeUser(id: "u1", name: "Alice"), role: .viewer)]
        )
        await vm.setRole(.editor, for: "u1")
        XCTAssertEqual(vm.role(for: "u1"), .viewer, "failed role change must keep the old role")
        XCTAssertNotNil(vm.actionErrorMessage)
    }

    func test_setRole_noopForUngrantedUser() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock: mock)
        await vm.setRole(.editor, for: "u9")
        XCTAssertNil(mock.lastRoleUpdateDto, "ungranted user must not dispatch a role change")
        XCTAssertNil(vm.role(for: "u9"))
    }
}
