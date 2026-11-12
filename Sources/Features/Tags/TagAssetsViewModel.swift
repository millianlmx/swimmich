import Foundation

/// The photos of one tag, newest first, a time bucket at a time.
///
/// Source: the timeline routes with `tagId` — the server attaches a tag's
/// descendants' photos to it, so nothing is computed here. `visibility` is
/// always explicit and every filter is repeated on `timeline/bucket`.
/// Each push creates its own instance: nothing is shared between tags.
@MainActor
@Observable
final class TagAssetsViewModel {
    let tagId: String
    let tagName: String
    private let client: any ImmichClient

    private(set) var items: [AssetReactItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    /// True once the first page was read and applied; the screen then shows
    /// empty/error/grid.
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    /// True while `refresh()` runs: the system's refresh control is the
    /// indicator then, not the screen's own.
    private(set) var isRefreshing = false
    /// Failure of the last read of the first page, cleared by a success. The
    /// photos already on screen stay.
    private(set) var loadErrorMessage: String?
    /// A failed later page: the grid stays, the footer offers a retry.
    private(set) var loadMoreErrorMessage: String?

    private var buckets: [TimeBucketsResponseDto] = []
    private var bucketIndex = 0
    private var loadedIds: Set<String> = []
    /// Bumped by every `load()`, so only the last read writes its result and a
    /// page still in flight cannot write into a newer list.
    private var generation = 0

    init(client: any ImmichClient, tagId: String, tagName: String) {
        self.client = client
        self.tagId = tagId
        self.tagName = tagName
    }

    /// What the grid renders.
    var renderState: ListRenderState {
        .resolve(
            isEmpty: items.isEmpty,
            hasLoaded: hasLoaded,
            isLoading: isLoading,
            isRefreshing: isRefreshing,
            loadError: loadErrorMessage
        )
    }

    /// First read, "Try Again" and `.task` (never pulls): restarts from the
    /// bucket list. The bucket list and the first non-empty period are read
    /// into locals and applied at once, so the photos on screen stay until the
    /// answer; a failure or a newer read leaves them alone.
    func load() async {
        generation += 1
        let started = generation
        isLoading = true
        defer { if started == generation { isLoading = false } }
        do {
            let fetched = try await client.getTimeBuckets(
                isFavorite: nil,
                isTrashed: nil,
                personId: nil,
                withPartners: nil,
                visibility: "timeline",
                withStacked: nil,
                orderBy: nil,
                tagId: tagId
            )
            guard started == generation else { return }
            var index = 0
            var firstItems: [AssetReactItem] = []
            var firstIds: Set<String> = []
            while index < fetched.count, firstItems.isEmpty {
                let columnar = try await client.getTimeBucket(
                    timeBucket: fetched[index].timeBucket,
                    isFavorite: nil,
                    isTrashed: nil,
                    personId: nil,
                    withPartners: nil,
                    visibility: "timeline",
                    withStacked: nil,
                    orderBy: nil,
                    tagId: tagId
                )
                guard started == generation else { return }
                firstItems = AssetReactItem.zip(columnar).filter { !firstIds.contains($0.id) }
                firstIds.formUnion(firstItems.map(\.id))
                index += 1
            }
            buckets = fetched
            bucketIndex = index
            items = firstItems
            loadedIds = firstIds
            hasMore = index < fetched.count
            hasLoaded = true
            loadErrorMessage = nil
            loadMoreErrorMessage = nil
        } catch {
            guard started == generation, let message = error.userFacingMessage else { return }
            loadErrorMessage = message
        }
    }

    /// Pull-to-refresh: `load()` flagged so the screen keeps its current
    /// rendering.
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
        await loadNextNonEmptyBucket()
        isLoadingMore = false
    }

    /// A photo deleted from the viewer leaves the grid.
    func remove(assetId: String) {
        items.removeAll { $0.id == assetId }
    }

    /// Reads buckets until one adds a photo: an empty period never ends the paging.
    private func loadNextNonEmptyBucket() async {
        let started = generation
        var added = false
        while bucketIndex < buckets.count, !added {
            do {
                let columnar = try await client.getTimeBucket(
                    timeBucket: buckets[bucketIndex].timeBucket,
                    isFavorite: nil,
                    isTrashed: nil,
                    personId: nil,
                    withPartners: nil,
                    visibility: "timeline",
                    withStacked: nil,
                    orderBy: nil,
                    tagId: tagId
                )
                guard started == generation else { return }
                let unseen = AssetReactItem.zip(columnar).filter { !loadedIds.contains($0.id) }
                loadedIds.formUnion(unseen.map(\.id))
                items.append(contentsOf: unseen)
                added = !unseen.isEmpty
                bucketIndex += 1
            } catch {
                guard started == generation else { return }
                loadMoreErrorMessage = error.userFacingMessage
                break
            }
        }
        if started == generation { hasMore = bucketIndex < buckets.count }
    }
}
