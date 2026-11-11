import XCTest
@testable import ImmichSwiftUI

/// Behaviour of the partner screen's view model.
///
/// The two properties worth defending are structural, not cosmetic:
/// - `load()` asks the server **twice**, once per direction — a single
///   direction-less call is a 400 (`direction` is required server-side), and
///   the response of one direction never contains the other's rows;
/// - `setInTimeline` and `remove` only act on the collection their request can
///   actually address (`PUT` pairs `{sharedById: id, sharedWithId: me}`,
///   `DELETE` the reverse). Sending either on the wrong direction does not
///   change anything server-side, so it must not be sent at all.
final class PartnersViewModelTests: XCTestCase {

    private struct Boom: Error {}

    private func partner(id: String, inTimeline: Bool = false) -> PartnerResponseDto {
        PartnerResponseDto(
            id: id, name: "Partner \(id)", email: "\(id)@test",
            profileImagePath: "", avatarColor: "#3366FF",
            profileChangedAt: "2024-01-01T00:00:00.000Z", inTimeline: inTimeline
        )
    }

    private func user(id: String) -> UserResponseDto {
        UserResponseDto(
            id: id, name: "User \(id)", email: "\(id)@test",
            profileImagePath: "", avatarColor: "#3366FF",
            profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    @MainActor
    func test_load_splitsByDirection() async {
        let mock = MockImmichClient()
        mock.partnersSharedWithResponse = [partner(id: "incoming")]
        mock.partnersSharedByResponse = [partner(id: "outgoing")]
        let vm = PartnersViewModel(client: mock)

        await vm.load()

        XCTAssertEqual(mock.lastPartnersDirections, [.sharedWith, .sharedBy],
                       "both directions are required queries — one call cannot serve both lists")
        XCTAssertEqual(vm.sharedWithMe.map(\.id), ["incoming"])
        XCTAssertEqual(vm.sharing.map(\.id), ["outgoing"])
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_load_failure_setsError() async {
        let mock = MockImmichClient()
        mock.partnersError = Boom()
        let vm = PartnersViewModel(client: mock)

        await vm.load()

        XCTAssertTrue(vm.sharedWithMe.isEmpty)
        XCTAssertTrue(vm.sharing.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
    }

    @MainActor
    func test_invite_postsSharedWithId() async {
        let mock = MockImmichClient()
        let created = self.partner(id: "u2")
        mock.createPartnerResponse = created
        let vm = PartnersViewModel(client: mock)

        let ok = await vm.invite(userId: "u2")

        XCTAssertTrue(ok)
        XCTAssertEqual(mock.lastCreatePartnerSharedWithId, "u2",
                       "POST /api/partners takes a user id — there is no email lookup on that route")
        XCTAssertEqual(vm.sharing.map(\.id), ["u2"], "an invited partner is one I share with")
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_invite_failure_reportsErrorAndAddsNothing() async {
        let mock = MockImmichClient()
        mock.partnersError = Boom()
        let vm = PartnersViewModel(client: mock)

        let ok = await vm.invite(userId: "u2")

        XCTAssertFalse(ok)
        XCTAssertTrue(vm.sharing.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
    }

    @MainActor
    func test_setInTimeline_replacesRowWithServerResponse() async {
        let mock = MockImmichClient()
        mock.partnersSharedWithResponse = [partner(id: "p1")]
        let vm = PartnersViewModel(client: mock)
        await vm.load()
        mock.updatePartnerResponse = partner(id: "p1", inTimeline: true)

        await vm.setInTimeline(partnerId: "p1", enabled: true)

        XCTAssertEqual(mock.lastUpdatePartnerId, "p1")
        XCTAssertEqual(mock.lastUpdatePartnerInTimeline, true)
        XCTAssertEqual(vm.sharedWithMe.first?.inTimeline, true)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_setInTimeline_ignoresOutgoingPartner() async {
        let mock = MockImmichClient()
        mock.partnersSharedByResponse = [partner(id: "outgoing")]
        let vm = PartnersViewModel(client: mock)
        await vm.load()

        await vm.setInTimeline(partnerId: "outgoing", enabled: true)

        XCTAssertNil(mock.lastUpdatePartnerId,
                     "PUT pairs {sharedById: id, sharedWithId: me}: on an outgoing row it targets nothing")
        XCTAssertEqual(vm.sharing.first?.inTimeline, false, "the row cannot be flipped either way")
    }

    @MainActor
    func test_setInTimeline_failure_keepsRow() async {
        let mock = MockImmichClient()
        mock.partnersSharedWithResponse = [partner(id: "p1")]
        let vm = PartnersViewModel(client: mock)
        await vm.load()
        mock.partnersError = Boom()

        await vm.setInTimeline(partnerId: "p1", enabled: true)

        XCTAssertEqual(vm.sharedWithMe.first?.inTimeline, false, "a failed toggle must not flip the switch")
        XCTAssertNotNil(vm.errorMessage)
    }

    @MainActor
    func test_remove_dropsRowOnSuccess() async {
        let mock = MockImmichClient()
        mock.partnersSharedByResponse = [partner(id: "p1"), partner(id: "p2")]
        let vm = PartnersViewModel(client: mock)
        await vm.load()

        await vm.remove(partnerId: "p1")

        XCTAssertEqual(mock.lastRemovePartnerId, "p1")
        XCTAssertEqual(vm.sharing.map(\.id), ["p2"])
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func test_remove_ignoresIncomingPartner() async {
        let mock = MockImmichClient()
        mock.partnersSharedWithResponse = [partner(id: "incoming")]
        let vm = PartnersViewModel(client: mock)
        await vm.load()

        await vm.remove(partnerId: "incoming")

        XCTAssertNil(mock.lastRemovePartnerId,
                     "DELETE pairs {sharedById: me, sharedWithId: id}: on an incoming row it would revoke their access, not mine")
        XCTAssertEqual(vm.sharedWithMe.map(\.id), ["incoming"], "nothing is dropped")
    }

    @MainActor
    func test_remove_failure_keepsRowAndReports() async {
        let mock = MockImmichClient()
        mock.partnersSharedByResponse = [partner(id: "p1")]
        let vm = PartnersViewModel(client: mock)
        await vm.load()
        mock.partnersError = Boom()

        await vm.remove(partnerId: "p1")

        XCTAssertEqual(vm.sharing.map(\.id), ["p1"])
        XCTAssertNotNil(vm.errorMessage)
    }

    @MainActor
    func test_loadCandidates_excludesSelfAndExistingPartners() async {
        let mock = MockImmichClient()
        mock.partnersSharedByResponse = [partner(id: "already")]
        mock.getUsersResponse = [user(id: "me"), user(id: "already"), user(id: "fresh")]
        let vm = PartnersViewModel(client: mock)
        await vm.load()

        await vm.loadCandidates(excludingUserId: "me")

        XCTAssertEqual(vm.inviteCandidates.map(\.id), ["fresh"],
                       "the directory contains me, and re-inviting an existing partner is a 400")
        XCTAssertFalse(vm.isDirectoryRestricted)
    }

    @MainActor
    func test_loadCandidates_flagsRestrictedDirectory() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [user(id: "me")]
        let vm = PartnersViewModel(client: mock)

        await vm.loadCandidates(excludingUserId: "me")

        XCTAssertTrue(vm.inviteCandidates.isEmpty)
        XCTAssertTrue(vm.isDirectoryRestricted,
                      "a non-admin on a private server only ever gets themselves back")
    }

    @MainActor
    func test_filteredCandidates_matchesNameAndEmail() async {
        let mock = MockImmichClient()
        mock.getUsersResponse = [user(id: "me"), user(id: "alice")]
        let vm = PartnersViewModel(client: mock)
        await vm.loadCandidates(excludingUserId: "me")

        vm.searchQuery = "alice"
        XCTAssertEqual(vm.filteredCandidates.map(\.id), ["alice"], "matches on name")

        vm.searchQuery = "alice@test"
        XCTAssertEqual(vm.filteredCandidates.map(\.id), ["alice"], "matches on email")

        vm.searchQuery = "nobody"
        XCTAssertTrue(vm.filteredCandidates.isEmpty)
    }

    @MainActor
    func test_selectCandidate_togglesSelection() async {
        let mock = MockImmichClient()
        let vm = PartnersViewModel(client: mock)
        let candidate = user(id: "u2")

        vm.selectCandidate(candidate)
        XCTAssertEqual(vm.selectedCandidateId, "u2")
        XCTAssertTrue(vm.canInvite)

        vm.selectCandidate(candidate)
        XCTAssertNil(vm.selectedCandidateId, "tapping the selected row clears it")
        XCTAssertFalse(vm.canInvite)
    }

    @MainActor
    func test_AC_18_2_onlySharedWithMeRowsOpenLibrary() {
        let vm = PartnersViewModel(client: MockImmichClient())
        let a = partner(id: "a")
        let o = partner(id: "o")
        // A shares with me and I share with A (reciprocal); O only receives from me.
        vm.sharedWithMe = [a]
        vm.sharing = [a, o]

        XCTAssertEqual(vm.libraryRoute(for: a, direction: .sharedWith), PartnerLibraryRoute(partnerId: "a", name: a.name))
        XCTAssertNil(vm.libraryRoute(for: a, direction: .sharedBy), "the Sharing row of a reciprocal partner opens nothing")
        XCTAssertNil(vm.libraryRoute(for: o, direction: .sharedBy))
        XCTAssertNil(vm.libraryRoute(for: o, direction: .sharedWith), "nobody shares O's library with me")
    }
}
