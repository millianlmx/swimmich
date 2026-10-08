import Foundation

/// Duplicate-group state — parity with the Flutter client's duplicate cleanup.
/// Each server group carries `suggestedKeepAssetIds`; deleting the group
/// removes every asset EXCEPT the suggested keep(s) (`deleteAssets` with the
/// rest). try-then-mutate throughout: the group is dropped only after the
/// server call succeeds.
@MainActor
@Observable
final class DuplicatesViewModel {
    private let client: any ImmichClient

    var groups: [DuplicateResponseDto] = []
    var isLoading = false
    var errorMessage: String?

    init(client: any ImmichClient) {
        self.client = client
    }

    /// Loads the duplicate groups from `GET /api/duplicates`.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            groups = try await client.getDuplicates()
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// The asset ids that would be deleted for a group: everything except the
    /// server-suggested keeps. Empty when the group is fully "keep".
    func deletableIds(for group: DuplicateResponseDto) -> [String] {
        let keep = Set(group.suggestedKeepAssetIds)
        return group.assets.map(\.id).filter { !keep.contains($0) }
    }

    /// Deletes all non-suggested assets of `duplicateId`, then reloads the
    /// groups. On failure the group stays (retryable) + errorMessage is set.
    func deleteGroup(id: String) async {
        guard let group = groups.first(where: { $0.duplicateId == id }) else { return }
        let ids = deletableIds(for: group)
        guard !ids.isEmpty else {
            // Nothing to delete — drop the group locally so it can't loop.
            groups.removeAll { $0.duplicateId == id }
            return
        }
        do {
            try await client.deleteAssets(ids: ids, force: false)
            // Local drop only — no re-fetch: the server may still return the
            // group until its duplicate job re-runs; pull-to-refresh covers it.
            groups.removeAll { $0.duplicateId == id }
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }
}
