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
    /// Load and delete failures.
    var errorMessage: String?
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

    func load(force: Bool = false) async {
        guard !(isLoading && !force) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            tags = try await client.getAllTags()
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
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
