import Foundation
import Observation

/// One day of a "recent" grid: the bucket key (`TimeBucketsResponseDto.timeBucket`,
/// already an ISO day) plus the items it holds.
///
/// `title` is formatted **here**, not in the view: the day labels are the
/// timeline's (`DateHeaderFormatter`), and a second formatting site would drift
/// from "Today"/"Yesterday" the day a locale changes.
struct RecentDayGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [AssetReactItem]
}

/// Read-only, day-paginated grid behind both "recent" consult screens (G13).
///
/// Two instances (one per `RecentAssetsMode`) share nothing — no process-wide
/// singleton, no shared cache: the two sort axes are independent scrolls from
/// independent bucket lists.
///
/// `orderBy: mode.orderBy` reaches the server. That matters: `GET
/// /api/timeline/buckets` is the only route that can sort by upload date — a
/// metadata search has no such order field — so "recently added" is
/// `orderBy=createdAt` and cannot be emulated by the search route.
///
/// Pagination goes **down**: each `loadMore()` fetches the next older bucket and
/// appends it at the END of `dayGroups`. The timeline does the opposite (it
/// prepends, because it scrolls up into newer days); reusing its direction here
/// would invert the order as the user scrolls.
@MainActor
@Observable
final class RecentAssetsViewModel {
    let mode: RecentAssetsMode
    private let client: any ImmichClient

    /// Loaded days, newest first.
    private(set) var dayGroups: [RecentDayGroup] = []
    /// True while the list of days and its first day are being read (drives
    /// the skeleton grid).
    private(set) var isLoading = false
    /// True while `refresh()` runs: the system's refresh control is the
    /// indicator then, not the screen's own.
    private(set) var isRefreshing = false
    /// True once the list of days and its first day were read and applied.
    private(set) var hasLoaded = false
    /// True while an older day is being fetched (drives the footer sentinel).
    private(set) var isLoadingMore = false
    /// Failure of the last read (the first day or an older one), cleared by a
    /// success. The grid is never touched by it.
    private(set) var errorMessage: String?
    /// False once the last requested bucket came back empty, or once the bucket
    /// list itself is exhausted.
    private(set) var hasMore = true

    private var buckets: [TimeBucketsResponseDto] = []
    private var bucketIndex = 0
    private var loadedIds: Set<String> = []
    /// Bumped by every `load()`, so only the last read writes its result.
    private var loadGeneration = 0

    init(client: any ImmichClient, mode: RecentAssetsMode) {
        self.client = client
        self.mode = mode
    }

    /// What the screen renders.
    var renderState: ListRenderState {
        .resolve(
            isEmpty: dayGroups.isEmpty,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            loadError: errorMessage
        )
    }

    /// Reads the bucket list for this mode, then the newest day, in a
    /// provisional state: the grid on screen is replaced only when both
    /// arrived (`.task` and "Try Again", never a pull).
    ///
    /// `withStacked: true` matches the timeline (and `AssetThumbnailCell`'s
    /// "+N" badge, which only exists for a request that asked for primaries).
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        // A page still in flight is dropped by the generation guard; its own
        // `defer` no longer clears the flag, so a failing read would leave it set.
        isLoadingMore = false
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let fetched = try await client.getTimeBuckets(
                isFavorite: nil,
                isTrashed: nil,
                personId: nil,
                withPartners: nil,
                visibility: nil,
                withStacked: true,
                orderBy: mode.orderBy
            )
            guard generation == loadGeneration else { return }
            var firstGroup: RecentDayGroup?
            var more = false
            if !fetched.isEmpty {
                let day = try await fetchDay(buckets: fetched, index: 0, loadedIds: [])
                guard generation == loadGeneration else { return }
                firstGroup = day.group
                more = day.hasMore
            }
            buckets = fetched
            bucketIndex = fetched.isEmpty ? 0 : 1
            loadedIds = Set(firstGroup?.items.map(\.id) ?? [])
            dayGroups = firstGroup.map { [$0] } ?? []
            isLoadingMore = false
            hasMore = more
            hasLoaded = true
            errorMessage = nil
        } catch let e {
            guard generation == loadGeneration, let message = e.userFacingMessage else { return }
            errorMessage = message
        }
    }

    /// Pull-to-refresh: a full reload, because the bucket list itself changes
    /// when photos are uploaded — patching the loaded days would miss new ones.
    func refresh() async {
        isRefreshing = true
        await load()
        isRefreshing = false
    }

    /// Appends the next older day. No-op once `hasMore` is false. A failure
    /// keeps the loaded grid intact and surfaces `errorMessage` — the footer
    /// sentinel then simply retries on next appear.
    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        guard bucketIndex < buckets.count else {
            hasMore = false
            return
        }
        isLoadingMore = true
        let generation = loadGeneration
        defer { if generation == loadGeneration { isLoadingMore = false } }
        do {
            let day = try await fetchDay(buckets: buckets, index: bucketIndex, loadedIds: loadedIds)
            guard generation == loadGeneration else { return }
            if let group = day.group {
                loadedIds.formUnion(group.items.map(\.id))
                dayGroups.append(group)
            }
            bucketIndex += 1
            hasMore = day.hasMore
            errorMessage = nil
        } catch let e {
            guard generation == loadGeneration, let message = e.userFacingMessage else { return }
            errorMessage = message
        }
    }

    /// Fetches one bucket and returns its unseen items as a day group, without
    /// touching any state.
    private func fetchDay(
        buckets: [TimeBucketsResponseDto],
        index: Int,
        loadedIds: Set<String>
    ) async throws -> (group: RecentDayGroup?, hasMore: Bool) {
        let bucket = buckets[index]
        let columnar = try await client.getTimeBucket(
            timeBucket: bucket.timeBucket,
            isFavorite: nil,
            isTrashed: nil,
            personId: nil,
            withPartners: nil,
            visibility: nil,
            withStacked: true,
            orderBy: mode.orderBy
        )
        let zipped = AssetReactItem.zip(columnar)
        let unseen = zipped.filter { !loadedIds.contains($0.id) }
        let group = unseen.isEmpty ? nil : RecentDayGroup(
            id: bucket.timeBucket,
            title: DateHeaderFormatter.displayString(for: bucket.timeBucket),
            items: unseen
        )
        return (group, index + 1 < buckets.count && !zipped.isEmpty)
    }
}
