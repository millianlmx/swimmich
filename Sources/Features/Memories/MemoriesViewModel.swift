import Foundation

/// Memories ("On this day") tab state — lists `MemoryResponseDto`s from
/// `GET /api/memories` (P0 api-surface-expansion) and carries the memory CRUD
/// the `/api/memories` routes expose: save/unsave, create from a photo
/// selection, delete, and add/remove assets.
///
/// `@Observable @MainActor` mirrors StacksViewModel.
@MainActor
@Observable
final class MemoriesViewModel {
    private let client: any ImmichClient

    var memories: [MemoryResponseDto] = []
    var isLoading = false
    var errorMessage: String?

    // MARK: - Create flow

    /// Drives the create sheet. Lives on the VM (not the view) so a reload of
    /// the list cannot dismiss the sheet mid-selection.
    var showCreate = false
    var isCreating = false

    /// The day the user is creating a memory for. Its year becomes the memory's
    /// `data.year` (`OnThisDayDto`) and its timestamp the `memoryAt` anchor —
    /// those three fields plus `assetIds` are the whole `POST /api/memories`
    /// payload; there is no name to collect.
    var memoryDate = Date()

    // MARK: - Picker

    /// Recent assets offered by the photo picker (`CreateMemorySheet`,
    /// `AddPhotosToMemorySheet`). Paged through `POST /api/search/metadata`
    /// (newest first) rather than the timeline buckets: both sheets open from
    /// the Memories tab, where no timeline page is loaded.
    var recentAssets: [AssetReactItem] = []
    var selectedIds: Set<String> = []
    var isLoadingAssets = false

    private let pickerPageSize = 100
    private var pickerNextPage: String?
    /// False once the server reported no next page (and before the first load is
    /// requested — `beginPicking` is what opens the flow).
    private var pickerHasMore = true
    /// Ids already handed to the picker — the server may repeat an asset across
    /// pages while the library changes under us.
    private var pickerLoadedIds: Set<String> = []

    init(client: any ImmichClient) {
        self.client = client
    }

    var canLoadMoreAssets: Bool { pickerHasMore && !recentAssets.isEmpty }

    /// The selection in the picker's display order (newest first). Order is not
    /// load-bearing server-side for memories (unlike a stack cover), but the
    /// memory's first asset is what the card shows as its hero, so the newest
    /// selection should lead.
    var orderedSelection: [String] {
        recentAssets.map(\.id).filter { selectedIds.contains($0) }
    }

    /// The memory the full-screen moment view is showing, resolved live so a
    /// mutation (or a delete) is reflected on screen.
    func memory(id: String) -> MemoryResponseDto? {
        memories.first { $0.id == id }
    }

    // MARK: - Load

    /// Loads the memory list, sorted by memory date descending (freshest year
    /// first). try-then-mutate: `memories` is replaced only on success.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await client.getMemories()
            memories = fetched.sorted {
                ($0.data.year, $0.memoryAt) > ($1.data.year, $1.memoryAt)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Save / unsave

    func saveMemory(id: String) async {
        await setSaved(id: id, saved: true)
    }

    func unsaveMemory(id: String) async {
        await setSaved(id: id, saved: false)
    }

    /// `PUT /api/memories/{id}` body `{isSaved}`. The server answers with the
    /// updated memory, which replaces the row in place — the list order is by
    /// `memoryAt`, and saving does not move a memory.
    private func setSaved(id: String, saved: Bool) async {
        do {
            let updated = try await client.updateMemory(id: id, dto: MemoryUpdateDto(isSaved: saved))
            if let index = memories.firstIndex(where: { $0.id == id }) {
                memories[index] = updated
            }
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Create

    /// Creates a memory from the picker's selection for `memoryDate`.
    ///
    /// Three facts the payload encodes, all verified against the server:
    /// `data: {year}` and `memoryAt` must both be present (the DTO rejects a
    /// create without them) and describe the same day; `type` only ever takes
    /// `on_this_day` server-side; and the memory is created **saved**, because
    /// the server's cleanup job deletes unsaved memories older than 30 days —
    /// a memory the user asked for must not be born scheduled for deletion.
    func createMemory() async {
        let assetIds = orderedSelection
        guard !assetIds.isEmpty, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }

        let dto = MemoryCreateDto(
            assetIds: assetIds,
            data: OnThisDayDto(year: Self.dayComponents(of: memoryDate).year ?? 0),
            memoryAt: Self.memoryAtString(for: memoryDate),
            type: .on_this_day,
            isSaved: true
        )
        do {
            _ = try await client.createMemory(dto: dto)
            resetPicking()
            showCreate = false
            errorMessage = nil
            await load()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Mutations on one memory

    func deleteMemory(id: String) async {
        do {
            try await client.deleteMemory(id: id)
            memories.removeAll { $0.id == id }
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// `PUT /api/memories/{id}/assets` body `{ids}` — the route answers one
    /// result per id, not the memory, so the memory is re-read to show the new
    /// members (mirrors `StacksViewModel.removeAssetFromStack`).
    @discardableResult
    func addAssets(toMemoryId id: String, assetIds: [String]) async -> Bool {
        guard !assetIds.isEmpty else { return false }
        do {
            _ = try await client.addAssetsToMemory(id: id, assetIds: assetIds)
            await refreshMemory(id: id)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.userFacingMessage
            return false
        }
    }

    /// `DELETE /api/memories/{id}/assets` body `{ids}`.
    ///
    /// - Returns: `false` once the memory holds no asset left — `GET
    ///   /api/memories` filters out empty memories server-side (`MemoryService.search`
    ///   drops them), so an emptied memory stops existing for this client and the
    ///   screen showing it must close. `true` while it still has assets, and also
    ///   on failure: nothing was removed and the error is on screen.
    @discardableResult
    func removeAssets(fromMemoryId id: String, assetIds: [String]) async -> Bool {
        guard !assetIds.isEmpty else { return true }
        do {
            _ = try await client.removeAssetsFromMemory(id: id, assetIds: assetIds)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
            return true
        }
        guard let updated = try? await client.getMemory(id: id) else { return true }
        if updated.assets.isEmpty {
            memories.removeAll { $0.id == id }
            return false
        }
        if let index = memories.firstIndex(where: { $0.id == id }) {
            memories[index] = updated
        }
        return true
    }

    /// Re-reads one memory so the list shows its new members. Cheap (one GET)
    /// and keeps the row truthful without a full reload.
    private func refreshMemory(id: String) async {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        if let updated = try? await client.getMemory(id: id) {
            memories[index] = updated
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

    /// The picked day, in the user's own calendar. Both halves of the payload
    /// come from here so `data.year` and `memoryAt` can never describe two
    /// different days.
    nonisolated static func dayComponents(of date: Date, calendar: Calendar = .current) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }


    /// UTC midnight of the day the user picked.
    ///
    /// The memory's day is read back in **UTC** (`MemoryCardPresentation.monthDayLabel`
    /// pins the timezone so a memory never drifts a day), so the anchor has to be
    /// that day's UTC midnight. Formatting the picker's instant directly would
    /// shift the day west by one for every positive UTC offset: "May 4" saved
    /// from Paris would come back as "May 3".
    nonisolated static func memoryAtString(for date: Date, calendar: Calendar = .current) -> String {
        let parts = dayComponents(of: date, calendar: calendar)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let midnight = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
        return isoString(from: midnight ?? date)
    }

    /// Wire format for `memoryAt` — the server takes an ISO-8601 instant and
    /// the DTO's pattern requires the time part.
    nonisolated static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
