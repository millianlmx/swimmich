import Foundation

/// The library of one partner who shares with the user (L-08), newest first, a
/// time bucket at a time.
///
/// Source: the timeline routes with `userId` — the server decides what another
/// account may show (`visibility=timeline` only, no favorites, no trash).
/// `withPartners` is never sent: combined with `userId` it would add the
/// user's other partners to the list. `visibility` is always explicit and every
/// filter is repeated on `timeline/bucket`. Each push creates its own instance.
///
/// `load()` never touches what is on screen before it has something to replace
/// it with: a reload that fails keeps the photos and only posts the error.
@MainActor
@Observable
final class PartnerLibraryViewModel {
    let partnerId: String
    let partnerName: String
    private let client: any ImmichClient

    /// The photos in grid order — also the viewer's paging order.
    private(set) var items: [AssetReactItem] = []
    /// `items` cut into days, computed when photos are added, never in `body`.
    private(set) var groupedByDay: [(day: String, items: [AssetReactItem])] = []
    private(set) var isLoading = false
    /// True while `refresh()` runs: the system's refresh control is the
    /// indicator then, not the screen's own.
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    /// True once a bucket list was read and applied.
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    /// A failed (re)load. The grid stays when it has photos.
    private(set) var errorMessage: String?
    /// A failed later page: the grid stays, the footer offers a retry.
    private(set) var loadMoreErrorMessage: String?
    /// Months already read: the identity of the pagination sentinel.
    private(set) var loadedBucketCount = 0

    private var buckets: [TimeBucketsResponseDto] = []
    private var bucketIndex = 0
    private var loadedIds: Set<String> = []
    /// Bumped by every reload that replaces the list, so a page still in
    /// flight cannot write into a newer one.
    private var generation = 0

    init(client: any ImmichClient, partnerId: String, partnerName: String) {
        self.client = client
        self.partnerId = partnerId
        self.partnerName = partnerName
    }

    /// First load, "Try Again" and pull-to-refresh: restarts from the bucket list.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        loadMoreErrorMessage = nil
        defer { isLoading = false }
        do {
            let fetched = try await client.getTimeBuckets(
                isFavorite: nil,
                isTrashed: nil,
                personId: nil,
                withPartners: nil,
                visibility: "timeline",
                withStacked: nil,
                orderBy: nil,
                tagId: nil,
                userId: partnerId
            )
            // Read into a provisional state: the screen keeps showing what it
            // has until the first period of the new list has arrived.
            var index = 0
            var seen: Set<String> = []
            var fresh: [AssetReactItem] = []
            while index < fetched.count, fresh.isEmpty {
                let unseen = try await readBucket(fetched[index].timeBucket).filter { !seen.contains($0.id) }
                seen.formUnion(unseen.map(\.id))
                fresh.append(contentsOf: unseen)
                index += 1
            }
            generation += 1
            buckets = fetched
            loadedIds = seen
            bucketIndex = index
            hasLoaded = true
            hasMore = index < fetched.count
            loadedBucketCount = index
            setItems(fresh)
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Pull-to-refresh: `load()` flagged so the screen knows the system's
    /// refresh control is the indicator.
    func refresh() async {
        isRefreshing = true
        await load()
        isRefreshing = false
    }

    /// Appends the next period that holds photos.
    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreErrorMessage = nil
        await appendNextNonEmptyBucket()
        isLoadingMore = false
    }

    /// The sections the grid renders for the user's "Group By" preference.
    func sections(groupBy: TimelineGroupBy) -> [TimelineSectionBuilder.Section] {
        TimelineSectionBuilder.build(from: groupedByDay, groupBy: groupBy)
    }

    /// Reads buckets until one adds a photo: an empty period never ends the paging.
    private func appendNextNonEmptyBucket() async {
        let started = generation
        var added = false
        while bucketIndex < buckets.count, !added {
            do {
                let columnar = try await readBucket(buckets[bucketIndex].timeBucket)
                guard started == generation else { return }
                let unseen = columnar.filter { !loadedIds.contains($0.id) }
                loadedIds.formUnion(unseen.map(\.id))
                if !unseen.isEmpty { setItems(items + unseen) }
                added = !unseen.isEmpty
                bucketIndex += 1
            } catch {
                guard started == generation else { return }
                loadMoreErrorMessage = error.userFacingMessage
                break
            }
        }
        if started == generation {
            hasMore = bucketIndex < buckets.count
            loadedBucketCount = bucketIndex
        }
    }

    /// One period of the partner's library, same filters as the bucket list.
    private func readBucket(_ timeBucket: String) async throws -> [AssetReactItem] {
        let columnar = try await client.getTimeBucket(
            timeBucket: timeBucket,
            isFavorite: nil,
            isTrashed: nil,
            personId: nil,
            withPartners: nil,
            visibility: "timeline",
            withStacked: nil,
            orderBy: nil,
            tagId: nil,
            userId: partnerId
        )
        return AssetReactItem.zip(columnar)
    }

    private func setItems(_ all: [AssetReactItem]) {
        groupedByDay = TimelineSectionBuilder.groupedByDay(all)
        items = groupedByDay.flatMap(\.items)
    }
}
