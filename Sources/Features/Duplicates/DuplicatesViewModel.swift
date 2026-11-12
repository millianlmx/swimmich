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
    /// True while `refresh()` runs: the system's refresh control is the
    /// indicator then, not the screen's own.
    private(set) var isRefreshing = false
    /// True once the groups were read and applied.
    private(set) var hasLoaded = false
    /// Failure of the last read, cleared by a success. Written by `load()`
    /// only.
    private(set) var loadErrorMessage: String?
    /// Failure of the last `deleteGroup`.
    var errorMessage: String?
    /// Bumped by every `load()`, so only the last read writes its result.
    private var loadGeneration = 0

    init(client: any ImmichClient) {
        self.client = client
    }

    /// What the screen renders.
    var renderState: ListRenderState {
        .resolve(
            isEmpty: groups.isEmpty,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            loadError: loadErrorMessage
        )
    }

    /// Loads the duplicate groups from `GET /api/duplicates` (`.task` and
    /// "Try Again", never a pull). The groups are replaced by a success only.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }

        do {
            let fetched = try await client.getDuplicates()
            guard generation == loadGeneration else { return }
            groups = fetched
            hasLoaded = true
            loadErrorMessage = nil
        } catch {
            guard generation == loadGeneration, let message = error.userFacingMessage else { return }
            loadErrorMessage = message
        }
    }

    /// Pull-to-refresh: `load()` flagged so the screen keeps its current
    /// rendering.
    func refresh() async {
        isRefreshing = true
        await load()
        isRefreshing = false
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
