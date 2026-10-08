import Foundation

/// Photo-stack state (gap #1): the stacks the server holds, their covers, and
/// the mutations the `/api/stacks` routes expose.
///
/// All six stack routes were already wired in `ImmichClient`; `searchStacks`
/// and `createStack` had no caller, and the rest were only reachable from the
/// viewer's `StackSheet`. This VM is the hub-level surface — list, create,
/// unstack, change cover, drop a member — plus the create-flow state (recent
/// assets to pick from, current selection).
///
/// `@Observable @MainActor` mirrors TagsViewModel / PeopleViewModel.
@Observable
@MainActor
final class StacksViewModel {
    let client: any ImmichClient

    var stacks: [StackResponseDto] = []
    var isLoading = false
    var errorMessage: String?

    /// Stack currently opened in the detail screen (nil until it loads).
    var selectedStack: StackResponseDto?

    // MARK: - Create flow

    /// Recent assets offered by the photo picker (`CreateStackSheet`,
    /// `AddToStackSheet`). Paged through `POST /api/search/metadata` (newest
    /// first) rather than the timeline buckets: a sheet can be opened from the
    /// hub, where no timeline page is loaded.
    var recentAssets: [AssetReactItem] = []
    var selectedIds: Set<String> = []
    var isLoadingAssets = false

    /// Drives the create sheet. Lives on the VM (not the view) so a reload of
    /// the hub list can't dismiss the sheet mid-selection.
    var showCreate = false

    /// Page size per picker fetch.
    private let pickerPageSize = 100
    private var pickerNextPage: String?
    /// False once the server reported no next page (and before the first load
    /// is requested — `beginPicking` is what opens the flow).
    private var pickerHasMore = true
    /// Ids already handed to the picker — the server may repeat an asset across
    /// pages while the library changes under us.
    private var pickerLoadedIds: Set<String> = []

    init(client: any ImmichClient) {
        self.client = client
    }

    var canLoadMoreAssets: Bool { pickerHasMore && !recentAssets.isEmpty }

    /// The selection in the picker's display order (newest first).
    ///
    /// Order is the payload: `POST /api/stacks` makes `assetIds[0]` the cover,
    /// and a `Set` has none — so every stack mutation sends this, never
    /// `Array(selectedIds)`.
    var orderedSelection: [String] {
        recentAssets.map(\.id).filter { selectedIds.contains($0) }
    }

    // MARK: - List

    func loadStacks(force: Bool = false) async {
        guard !(isLoading && !force) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            stacks = try await client.searchStacks(primaryAssetId: nil)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Loads one stack and keeps it in `selectedStack` for the detail screen.
    /// A failure surfaces through `errorMessage` and leaves the screen with
    /// nothing to show — the detail view renders the error with a retry.
    func loadStack(id: String, force: Bool = false) async {
        if !force, let current = selectedStack, current.id == id { return }
        isLoading = true
        defer { isLoading = false }
        do {
            selectedStack = try await client.getStack(id: id)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Mutations

    /// Creates a stack from `assetIds` (first id becomes the cover, min 2 —
    /// the server rejects anything shorter).
    func createStack(assetIds: [String]) async {
        guard assetIds.count >= 2 else { return }
        do {
            _ = try await client.createStack(assetIds: assetIds)
            resetPicking()
            showCreate = false
            errorMessage = nil
            await loadStacks(force: true)
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func deleteStack(id: String) async {
        do {
            try await client.deleteStack(id: id)
            stacks.removeAll { $0.id == id }
            if selectedStack?.id == id { selectedStack = nil }
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func updatePrimary(stackId: String, assetId: String) async {
        do {
            selectedStack = try await client.updateStack(id: stackId, primaryAssetId: assetId)
            await refreshCover(inList: stackId)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func removeAssetFromStack(stackId: String, assetId: String) async {
        do {
            try await client.removeAssetFromStack(stackId: stackId, assetId: assetId)
            await loadStack(id: stackId, force: true)
            await refreshCover(inList: stackId)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Adds photos to an existing stack, keeping its current cover.
    ///
    /// **There is no "add asset to stack" route.** Verified against the server
    /// (`server/src/controllers/stack.controller.ts` and the published
    /// OpenAPI, main and v1.135.0): the stack API is `GET/POST /stacks`,
    /// `GET/PUT/DELETE /stacks/:id` and `DELETE /stacks/:id/assets/:assetId` —
    /// 7 operations and none of them adds a member. The backlog's
    /// `POST /api/assets/:stackId/assets` does not exist.
    ///
    /// The sanctioned path is `POST /api/stacks`, whose own contract is merge:
    /// *"If any of the provided asset IDs are primary assets of an existing
    /// stack, the existing stack will be merged into the newly created stack."*
    /// `StackRepository.create` implements it by finding every owned stack whose
    /// `primaryAssetId` is in the payload, folding **all** of its members in,
    /// deleting it, then inserting a new stack with `primaryAssetId = assetIds[0]`
    /// and re-parenting every collected asset onto it. Posting this stack's
    /// current primary alongside the new ids therefore extends it in place.
    ///
    /// Three consequences this method is responsible for:
    /// - the current cover must lead the payload — `assetIds[0]` becomes the new
    ///   stack's primary, so posting the new photos first would silently change
    ///   this stack's cover;
    /// - the stack's **id changes**: the server deletes and re-inserts, so the
    ///   old id is dead the moment this returns. The new id is returned for the
    ///   caller to follow (a view holding the old one would show "stack no
    ///   longer available");
    /// - an asset belongs to at most one stack, so a picked photo that already
    ///   sits in another stack is *re-parented* into this one — and picking
    ///   another stack's cover merges that whole stack in. The picker hides
    ///   this stack's own members; the rest is the server's documented merge.
    ///
    /// - Returns: the stack's new id, or `nil` when nothing was sent or the call
    ///   failed (the failure lands in `errorMessage`).
    @discardableResult
    func addPhotos(toStackId stackId: String, primaryAssetId: String, assetIds: [String]) async -> String? {
        // Re-posting the cover alone would be a 1-id payload, which the server
        // rejects (`.min(2)`), and adding a photo the stack already holds would
        // needlessly re-create it.
        let additions = assetIds.filter { $0 != primaryAssetId }
        guard !additions.isEmpty else { return nil }
        do {
            let updated = try await client.createStack(assetIds: [primaryAssetId] + additions)
            selectedStack = updated
            errorMessage = nil
            await loadStacks(force: true)
            return updated.id
        } catch {
            errorMessage = error.userFacingMessage
            return nil
        }
    }

    /// Re-reads one stack so the hub list shows the new cover/count. Cheap
    /// (one GET) and keeps the list truthful without a full reload.
    private func refreshCover(inList stackId: String) async {
        guard let index = stacks.firstIndex(where: { $0.id == stackId }) else { return }
        if let updated = try? await client.getStack(id: stackId) {
            stacks[index] = updated
        }
    }

    // MARK: - Picker

    /// Resets the picker and loads its first page. Called when a picker sheet
    /// appears, so a reopened sheet never shows the previous selection.
    func beginPicking() async {
        resetPicking()
        await loadMoreAssets()
    }

    private func resetPicking() {
        recentAssets = []
        selectedIds = []
        pickerNextPage = nil
        pickerHasMore = true
        pickerLoadedIds = []
    }

    func toggleSelection(id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// Loads the next page of pickable assets. A no-op once the library is
    /// exhausted; errors surface through `errorMessage` (the grid keeps what it
    /// already has).
    func loadMoreAssets() async {
        guard !isLoadingAssets, pickerHasMore else { return }
        isLoadingAssets = true
        defer { isLoadingAssets = false }
        do {
            // `order: "desc"` = newest first, matching the timeline's first page.
            var dto = MetadataSearchDto(order: "desc", size: pickerPageSize)
            if let page = pickerNextPage { dto.page = Int(page) }
            let response = try await client.searchMetadata(dto: dto)
            let fresh = response.assets.items
                .filter { pickerLoadedIds.insert($0.id).inserted }
                .map(AssetReactItem.init(from:))
            recentAssets.append(contentsOf: fresh)
            pickerNextPage = response.assets.nextPage
            pickerHasMore = response.assets.nextPage != nil
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }
}
