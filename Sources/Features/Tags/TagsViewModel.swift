import Foundation

/// Tag management state (gap #2, L-03): the tag hierarchy, creation under a
/// parent, deletion.
@Observable
@MainActor
final class TagsViewModel {
    let client: any ImmichClient

    /// The flat list the server sent. Every write rebuilds `rows` from it.
    private(set) var tags: [TagResponseDto] = [] {
        didSet { rows = TagTree.rows(from: tags) }
    }
    /// The hierarchy in display order (`TagTree`).
    private(set) var rows: [TagRow] = []
    var isLoading = false
    /// True while `refresh()` runs: the system's refresh control is the
    /// indicator then, not the screen's own.
    private(set) var isRefreshing = false
    /// True once the list was read and applied.
    private(set) var hasLoaded = false
    /// Failure of the last read of the list, cleared by a success. Written by
    /// `load` only.
    private(set) var loadErrorMessage: String?
    /// Delete failures.
    var errorMessage: String?
    /// Bumped by every read, so only the last one writes its result.
    private var loadGeneration = 0
    private(set) var isCreating = false
    /// Why the last `create` failed, shown inside the creation sheet.
    private(set) var createErrorMessage: String?

    /// Candidate parents for a new tag, by full path.
    var parentChoices: [TagResponseDto] {
        tags.sorted {
            let order = $0.path.localizedStandardCompare($1.path)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    init(client: any ImmichClient) {
        self.client = client
    }

    /// What the list renders.
    var renderState: ListRenderState {
        .resolve(
            isEmpty: rows.isEmpty,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            loadError: loadErrorMessage
        )
    }

    /// First read, "Try Again" and `.task` (never pulls). The list is replaced
    /// only by a success; a newer read supersedes one still in flight. Without
    /// `force`, a read already in flight is not duplicated.
    func load(force: Bool = false) async {
        guard !(isLoading && !force) else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let fetched = try await client.getAllTags()
            guard generation == loadGeneration else { return }
            tags = fetched
            hasLoaded = true
            loadErrorMessage = nil
        } catch {
            guard generation == loadGeneration, let message = error.userFacingMessage else { return }
            loadErrorMessage = message
        }
    }

    /// Pull-to-refresh: `load(force: true)` flagged so the screen keeps its
    /// current rendering.
    func refresh() async {
        isRefreshing = true
        await load(force: true)
        isRefreshing = false
    }

    /// Creates a tag under `parentId` (root when `nil`). On success the server's
    /// answer is inserted in place — no `getAllTags` replay — and the row lands
    /// where the answer's own `parentId` puts it. On failure nothing changes
    /// but `createErrorMessage`.
    func create(name: String, parentId: String?) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCreating else { return false }
        isCreating = true
        defer { isCreating = false }
        createErrorMessage = nil
        do {
            let created = try await client.createTag(name: trimmed, color: nil, parentId: parentId)
            tags.append(created)
            return true
        } catch {
            createErrorMessage = error.userFacingMessage
            return false
        }
    }

    func clearCreateError() {
        createErrorMessage = nil
    }

    func delete(_ tag: TagResponseDto) async {
        do {
            try await client.deleteTag(id: tag.id)
            errorMessage = nil
            await load(force: true)
        } catch {
            errorMessage = error.userFacingMessage
        }
    }
}
