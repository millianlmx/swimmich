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
    /// True while the first day is being fetched (drives the skeleton grid).
    private(set) var isLoading = false
    /// True while an older day is being fetched (drives the footer sentinel).
    private(set) var isLoadingMore = false
    /// Set by a failed load; the screen replays `refresh()`.
    private(set) var errorMessage: String?
    /// False once the last requested bucket came back empty, or once the bucket
    /// list itself is exhausted.
    private(set) var hasMore = true

    private var buckets: [TimeBucketsResponseDto] = []
    private var bucketIndex = 0
    private var loadedIds: Set<String> = []

    init(client: any ImmichClient, mode: RecentAssetsMode) {
        self.client = client
        self.mode = mode
    }

    /// Loads the bucket list for this mode, then the newest day.
    ///
    /// `withStacked: true` matches the timeline (and `AssetThumbnailCell`'s
    /// "+N" badge, which only exists for a request that asked for primaries).
    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            buckets = try await client.getTimeBuckets(
                isFavorite: nil,
                isTrashed: nil,
                personId: nil,
                withPartners: nil,
                visibility: nil,
                withStacked: true,
                orderBy: mode.orderBy
            )
            bucketIndex = 0
            loadedIds = []
            dayGroups = []
            hasMore = true
            await loadNextBucket()
        } catch let e {
            errorMessage = e.userFacingMessage
        }
        isLoading = false
    }

    /// Pull-to-refresh: a full reload, because the bucket list itself changes
    /// when photos are uploaded — patching the loaded days would miss new ones.
    func refresh() async {
        await load()
    }

    /// Appends the next older day. No-op once `hasMore` is false.
    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        await loadNextBucket()
        isLoadingMore = false
    }

    /// Fetches one bucket, appends its unseen items as a new day group, and
    /// advances the cursor. A throw keeps the loaded grid intact and surfaces
    /// `errorMessage` — the footer sentinel then simply retries on next appear.
    private func loadNextBucket() async {
        guard bucketIndex < buckets.count else {
            hasMore = false
            return
        }
        let bucket = buckets[bucketIndex]
        do {
            let columnar = try await client.getTimeBucket(
                timeBucket: bucket.timeBucket,
                personId: nil,
                withPartners: nil,
                visibility: nil,
                withStacked: true
            )
            let zipped = AssetReactItem.zip(columnar)
            let unseen = zipped.filter { !loadedIds.contains($0.id) }
            if !unseen.isEmpty {
                loadedIds.formUnion(unseen.map(\.id))
                dayGroups.append(
                    RecentDayGroup(
                        id: bucket.timeBucket,
                        title: DateHeaderFormatter.displayString(for: bucket.timeBucket),
                        items: unseen
                    )
                )
            }
            bucketIndex += 1
            hasMore = bucketIndex < buckets.count && !zipped.isEmpty
        } catch let e {
            errorMessage = e.userFacingMessage
        }
    }
}
