import Foundation

/// Partner-sharing state (P3, issue #14): the two directions of the partner
/// relation and the mutations the `/api/partners` routes accept.
///
/// The server splits the relation in two, and the split is not cosmetic — the
/// response of `GET /api/partners?direction=` always carries the *other* user of
/// the pair (`PartnerService.search` → `mapPartner`), and each mutation only
/// pairs one of the two directions:
///
/// | Collection | Query | Rows | Mutation the server accepts |
/// |---|---|---|---|
/// | `sharedWithMe` | `direction=shared-with` | `sharedWithId == me` → the people who share **their** library with me | `PUT /api/partners/{id}` (`{sharedById: id, sharedWithId: me}`) |
/// | `sharing` | `direction=shared-by` | `sharedById == me` → the people **I** added | `DELETE /api/partners/{id}` (`{sharedById: me, sharedWithId: id}`) |
///
/// `setInTimeline` and `remove` therefore refuse an id that is not in their own
/// collection: sending the other one is not an error the server reports, it
/// simply never matches the row it means to change (or removes access the user
/// never asked to remove).
///
/// Until 2026-09-13 the app called `getPartners()` with no query at all, which
/// the server answers with **400** (`direction` is required) — the partner
/// section of the Shared tab never rendered.
@Observable
@MainActor
final class PartnersViewModel {
    let client: any ImmichClient

    /// People who share their library with me — the only rows that carry the
    /// "show in timeline" toggle.
    var sharedWithMe: [PartnerResponseDto] = []
    /// People I added — the only rows that can be removed.
    var sharing: [PartnerResponseDto] = []

    var isLoading = false
    var errorMessage: String?

    // MARK: - Invite flow

    /// Instance users that can still be invited: the directory minus me minus
    /// everyone already in `sharing`.
    var inviteCandidates: [UserResponseDto] = []
    var isLoadingCandidates = false
    var searchQuery = ""
    var selectedCandidateId: String?

    /// `GET /api/users` only returns the current user to a non-admin on a
    /// server with `publicUsers` disabled — the invite sheet says so instead of
    /// showing an empty list.
    var isDirectoryRestricted = false

    /// One invitation at a time; drives the CTA's disabled state.
    var isInviting = false

    init(client: any ImmichClient) {
        self.client = client
    }

    // MARK: - Derived

    var filteredCandidates: [UserResponseDto] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return inviteCandidates }
        return inviteCandidates.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.email.localizedCaseInsensitiveContains(query)
        }
    }

    var canInvite: Bool { selectedCandidateId != nil && !isInviting }

    // MARK: - Load

    /// Loads both directions. A failure on one leaves the other populated —
    /// the two lists are independent queries.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            sharedWithMe = try await client.getPartners(direction: .sharedWith)
            sharing = try await client.getPartners(direction: .sharedBy)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Loads the invite candidates. `excludingUserId` is the signed-in user —
    /// the directory always contains them, and nothing on the server stops a
    /// self-invitation.
    func loadCandidates(excludingUserId currentUserId: String) async {
        isLoadingCandidates = true
        defer { isLoadingCandidates = false }
        do {
            let directory = try await client.getUsers()
            isDirectoryRestricted = directory.count <= 1
            let alreadySharing = Set(sharing.map(\.id))
            inviteCandidates = directory.filter {
                $0.id != currentUserId && !alreadySharing.contains($0.id)
            }
            selectedCandidateId = nil
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func selectCandidate(_ user: UserResponseDto) {
        selectedCandidateId = (selectedCandidateId == user.id) ? nil : user.id
    }

    // MARK: - Mutations

    /// Invites a user. `POST /api/partners` takes a **user id** — the server has
    /// no email lookup on this route. The created partner lands in `sharing`
    /// (the server maps the response with `sharedBy`, i.e. the person I added).
    @discardableResult
    func invite(userId: String) async -> Bool {
        guard !isInviting else { return false }
        isInviting = true
        defer { isInviting = false }
        do {
            let created = try await client.createPartner(sharedWithId: userId)
            if !sharing.contains(where: { $0.id == created.id }) {
                sharing.append(created)
            }
            inviteCandidates.removeAll { $0.id == created.id }
            selectedCandidateId = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.userFacingMessage
            return false
        }
    }

    /// Flips a partner's "show in timeline" flag. Only valid for a row from
    /// `sharedWithMe`: the server pairs the request as `{sharedById: id,
    /// sharedWithId: me}`. Try-then-mutate — the row is replaced only after the
    /// server answers, so a failure leaves the switch where it was.
    func setInTimeline(partnerId: String, enabled: Bool) async {
        guard let index = sharedWithMe.firstIndex(where: { $0.id == partnerId }) else { return }
        do {
            sharedWithMe[index] = try await client.updatePartner(id: partnerId, isInTimeline: enabled)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Stops sharing with a partner. Only valid for a row from `sharing`: the
    /// server pairs the request as `{sharedById: me, sharedWithId: id}`.
    ///
    /// The invite sheet reloads the directory each time it opens, so the
    /// removed person is offered again without a reload here.
    func remove(partnerId: String) async {
        guard sharing.contains(where: { $0.id == partnerId }) else { return }
        do {
            try await client.removePartner(id: partnerId)
            sharing.removeAll { $0.id == partnerId }
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }
}
