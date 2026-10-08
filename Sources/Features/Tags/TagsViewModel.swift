import Foundation

/// Tag management state (gap #2): list, create, delete server tags.
@Observable
@MainActor
final class TagsViewModel {
    let client: any ImmichClient

    var tags: [TagResponseDto] = []
    var isLoading = false
    var errorMessage: String?

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

    func create(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await client.createTag(name: trimmed, color: nil)
            errorMessage = nil
            await load(force: true)
        } catch {
            errorMessage = error.userFacingMessage
        }
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
