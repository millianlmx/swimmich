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
    /// True once the bucket list was read; the screen then shows empty/error/grid.
    private(set) var hasLoaded = false
    private(set) var hasMore = false
    /// A failed first load (nothing on screen yet).
    private(set) var errorMessage: String?
    /// A failed later page: the grid stays, the footer offers a retry.
    private(set) var loadMoreErrorMessage: String?

    private var buckets: [TimeBucketsResponseDto] = []
    private var bucketIndex = 0
    private var loadedIds: Set<String> = []
    /// Bumped by every reset, so a page still in flight cannot write into a newer list.
    private var generation = 0

    init(client: any ImmichClient, tagId: String, tagName: String) {
        self.client = client
        self.tagId = tagId
        self.tagName = tagName
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
                tagId: tagId
            )
            generation += 1
            buckets = fetched
            items = []
            loadedIds = []
            bucketIndex = 0
            hasLoaded = true
            await loadNextNonEmptyBucket()
        } catch {
            errorMessage = error.userFacingMessage
        }
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
                if items.isEmpty {
                    errorMessage = error.userFacingMessage
                } else {
                    loadMoreErrorMessage = error.userFacingMessage
                }
                break
            }
        }
        if started == generation { hasMore = bucketIndex < buckets.count }
    }
}
