import Foundation
import SwiftUI

/// Timeline state: drives bucket-level pagination + columnar→object zip.
///
/// AC-006 + AC-013: loads buckets one at a time (no in-bucket pagination).
/// loadMore() advances to the next bucket, accumulates items, dedupes by id.
@Observable
final class TimelineViewModel {
    var buckets: [TimeBucketsResponseDto] = []
    var items: [AssetReactItem] = []
    var bucketIndex: Int = 0
    /// Next NEWER bucket to load when scrolling up (after a `jump`). -1 = none
    /// (the timeline already starts at the newest bucket).
    var upperBucketIndex: Int = -1
    var isLoading: Bool = false
    var loadErrorMessage: String?
    var actionErrorMessage: String?
    /// Partner photos left out of the last selection action (owner-only server
    /// rights). `nil` = nothing to report. Distinct from `actionErrorMessage`:
    /// the action itself succeeded or sent nothing.
    var skippedPartnerCount: Int?

    /// Loaded item IDs for O(1) dedup (FM-1 / AC-006).
    private(set) var loadedIds: Set<String> = []

    let client: any ImmichClient
    /// Active filter of the main timeline. `.all` asks the server for my
    /// photos plus those of partners with "Show in timeline" on.
    private(set) var filter: TimelineFilter = .all
    var filterIsFavorite: Bool? { filter.isFavorite }
    var filterIsTrashed: Bool?
    var filterVisibility: String? { filter.visibility }
    var filterWithPartners: Bool? { filter.withPartners }

    /// Collapse every stack to its primary tile, with the stack reported on
    /// that tile (`stackId`/`stackCount`). On, the server drops the other
    /// members from the bucket, so a stacked tile must route to the stack
    /// itself — otherwise those photos become unreachable (`TimelineView`).
    /// The trash keeps asking for the flat list (`TrashViewModel`).
    var withStacked: Bool = true

    init(client: any ImmichClient) {
        self.client = client
    }

    var canLoadMore: Bool { bucketIndex < buckets.count }

    // MARK: - Selection mode (AC-201)

    /// True while the grid is in multi-select mode (long-press entry). Drives
    /// per-cell checkmark overlays + the selection toolbar.
    var selectionMode: Bool = false

    /// Ids the user has checked while in selection mode. Keyed by id so it
    /// survives pagination (`loadMore` appends items but selectedIds is stable).
    var selectedIds: Set<String> = []

    func enterSelectionMode() { selectionMode = true }

    func exitSelectionMode() {
        selectionMode = false
        selectedIds.removeAll()
    }

    /// Toggles membership of `id` in `selectedIds`. Callers enter selection
    /// mode first (long-press / Select button); the toggle itself is mode-agnostic.
    func toggleSelection(id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    // MARK: - Filter (AC-1010)

    /// Applies a timeline filter and reloads. No-op when the requested filter
    /// already matches, so the grid keeps its position between identical taps.
    @MainActor
    func setFilter(_ newFilter: TimelineFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        await refresh()
    }

    /// What a tap on a tile opens: the flat viewer, or the stack screen.
    /// The server refuses `StackRead` to a non-owner, so the cover of a
    /// partner's stack opens the viewer on the cover itself. Unknown owner
    /// (no logged-in id, offline items with an empty `ownerId`) keeps the
    /// stack route.
    static func tapRoute(for item: AssetReactItem, currentUserId: String?) -> TimelineTapRoute {
        guard let stackId = item.stackId else { return .viewer }
        return item.allowsOwnerActions(currentUserId: currentUserId) ? .stack(id: stackId) : .viewer
    }

    /// Splits the selection for an owner-only batch action: `ids` are sent,
    /// `skipped` counts partner photos the server would refuse (and fail the
    /// whole request for). Unknown owner is sent (see `allowsOwnerActions`),
    /// as is an id the grid no longer holds. Pure; order of `ids` is
    /// unspecified.
    func ownerScopedSelection(currentUserId: String?) -> (ids: [String], skipped: Int) {
        let foreign = Set(items.lazy.filter {
            selectedIds.contains($0.id) && !$0.allowsOwnerActions(currentUserId: currentUserId)
        }.map(\.id))
        return (Array(selectedIds).filter { !foreign.contains($0) }, foreign.count)
    }

    // MARK: - Favorite toggle (AC-202)

    /// Toggles favorite on a single asset via `updateAsset`, then patches
    /// `items` in place via `AssetReactItem.with(isFavorite:)`.
    /// Try-then-mutate discipline: on throw the `items` array is left untouched
    /// and `actionErrorMessage` is surfaced — UI never lies about server state.
    @MainActor
    func toggleFavorite(id: String) async {
        guard let current = items.first(where: { $0.id == id }) else { return }
        await setFavorite(id: id, isFavorite: !current.isFavorite)
    }

    /// Writes an **explicit** favorite state. `toggleFavorite(id:)` derives the
    /// target from the grid row it holds; the photo viewer cannot — it keeps
    /// its own optimistic set and knows which value it wants, and re-deriving
    /// it from a snapshot the surface has not refreshed yet would send a no-op.
    /// Same try-then-mutate discipline; unlike `batchSetFavorite`, an id the
    /// grid does not hold is still written (the viewer pages through assets the
    /// timeline never loaded).
    @MainActor
    @discardableResult
    func setFavorite(id: String, isFavorite value: Bool) async -> Bool {
        do {
            _ = try await client.updateAsset(id: id, dto: UpdateAssetDto(isFavorite: value))
            // Mutate only after the network call succeeded.
            applyFavorite(value, to: id)
            actionErrorMessage = nil
            return true
        } catch let e {
            actionErrorMessage = e.userFacingMessage
            return false
        }
    }

    /// Reflects a favorite write that already succeeded on the server. Under
    /// the Favorites filter an un-favorited asset no longer belongs to the
    /// grid: it leaves `items`, `loadedIds` and the selection (a later
    /// selection action must not target an invisible asset). Otherwise the
    /// row is patched in place; an id the grid does not hold changes nothing
    /// (a re-favorite is written but not re-inserted until the next refresh).
    @MainActor
    private func applyFavorite(_ value: Bool, to id: String) {
        if filterIsFavorite == true && !value {
            items.removeAll { $0.id == id }
            loadedIds.remove(id)
            selectedIds.remove(id)
        } else if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = items[idx].with(isFavorite: value)
        }
    }

    // MARK: - Batch delete (AC-203 / AC-203b)

    /// Deletes the selected assets the user owns (a partner's photo is refused
    /// by the server, and `requireAccess` fails the whole request). On success
    /// removes them from `items` + `loadedIds` and exits selection mode. On
    /// throw, state is preserved so the user can retry (actionErrorMessage set,
    /// selectedIds kept, selectionMode stays true). Empty selection is a no-op.
    /// Skipped partner photos are announced by the confirmation beforehand, so
    /// a success does not publish `skippedPartnerCount`; with nothing
    /// sendable, no request is made and the notice is published.
    @MainActor
    func deleteSelected(currentUserId: String?) async {
        await removeOwnedSelection(currentUserId: currentUserId, reportsSkipped: false) { ids in
            try await client.deleteAssets(ids: ids, force: false)
        }
    }

    /// Shared shape of delete / archive / locked folder: send only the ids the
    /// user owns, then drop them from the grid and close the selection.
    /// Try-then-mutate: a throw publishes `actionErrorMessage` and leaves
    /// `items`, `loadedIds` and the selection untouched.
    @MainActor
    private func removeOwnedSelection(
        currentUserId: String?,
        reportsSkipped: Bool,
        send: ([String]) async throws -> Void
    ) async {
        guard !selectedIds.isEmpty else { return }
        let (ids, skipped) = ownerScopedSelection(currentUserId: currentUserId)
        guard !ids.isEmpty else {
            skippedPartnerCount = skipped
            return
        }
        do {
            // MUST throw-or-succeed before mutating anything.
            try await send(ids)
            let sent = Set(ids)
            items.removeAll { sent.contains($0.id) }
            loadedIds.subtract(sent)
            exitSelectionMode()
            if reportsSkipped && skipped > 0 { skippedPartnerCount = skipped }
        } catch let e {
            actionErrorMessage = e.userFacingMessage
        }
    }

    // MARK: - Refresh (AC-204)

    /// Pull-to-refresh: exits selection, re-fetches buckets, reloads only the
    /// first bucket. Subsequent buckets come back on scroll (`loadMore`).
    @MainActor
    func archiveSelected(currentUserId: String?) async {
        await removeOwnedSelection(currentUserId: currentUserId, reportsSkipped: true) { ids in
            try await client.bulkUpdateAssets(dto: AssetBulkUpdateDto(ids: ids, visibility: .archive))
        }
    }

    /// - Returns: `true` when the server accepted the archive. The photo
    ///   viewer's own path needs the outcome to decide whether the surface it
    ///   came from should re-read; a refusal is published either way.
    @MainActor
    @discardableResult
    func archive(id: String) async -> Bool {
        do {
            try await client.bulkUpdateAssets(dto: AssetBulkUpdateDto(ids: [id], visibility: .archive))
            items.removeAll { $0.id == id }
            loadedIds.remove(id)
            return true
        } catch let e {
            actionErrorMessage = e.userFacingMessage
            return false
        }
    }

    /// Moves a single asset back to the timeline (`visibility: timeline`).
    /// Try-then-mutate: a refusal (server or read-only) leaves `items`,
    /// `loadedIds` and `selectedIds` untouched and is published in
    /// `actionErrorMessage`. An id the grid does not hold is still sent (the
    /// photo viewer's standalone path runs on an empty private VM).
    /// - Returns: `true` when the server accepted.
    @MainActor
    @discardableResult
    func unarchive(id: String) async -> Bool {
        do {
            try await client.bulkUpdateAssets(dto: AssetBulkUpdateDto(ids: [id], visibility: .timeline))
            applyUnarchived([id])
            return true
        } catch let e {
            actionErrorMessage = e.userFacingMessage
            return false
        }
    }

    /// Unarchives the whole selection in one request, then exits selection
    /// mode whatever the filter. A refusal keeps items, selection and mode.
    @MainActor
    func unarchiveSelected() async {
        guard !selectedIds.isEmpty else { return }
        let ids = Array(selectedIds)
        do {
            try await client.bulkUpdateAssets(dto: AssetBulkUpdateDto(ids: ids, visibility: .timeline))
            applyUnarchived(Set(ids))
            exitSelectionMode()
        } catch let e {
            actionErrorMessage = e.userFacingMessage
        }
    }

    /// Reflects an unarchive that already succeeded on the server. Under the
    /// Archived filter the assets leave the grid; elsewhere (Favorites also
    /// lists archived photos) they stay, patched in place, and the section
    /// caches are reset so the cells re-read the new visibility.
    @MainActor
    private func applyUnarchived(_ ids: Set<String>) {
        if filter == .archived {
            items.removeAll { ids.contains($0.id) }
            loadedIds.subtract(ids)
            selectedIds.subtract(ids)
        } else {
            for idx in items.indices where ids.contains(items[idx].id) {
                items[idx] = items[idx].with(visibility: AssetVisibility.timeline.rawValue)
            }
            _groupedByDay = nil
            _groupedByDayKey = nil
            _timelineSections = nil
            _timelineSectionsKey = nil
        }
    }

    /// Single entry point of the photo viewer's archive/unarchive button, with
    /// or without a surface callback.
    /// - Parameter handOffError: `true` = the caller shows the refusal itself
    ///   (the viewer's banner), so the grid must no longer present it.
    /// - Returns: `nil` when the server accepted, else the refusal message.
    @MainActor
    func setArchived(id: String, archived: Bool, handOffError: Bool) async -> String? {
        let accepted = archived ? await archive(id: id) : await unarchive(id: id)
        if accepted { return nil }
        let message = actionErrorMessage
        if handOffError { actionErrorMessage = nil }
        return message
    }

    /// True when the cell menu / viewer should offer "Unarchive" for `item`:
    /// the Archived filter, or an item that is archived (Favorites lists both).
    func offersUnarchive(for item: AssetReactItem) -> Bool {
        filter == .archived || item.visibility == AssetVisibility.archive.rawValue
    }

    /// True when the selection toolbar shows "Unarchive": the Archived filter,
    /// or a non-empty selection made only of archived items still in the grid.
    var selectionOffersUnarchive: Bool {
        filter == .archived || (!selectedIds.isEmpty && selectedIds.allSatisfy { id in
            items.first { $0.id == id }?.visibility == AssetVisibility.archive.rawValue
        })
    }

    // MARK: - Locked folder (gap G12)

    /// Moves the selection into the locked folder — the same bulk route as
    /// Archive, with `visibility: locked`. The assets leave the timeline
    /// immediately (the server stops returning them under the default
    /// visibility), and the folder is the only screen that reads them back.
    @MainActor
    func moveSelectedToLockedFolder(currentUserId: String?) async {
        await removeOwnedSelection(currentUserId: currentUserId, reportsSkipped: true) { ids in
            try await client.bulkUpdateAssets(dto: AssetBulkUpdateDto(ids: ids, visibility: .locked))
        }
    }

    /// Single-asset variant, used by a cell's context menu.
    @MainActor
    func moveToLockedFolder(id: String) async {
        do {
            try await client.bulkUpdateAssets(dto: AssetBulkUpdateDto(ids: [id], visibility: .locked))
            items.removeAll { $0.id == id }
            loadedIds.remove(id)
        } catch let e {
            actionErrorMessage = e.userFacingMessage
        }
    }

    @MainActor
    func refresh() async {
        exitSelectionMode()
        isLoading = true
        loadErrorMessage = nil
        do {
            try await reloadFirstPage()
        } catch let e {
            loadErrorMessage = e.userFacingMessage
        }
        isLoading = false
    }

    @MainActor
    func load() async {
        isLoading = true
        loadErrorMessage = nil
        do {
            try await reloadFirstPage()
        } catch let e {
            loadErrorMessage = e.userFacingMessage
        }
        isLoading = false
    }

    /// Re-fetches the bucket list and the first page. The shown items are only
    /// replaced once the first bucket has loaded: if that bucket fails or is
    /// cancelled, the photos already on screen stay (SP-1 / SP-5).
    @MainActor
    private func reloadFirstPage() async throws {
        buckets = try await fetchBuckets()
        bucketIndex = 0
        upperBucketIndex = -1
        let previousItems = items
        let previousLoadedIds = loadedIds
        items = []
        loadedIds = []
        await loadNextBucket()
        if bucketIndex == 0 && !buckets.isEmpty {
            items = previousItems
            loadedIds = previousLoadedIds
        }
    }

    @MainActor
    func loadMore() async {
        guard !isLoading else { return }
        await loadNextBucket()
    }

    /// Teleports the timeline to a specific day: loads that day's bucket
    /// directly (replacing `items`), then lets `loadMore` continue into older
    /// buckets and `loadNewer` into newer ones. No-op when the day isn't found.
    @MainActor
    func jump(toDay day: String) async {
        guard !day.isEmpty else { return }
        if buckets.isEmpty {
            do {
                buckets = try await fetchBuckets()
            } catch let e {
                loadErrorMessage = e.userFacingMessage
                return
            }
        }
        guard let index = buckets.firstIndex(where: { $0.timeBucket == day }) else { return }
        isLoading = true
        do {
            let columnar = try await fetchBucket(buckets[index].timeBucket)
            let zipped = AssetReactItem.zip(columnar)
            items = zipped
            loadedIds = Set(zipped.map(\.id))
            bucketIndex = index + 1
            upperBucketIndex = index - 1
        } catch let e {
            loadErrorMessage = e.userFacingMessage
        }
        isLoading = false
    }

    /// Loads the bucket immediately NEWER than the current top (used when the
    /// user scrolls up after a jump). Prepends so the timeline stays sorted
    /// newest-first.
    @MainActor
    func loadNewer() async {
        guard !isLoading, upperBucketIndex >= 0 else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let columnar = try await fetchBucket(buckets[upperBucketIndex].timeBucket)
            let zipped = AssetReactItem.zip(columnar)
            let newItems = zipped.filter { !loadedIds.contains($0.id) }
            items.insert(contentsOf: newItems, at: 0)
            loadedIds.formUnion(newItems.map(\.id))
            upperBucketIndex -= 1
        } catch let e {
            loadErrorMessage = e.userFacingMessage
        }
    }

    @MainActor
    private func loadNextBucket() async {
        guard bucketIndex < buckets.count else { return }
        let bucket = buckets[bucketIndex]
        do {
            let columnar = try await fetchBucket(bucket.timeBucket)
            // AC-013: zip columnar into objects.
            let zipped = AssetReactItem.zip(columnar)
            for item in zipped where !loadedIds.contains(item.id) {
                items.append(item)
                loadedIds.insert(item.id)
            }
            bucketIndex += 1
        } catch let e {
            loadErrorMessage = e.userFacingMessage
        }
    }

    /// The single place listing the filters of `GET /api/timeline/buckets`.
    @MainActor
    private func fetchBuckets() async throws -> [TimeBucketsResponseDto] {
        try await client.getTimeBuckets(isFavorite: filterIsFavorite, isTrashed: filterIsTrashed, personId: nil, withPartners: filterWithPartners, visibility: filterVisibility, withStacked: withStacked, orderBy: nil)
    }

    /// The single place listing the filters of `GET /api/timeline/bucket`:
    /// the same ones as `fetchBuckets()`, or the server applies its defaults
    /// to the month (e.g. non-favorites slip into the Favorites filter).
    @MainActor
    private func fetchBucket(_ timeBucket: String) async throws -> TimeBucketAssetResponseDto {
        try await client.getTimeBucket(timeBucket: timeBucket, isFavorite: filterIsFavorite, isTrashed: filterIsTrashed, personId: nil, withPartners: filterWithPartners, visibility: filterVisibility, withStacked: withStacked, orderBy: nil)
    }

    /// Grouped view of loaded items by day (fileCreatedAt date portion).
    /// Provided as a convenience for the grid view.
    ///
    /// Memoized: the Dictionary grouping + two sorts ran on every `body`
    /// evaluation (audit P1) even though the grouping only depends on `items`.
    /// The cache is invalidated by a `(count, lastId)` signature — every
    /// `items` mutation that adds or removes rows (append, replace-all,
    /// removeAll) changes one of these. An in-place patch (`items[idx] = …`)
    /// changes neither, and the cells render the cached COPIES: a patch that
    /// must show in the grid (`applyUnarchived`) resets the four cache
    /// storages itself. The in-place favorite patch does not (pre-existing).
    private var _groupedByDay: [(day: String, items: [AssetReactItem])]?
    private var _groupedByDayKey: (count: Int, lastId: String?)?

    var groupedByDay: [(day: String, items: [AssetReactItem])] {
        let key = (count: items.count, lastId: items.last?.id)
        if let cacheKey = _groupedByDayKey, cacheKey.count == key.count, cacheKey.lastId == key.lastId,
           let cached = _groupedByDay {
            return cached
        }
        let groups = Dictionary(grouping: items) { item -> String in
            // ISO8601 YYYY-MM-DD prefix
            String(item.fileCreatedAt.prefix(10))
        }
        let computed = groups
            .map { (day: $0.key, items: $0.value.sorted { $0.fileCreatedAt > $1.fileCreatedAt }) }
            .sorted { $0.day > $1.day }
        _groupedByDay = computed
        _groupedByDayKey = key
        return computed
    }

    /// The sections the grid renders, built from `groupedByDay` via
    /// `TimelineSectionBuilder.build`. Memoized on the same `(count, lastId)`
    /// signature as `groupedByDay` — plus the grouping itself, which is a
    /// parameter of the builder (settings-parity): a cache keyed on the items
    /// alone would hand the previous grouping back after the user switches it.
    /// Memoization is what keeps the whole pipeline (Dictionary + sorts + banner
    /// interleave) off every `body` evaluation (audit P1).
    private var _timelineSections: [TimelineSectionBuilder.Section]?
    private var _timelineSectionsKey: (count: Int, lastId: String?, groupBy: TimelineGroupBy)?

    func timelineSections(groupBy: TimelineGroupBy) -> [TimelineSectionBuilder.Section] {
        let key = (count: items.count, lastId: items.last?.id, groupBy: groupBy)
        if let cacheKey = _timelineSectionsKey, cacheKey.count == key.count, cacheKey.lastId == key.lastId,
           cacheKey.groupBy == key.groupBy, let cached = _timelineSections {
            return cached
        }
        let computed = TimelineSectionBuilder.build(from: groupedByDay, groupBy: groupBy)
        _timelineSections = computed
        _timelineSectionsKey = key
        return computed
    }

    // MARK: - Batch favorite (V7)

    /// Sets favorite uniformly across `ids` (skips ids already in the target
    /// state). Backs the selection-toolbar heart action. Same try-then-mutate
    /// discipline as `toggleFavorite`; first throw stops the batch and surfaces
    /// `actionErrorMessage` without mutating the remaining items.
    /// - Returns: `true` when every id reached the target state, `false` on
    ///   error — callers exit selection mode only on success (audit fix).
    @MainActor
    @discardableResult
    func batchSetFavorite(_ ids: Set<String>, favorite value: Bool) async -> Bool {
        for id in ids {
            guard let current = items.first(where: { $0.id == id }), current.isFavorite != value else { continue }
            do {
                _ = try await client.updateAsset(id: id, dto: UpdateAssetDto(isFavorite: value))
                applyFavorite(value, to: id)
            } catch let e {
                actionErrorMessage = e.userFacingMessage
                return false
            }
        }
        return true
    }

    /// The whole heart gesture of the selection bar: target computed on the
    /// ids the user may change only (a partner's photo never decides it), send,
    /// partner notice, selection closed. Nothing sendable: no request, notice
    /// only, selection kept. A refusal keeps the selection and publishes
    /// `actionErrorMessage` (published by `batchSetFavorite`).
    @MainActor
    func favoriteSelected(currentUserId: String?) async {
        guard !selectedIds.isEmpty else { return }
        let (ids, skipped) = ownerScopedSelection(currentUserId: currentUserId)
        guard !ids.isEmpty else {
            skippedPartnerCount = skipped
            return
        }
        let target = !ids.allSatisfy { id in items.first { $0.id == id }?.isFavorite ?? false }
        if await batchSetFavorite(Set(ids), favorite: target) {
            exitSelectionMode()
            if skipped > 0 { skippedPartnerCount = skipped }
        }
    }

    // MARK: - Single-asset delete (V9 context menu)

    /// Deletes a single asset by id (used by the cell context menu). Does NOT
    /// touch selection state — distinct from `deleteSelected` which operates on
    /// the selection set. Same try-then-mutate discipline.
    /// - Returns: `true` when the server accepted the delete (see `archive(id:)`).
    @MainActor
    @discardableResult
    func delete(id: String) async -> Bool {
        do {
            try await client.deleteAssets(ids: [id], force: false)
            items.removeAll { $0.id == id }
            loadedIds.remove(id)
            return true
        } catch let e {
            actionErrorMessage = e.userFacingMessage
            return false
        }
    }

    // MARK: - Stack (gap #1)

    /// Stacks the selected assets (the newest selected photo becomes primary,
    /// min 2). On success exits selection mode and refreshes so the new stack
    /// badges appear. Same try-then-mutate discipline as the other batch
    /// actions.
    ///
    /// Order comes from `items`, not from `selectedIds`: the server makes the
    /// **first** id the stack's primary (cover), and a `Set` has no order — the
    /// cover would be arbitrary. Grid order makes "the newest selected photo is
    /// the cover" predictable, and the cover stays changeable from the stack
    /// detail.
    @MainActor
    func stackSelected(currentUserId: String?) async {
        let selected = items.filter { selectedIds.contains($0.id) }
        let owned = selected.filter { $0.allowsOwnerActions(currentUserId: currentUserId) }.map(\.id)
        let skipped = selected.count - owned.count
        guard owned.count >= 2 else {
            if skipped > 0 { skippedPartnerCount = skipped }
            return
        }
        do {
            _ = try await client.createStack(assetIds: owned)
            exitSelectionMode()
            if skipped > 0 { skippedPartnerCount = skipped }
            await refresh()
        } catch let e {
            actionErrorMessage = e.userFacingMessage
        }
    }
}

/// Filters of the main timeline, in menu order. The network parameters are
/// derived here so no case can combine `withPartners` with anything but
/// `visibility=timeline` (the server answers 400 otherwise). `.all` sends
/// `visibility=timeline` explicitly: without it the server also returns
/// archived assets, and older servers refuse `withPartners` altogether.
enum TimelineFilter: String, Sendable, CaseIterable {
    case all
    case favorites
    case archived

    var isFavorite: Bool? {
        switch self {
        case .all, .archived: nil
        case .favorites: true
        }
    }

    var visibility: String? {
        switch self {
        case .all: "timeline"
        case .favorites: nil
        case .archived: "archive"
        }
    }

    var withPartners: Bool? {
        switch self {
        case .all: true
        case .favorites, .archived: nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .favorites: "Favorites"
        case .archived: "Archived"
        }
    }
}

/// Destination of a tap on a timeline tile.
enum TimelineTapRoute: Equatable {
    case viewer
    case stack(id: String)
}
