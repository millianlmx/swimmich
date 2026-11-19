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

    // MARK: - Date scrubber state (L-04)

    /// Where the date scrubber's handle rests outside a gesture: the month of
    /// the first visible photo and how far into it. Observed by
    /// `TimelineScrubber` only — `TimelineView.body` never reads it, or every
    /// row change would re-evaluate the whole grid.
    var scrubPosition: TimelineScrubPosition?
    /// The month a failed jump was heading to, so "Try Again" reloads that
    /// month and nothing else. `nil` once any load supersedes it.
    private(set) var pendingJump: PendingJump?
    /// Bumped by every jump and by every reload: a jump (or a neighbour load)
    /// whose answer arrives after a newer one must not touch the window.
    @ObservationIgnored private var jumpGeneration = 0
    @ObservationIgnored private var activeJump: Int?
    /// Months already fetched during the scrub in progress (`timeBucket` →
    /// answer), so a month the finger comes back to is shown at once instead
    /// of asked again. `nil` outside a gesture: the cache lives a few seconds
    /// and never outlives it, so it cannot serve a month edited meanwhile.
    @ObservationIgnored private var scrubCache: [String: [AssetReactItem]]?

    // MARK: - Merged timeline (device photos)

    /// The device half of the merged timeline: this phone's photos the server
    /// does not have yet (`DeviceTimelineSource`). `nil` keeps the timeline the
    /// server's alone — every `TimelineViewModel` but the Photos tab's (search
    /// results, archive, trash…) never sets it.
    @ObservationIgnored var deviceSource: (any DeviceTimelineSource)?
    /// The library ids the backup ledger proves on the server, read at every
    /// month list: a photo just backed up leaves the device half and is shown
    /// by its server copy alone.
    @ObservationIgnored var uploadedDeviceIDs: @MainActor () -> Set<String> = { [] }
    /// The Preferences switch "Show photos from this device".
    @ObservationIgnored var showsDeviceAssets: @MainActor () -> Bool = { true }
    /// The library id a server photo was backed up from (the backup ledger's
    /// bridge), for "Delete from This Device Too". `nil` everywhere but the
    /// Photos tab.
    @ObservationIgnored var deviceCopyID: @MainActor (String) -> String? = { _ in nil }

    /// The library ids of the copies this device still holds of `serverIDs`.
    @MainActor
    func deviceCopies(of serverIDs: [String]) -> [String] {
        serverIDs.compactMap { id in
            deviceCopyID(id).flatMap { DeviceMedia.exists(localIdentifier: $0) ? $0 : nil }
        }
    }
    /// The device half of the last month list, by `"yyyy-MM"`.
    @ObservationIgnored private var deviceItemsByMonth: [String: [AssetReactItem]] = [:]
    /// The months the server itself has (`"yyyy-MM"`): a month only the device
    /// has is never asked of the server.
    @ObservationIgnored private var serverMonths: Set<String> = []
    /// The ids of the device half last merged, so a return to the foreground
    /// reloads only when the library actually changed.
    @ObservationIgnored private(set) var deviceItemIDs: Set<String> = []
    /// `MergedTimeline.dedupeKey` of every server photo loaded since the last
    /// reload: a device photo matching one is that photo, already on screen.
    @ObservationIgnored private var serverKeys: Set<String> = []
    /// Bumped each time the window of loaded months is replaced; a neighbour
    /// load that started before the replacement is discarded on arrival.
    @ObservationIgnored private(set) var windowEpoch = 0
    /// Month index and rank (grid order) of every loaded photo — what turns
    /// the ids the scroll view reports as visible into a scrubber position.
    @ObservationIgnored private var placeById: [String: (month: Int, rank: Int)] = [:]
    /// The first visible photo as last reported by the scroll view; the
    /// re-anchor target after a newer month is prepended.
    @ObservationIgnored private(set) var topVisibleId: String?

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

    /// True while the loaded window begins at the newest month (nothing newer
    /// to prepend).
    var windowStartsAtNewest: Bool { upperBucketIndex < 0 }

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
        // A device-only photo has no server id for the batch actions to send:
        // it is backed up, shared or deleted on its own (cell menu, viewer).
        guard !AssetReactItem.isDeviceOnlyID(id) else { return }
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
            self.selectedIds.contains($0.id) && !$0.allowsOwnerActions(currentUserId: currentUserId)
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
    /// `alsoFromDevice`: once the server accepted, the copies this device
    /// still holds are deleted from Photos too (which asks the user).
    @MainActor
    func deleteSelected(currentUserId: String?) async {
        await deleteSelected(currentUserId: currentUserId, alsoFromDevice: false)
    }

    /// The selection deleted from the server, then the copies this device
    /// still holds from Photos.
    @MainActor
    func deleteSelectedEverywhere(currentUserId: String?) async {
        await deleteSelected(currentUserId: currentUserId, alsoFromDevice: true)
    }

    @MainActor
    private func deleteSelected(currentUserId: String?, alsoFromDevice: Bool) async {
        let copies = alsoFromDevice ? deviceCopies(of: ownerScopedSelection(currentUserId: currentUserId).ids) : []
        var accepted = false
        await removeOwnedSelection(currentUserId: currentUserId, reportsSkipped: false) { ids in
            try await client.deleteAssets(ids: ids, force: false)
            accepted = true
        }
        if accepted, !copies.isEmpty { _ = await DeviceMedia.delete(localIdentifiers: copies) }
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

    // MARK: - Widget link target (L-28)

    /// Where a widget link to one photo lands.
    enum LinkedAssetResolution: Equatable {
        /// Open the viewer on `assets[index]`; `inTimeline` says the photo is
        /// part of the timeline (so the grid can scroll to it) rather than a
        /// lone photo the timeline does not hold.
        case open(assets: [AssetReactItem], index: Int, inTimeline: Bool)
        /// The server refuses or cannot be asked: nothing opens, nothing is
        /// said (the official client does the same), and nothing is retried.
        case unavailable
    }

    /// Resolves the photo a widget link names. One `GET /api/assets/{id}`
    /// decides whether it can be opened at all (deleted, or another account's:
    /// the server refuses); the grid is then asked for it, jumping to its day
    /// when it is not loaded.
    @MainActor
    func resolveLinkedAsset(id: String, day: String?) async -> LinkedAssetResolution {
        let dto: AssetResponseDto
        do {
            dto = try await client.getAsset(id: id)
        } catch {
            return .unavailable
        }
        // A first page in flight owns `items`: its result decides what is
        // loaded. A link that arrived before the grid started loading starts it.
        if let inFlight = firstPageTask {
            await inFlight.value
        } else if items.isEmpty {
            await load()
        }
        if let index = items.firstIndex(where: { $0.id == id }) {
            return .open(assets: items, index: index, inTimeline: true)
        }
        if let day, !day.isEmpty {
            await jump(toDay: day)
            if let index = items.firstIndex(where: { $0.id == id }) {
                return .open(assets: items, index: index, inTimeline: true)
            }
        }
        return .open(assets: [AssetReactItem(from: dto)], index: 0, inTimeline: false)
    }

    // MARK: - First page and startup reachability (L-28)

    /// How long the startup probe waits for the server before the empty Photos
    /// tab shows its error state. 2 s, not the 5 s of the official client: the
    /// error must be on screen within 3 s of the launch.
    static let reachabilityTimeout: TimeInterval = 2

    /// The first page in flight (`load()` / `refresh()`), `nil` when none.
    private var firstPageTask: Task<Void, Never>?
    /// Identifies the current first page: a replaced one must not write its
    /// late result over the new one.
    private var firstPageGeneration = 0

    @MainActor
    func refresh() async {
        exitSelectionMode()
        // "Try Again" replaces a first page still in flight.
        firstPageTask?.cancel()
        await startFirstPage()
    }

    @MainActor
    func load() async {
        // The view reappearing while the first page is in flight starts neither
        // a second page nor a second probe: it waits for the one running.
        if let inFlight = firstPageTask {
            await inFlight.value
            return
        }
        await startFirstPage()
    }

    /// Runs the first page. With nothing on screen a reachability probe runs
    /// beside it: a server that does not answer within `reachabilityTimeout`
    /// puts the error state on screen without cancelling the page — a server
    /// that is merely slow to connect still delivers its photos, which then
    /// replace the error. A server that answers the probe never shows the error
    /// early: the loading state lasts until the content or the page's own error.
    @MainActor
    private func startFirstPage() async {
        firstPageGeneration &+= 1
        let generation = firstPageGeneration
        isLoading = true
        loadErrorMessage = nil
        let page: Task<Void, Never> = Task { @MainActor [weak self] in
            await self?.runFirstPage(generation: generation)
        }
        firstPageTask = page
        var probe: Task<Void, Never>?
        if items.isEmpty {
            probe = Task { @MainActor [weak self] in
                await self?.probeReachability(generation: generation)
            }
        }
        await page.value
        probe?.cancel()
    }

    @MainActor
    private func runFirstPage(generation: Int) async {
        var thrownMessage: String?
        var failed = false
        do {
            try await reloadFirstPage(generation: generation)
            // The first month failed: `loadNextBucket` recorded its own message.
            failed = bucketIndex == 0 && !buckets.isEmpty
        } catch let e {
            failed = true
            thrownMessage = e.userFacingMessage
        }
        guard generation == firstPageGeneration else { return }
        if let thrownMessage {
            loadErrorMessage = thrownMessage
        } else if !failed {
            // Photos arrived after the probe's error: they replace it.
            loadErrorMessage = nil
        }
        isLoading = false
        firstPageTask = nil
    }

    @MainActor
    private func probeReachability(generation: Int) async {
        do {
            _ = try await client.ping(timeout: Self.reachabilityTimeout)
        } catch {
            // Only a server that did not answer (timeout, refusal, cut): any
            // reply, whatever its status, proves it is there.
            guard UserFacingError.from(error)?.family == .offline else { return }
            // The page finished first, or was replaced: nothing to say.
            guard !Task.isCancelled, generation == firstPageGeneration, firstPageTask != nil else { return }
            loadErrorMessage = UserFacingError.offlineMessage
            isLoading = false
        }
    }

    /// Re-fetches the bucket list and the first page. The shown items are only
    /// replaced once the first bucket has loaded: if that bucket fails or is
    /// cancelled, the photos already on screen stay (SP-1 / SP-5). The scrubber
    /// places are not restored: `buckets` already names the new list, and old
    /// places would point at months that are absent or wrong in it.
    @MainActor
    private func reloadFirstPage(generation: Int) async throws {
        supersedeJumps()
        let fetched = try await fetchBuckets()
        // Replaced while the list was in flight: the newer page owns the state.
        guard generation == firstPageGeneration else { throw CancellationError() }
        // A jump started while the list was in flight read the old one.
        supersedeJumps()
        buckets = fetched
        bucketIndex = 0
        upperBucketIndex = -1
        placeById = [:]
        topVisibleId = nil
        scrubPosition = nil
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

    /// A reload replaces any jump in flight and invalidates neighbour loads.
    private func supersedeJumps() {
        if scrubCache != nil { scrubCache = [:] }
        serverKeys = []
        jumpGeneration &+= 1
        activeJump = nil
        pendingJump = nil
        windowEpoch &+= 1
    }

    @MainActor
    func loadMore() async {
        guard !isLoading else { return }
        await loadNextBucket()
    }

    /// Teleports the timeline to a specific day: loads that day's month
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
        await jumpToMonth(at: index, fraction: 0)
    }

    /// The single entry point of every jump (date scrubber, VoiceOver,
    /// "view in timeline", "scroll to top" after a jump): loads month `index`
    /// alone, replacing the window, with exactly one `GET bucket`.
    /// - Returns: the id of the photo to put at the top of the grid — the first
    ///   of the month for `fraction == 0`, else the photo at that fraction of
    ///   the month in grid order — or `nil` when nothing changed (superseded,
    ///   failed, cancelled, empty month, unknown index).
    @MainActor
    @discardableResult
    func jumpToMonth(at index: Int, fraction: Double) async -> String? {
        guard buckets.indices.contains(index) else { return nil }
        jumpGeneration &+= 1
        let gen = jumpGeneration
        activeJump = gen
        isLoading = true
        pendingJump = nil
        let previous = scrubPosition
        scrubPosition = TimelineScrubPosition(monthIndex: index, fraction: fraction)
        let key = buckets[index].timeBucket
        do {
            let monthItems = try await fetchBucketForJump(key)
            // A newer jump or a reload owns the window now: touch nothing.
            guard gen == jumpGeneration else { return nil }
            activeJump = nil
            isLoading = false
            let zipped = monthItems
            if zipped.isEmpty {
                scrubPosition = previous
                return nil
            }
            windowEpoch &+= 1
            items = zipped
            loadedIds = Set(zipped.map(\.id))
            bucketIndex = index + 1
            upperBucketIndex = index - 1
            placeById = [:]
            recordPlaces(of: zipped, month: index)
            loadErrorMessage = nil
            let ordered = Self.gridOrdered(zipped)
            let anchor = ordered[TimelineScrubberMath.anchorRank(fraction: fraction, count: ordered.count)].id
            topVisibleId = anchor
            return anchor
        } catch let e {
            guard gen == jumpGeneration else { return nil }
            activeJump = nil
            isLoading = false
            scrubPosition = previous
            if let message = e.userFacingMessage {
                loadErrorMessage = message
                pendingJump = PendingJump(timeBucket: key, fraction: fraction)
            }
            return nil
        }
    }

    /// "Try Again" of the error banner: a failed jump reloads its month only
    /// (one `GET bucket`, no `GET buckets`); any other failure refreshes.
    @MainActor
    @discardableResult
    func retryLoad() async -> String? {
        if let pending = pendingJump,
           let index = buckets.firstIndex(where: { $0.timeBucket == pending.timeBucket }) {
            loadErrorMessage = nil
            return await jumpToMonth(at: index, fraction: pending.fraction)
        }
        await refresh()
        return nil
    }

    /// Records the topmost visible photo reported by the scroll view as the
    /// scrubber's resting position. Takes the minimum `(month, rank)` of the
    /// ids it knows — the order of `visibleIds` is not documented — and only
    /// writes when the position changes.
    func updateScrubPosition(visibleIds: [String]) {
        var best: (month: Int, rank: Int, id: String)?
        for id in visibleIds {
            guard let place = placeById[id], buckets.indices.contains(place.month) else { continue }
            if let current = best, (current.month, current.rank) <= (place.month, place.rank) { continue }
            best = (place.month, place.rank, id)
        }
        guard let best else { return }
        topVisibleId = best.id
        let count = Double(max(buckets[best.month].count, 1))
        let position = TimelineScrubPosition(
            monthIndex: best.month,
            fraction: min(Double(best.rank) / count, 1.0.nextDown)
        )
        if position != scrubPosition { scrubPosition = position }
    }

    /// Loads the bucket immediately NEWER than the current top (used when the
    /// user scrolls up after a jump). Prepends so the timeline stays sorted
    /// newest-first.
    @MainActor
    func loadNewer() async {
        guard !isLoading, upperBucketIndex >= 0, buckets.indices.contains(upperBucketIndex) else { return }
        isLoading = true
        // A jump that started meanwhile owns `isLoading`.
        defer { if activeJump == nil { isLoading = false } }
        let epoch = windowEpoch
        let index = upperBucketIndex
        let key = buckets[index].timeBucket
        do {
            let zipped = try await fetchMonthItems(key)
            guard epoch == windowEpoch, upperBucketIndex == index, bucketIsCurrent(index, key) else { return }
            let newItems = zipped.filter { !loadedIds.contains($0.id) }
            items.insert(contentsOf: newItems, at: 0)
            loadedIds.formUnion(newItems.map(\.id))
            pruneDeviceDuplicates()
            recordPlaces(of: zipped, month: index)
            upperBucketIndex -= 1
        } catch let e {
            guard epoch == windowEpoch, upperBucketIndex == index, bucketIsCurrent(index, key) else { return }
            loadErrorMessage = e.userFacingMessage
        }
    }

    @MainActor
    private func loadNextBucket() async {
        guard bucketIndex < buckets.count else { return }
        let epoch = windowEpoch
        let index = bucketIndex
        let key = buckets[index].timeBucket
        do {
            // AC-013: the month's columns zipped into objects, with this
            // device's photos of the month folded in.
            let zipped = try await fetchMonthItems(key)
            // The window may have been replaced during the await (a jump, a
            // reload): then this month no longer belongs after its end.
            guard epoch == windowEpoch, bucketIndex == index, bucketIsCurrent(index, key) else { return }
            for item in zipped where !loadedIds.contains(item.id) {
                items.append(item)
                loadedIds.insert(item.id)
            }
            pruneDeviceDuplicates()
            recordPlaces(of: zipped, month: index)
            bucketIndex += 1
        } catch let e {
            guard epoch == windowEpoch, bucketIndex == index, bucketIsCurrent(index, key) else { return }
            loadErrorMessage = e.userFacingMessage
        }
    }

    private func bucketIsCurrent(_ index: Int, _ key: String) -> Bool {
        buckets.indices.contains(index) && buckets[index].timeBucket == key
    }

    /// The order the grid draws a month in: newest first.
    private static func gridOrdered(_ items: [AssetReactItem]) -> [AssetReactItem] {
        items.sorted { $0.fileCreatedAt > $1.fileCreatedAt }
    }

    private func recordPlaces(of items: [AssetReactItem], month: Int) {
        for (rank, item) in Self.gridOrdered(items).enumerated() {
            placeById[item.id] = (month: month, rank: rank)
        }
    }

    /// The single place listing the filters of `GET /api/timeline/buckets`.
    /// With a device source, the device half is read here too and its months
    /// folded into the list (`MergedTimeline.buckets`).
    @MainActor
    private func fetchBuckets() async throws -> [TimeBucketsResponseDto] {
        let server = try await client.getTimeBuckets(isFavorite: filterIsFavorite, isTrashed: filterIsTrashed, personId: nil, withPartners: filterWithPartners, visibility: filterVisibility, withStacked: withStacked, orderBy: nil)
        serverMonths = Set(server.map { MergedTimeline.monthKey($0.timeBucket) })
        let device = await deviceItems()
        deviceItemsByMonth = Dictionary(grouping: device) { MergedTimeline.monthKey($0.fileCreatedAt) }
        deviceItemIDs = Set(device.map(\.id))
        return MergedTimeline.buckets(server: server, deviceCounts: deviceItemsByMonth.mapValues(\.count))
    }

    /// The device half for the current filter: nothing without a source, with
    /// the switch off, or under Archived (a device photo is never archived);
    /// its favorites alone under Favorites.
    ///
    /// A photo the ledger does not know is still never shown twice: the month
    /// merge recognises the server's copy by its capture time
    /// (`MergedTimeline.dedupeKey`), so the device half needs no backup pass
    /// to be right — it is the whole library from the first launch.
    @MainActor
    private func deviceItems() async -> [AssetReactItem] {
        guard let deviceSource, filter != .archived, showsDeviceAssets() else { return [] }
        return await deviceSource.deviceOnlyItems(excluding: uploadedDeviceIDs(), favoritesOnly: filter == .favorites)
    }

    /// Back in the foreground: the library may have changed behind the app (a
    /// photo taken, one deleted in Photos, one backed up). Reloads only when
    /// the device half is no longer the one on screen.
    @MainActor
    func refreshIfDeviceLibraryChanged() async {
        guard deviceSource != nil, firstPageTask == nil, !isLoading else { return }
        let device = await deviceItems()
        let ids = Set(device.map(\.id))
        guard ids != deviceItemIDs else { return }
        await refresh()
    }

    /// One month's items: the server's (zipped) and the device's, newest
    /// first. A month only the device has is not asked of the server.
    @MainActor
    private func fetchMonthItems(_ timeBucket: String) async throws -> [AssetReactItem] {
        let month = MergedTimeline.monthKey(timeBucket)
        let device = deviceItemsByMonth[month] ?? []
        if !device.isEmpty, !serverMonths.contains(month) {
            return MergedTimeline.items(server: [], device: device, serverKeys: serverKeys)
        }
        let server = AssetReactItem.zip(try await fetchBucket(timeBucket))
        let merged = MergedTimeline.items(server: server, device: device, serverKeys: serverKeys)
        serverKeys.formUnion(server.map(MergedTimeline.dedupeKey))
        return merged
    }

    /// A server month just loaded may hold the server copy of a device photo
    /// shown by an earlier month (the two halves do not always file a photo
    /// taken near midnight on the 1st under the same month): that device
    /// photo leaves the grid.
    @MainActor
    private func pruneDeviceDuplicates() {
        guard deviceSource != nil, !serverKeys.isEmpty else { return }
        let duplicates = Set(items.lazy
            .filter { $0.isDeviceOnly && self.serverKeys.contains(MergedTimeline.dedupeKey($0)) }
            .map(\.id))
        guard !duplicates.isEmpty else { return }
        items.removeAll { duplicates.contains($0.id) }
        loadedIds.subtract(duplicates)
    }

    /// The single place listing the filters of `GET /api/timeline/bucket`:
    /// the same ones as `fetchBuckets()`, or the server applies its defaults
    /// to the month (e.g. non-favorites slip into the Favorites filter).
    @MainActor
    /// Opens a scrub: the months fetched until `endScrubbing()` are kept.
    func beginScrubbing() {
        if scrubCache == nil { scrubCache = [:] }
    }

    /// Closes the scrub and drops the months it kept.
    func endScrubbing() {
        scrubCache = nil
    }

    /// A jump's month: from the scrub cache when the gesture already fetched
    /// it, else from the server (and kept while a scrub is open).
    @MainActor
    private func fetchBucketForJump(_ timeBucket: String) async throws -> [AssetReactItem] {
        if let cached = scrubCache?[timeBucket] { return cached }
        let monthItems = try await fetchMonthItems(timeBucket)
        if scrubCache != nil { scrubCache?[timeBucket] = monthItems }
        return monthItems
    }

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
        let computed = TimelineSectionBuilder.groupedByDay(items)
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
    /// Deletes one server photo, and — `alsoFromDevice` — the copy this device
    /// still holds, once the server accepted (Photos asks the user).
    @MainActor
    @discardableResult
    func delete(id: String, alsoFromDevice: Bool) async -> Bool {
        let copies = alsoFromDevice ? deviceCopies(of: [id]) : []
        guard await delete(id: id) else { return false }
        if !copies.isEmpty { _ = await DeviceMedia.delete(localIdentifiers: copies) }
        return true
    }

    @MainActor
    @discardableResult
    func delete(id: String) async -> Bool {
        // A device-only photo: Photos deletes it (and asks the user first).
        // Already gone from the library (the viewer deleted it) counts as done.
        if let deviceID = AssetReactItem.deviceAssetID(fromID: id) {
            guard await DeviceMedia.delete(localIdentifiers: [deviceID]) else { return false }
            items.removeAll { $0.id == id }
            loadedIds.remove(id)
            deviceItemIDs.remove(id)
            return true
        }
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
    ///
    /// - Parameter refreshing: `false` for a host that is not the timeline
    ///   (the search results): the caller re-reads its own list, and this
    ///   view model must not replace its `items` with timeline buckets.
    @MainActor
    func stackSelected(currentUserId: String?, refreshing: Bool) async {
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
            if refreshing { await refresh() }
        } catch let e {
            actionErrorMessage = e.userFacingMessage
        }
    }

    /// The shared selection bar's stack action: the timeline re-reads itself
    /// afterwards. A defaulted `refreshing` would not satisfy the protocol's
    /// requirement, hence this explicit overload.
    @MainActor
    func stackSelected(currentUserId: String?) async {
        await stackSelected(currentUserId: currentUserId, refreshing: true)
    }
}

extension TimelineViewModel: BatchSelectionModel {
    /// The selection in grid order, not `Set` order (a download's file order).
    var selectedItems: [AssetReactItem] { items.filter { selectedIds.contains($0.id) } }
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

extension TimelineViewModel: ReloadableScreen {
    /// Only the failure of the timeline read counts, never an action's (L-26).
    var hasLoadError: Bool { loadErrorMessage != nil }
}
