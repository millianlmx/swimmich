import Foundation
import Observation

/// Drives the offline cache from the UI: the storage screen, the viewer's
/// "Download for Offline" action and the badge index.
///
/// It owns no transport of its own — every byte and every index mutation goes
/// through `OfflineAssetStore`, which is the single source of truth on disk.
/// It is bound to one account at construction (`accountID`): a view model that
/// outlives a switch of account touches neither that account's files nor the
/// shared mirror (`OfflineAssetIndex`) it no longer owns. After each mutation
/// the mirror is refreshed, because the timeline badge reads it.
@MainActor
@Observable
final class OfflineDownloadViewModel {
    private let store: OfflineAssetStore
    private let client: any ImmichClient
    let index: OfflineAssetIndex
    /// `SavedAccount.id` this view model acts for: every mutation is refused by
    /// the store once another account (or none) is active.
    let accountID: String

    /// Cached assets, most recent first — the storage screen's list.
    private(set) var cachedAssets: [CachedAssetInfo] = []
    /// Bytes currently held on disk.
    private(set) var cacheUsage: Int64 = 0
    /// Configured budget in bytes (`0` = unlimited).
    private(set) var maxCacheSize: Int64 = OfflineAssetStore.defaultMaxCacheSize
    private(set) var errorMessage: String?
    /// Asset that most recently finished downloading — drives the success haptic.
    private(set) var lastDownloadedID: String?

    // MARK: - Listing state (L-16)

    /// A read of the cache folder is in flight.
    private(set) var isLoadingListing = false
    /// A read has succeeded at least once.
    private(set) var hasLoadedListing = false
    /// Why the last read of the folder failed; cleared by a successful read.
    /// Never written by a download or a removal: those use `errorMessage`.
    private(set) var listingErrorMessage: String?
    /// The read in flight comes from a pull-to-refresh.
    private(set) var isRefreshingListing = false
    private var listingGeneration = 0

    /// How the last purge ended, for the alert the three storage screens show.
    private(set) var purgeResult: OfflinePurgeResult?
    private var refreshCount = 0

    /// What the storage screens render, decided here and not in the views.
    var listingState: ListRenderState {
        .resolve(
            isEmpty: cachedAssets.isEmpty,
            hasLoaded: hasLoadedListing,
            isLoading: isLoadingListing,
            isRefreshing: isRefreshingListing,
            loadError: listingErrorMessage
        )
    }

    var searchQuery: String = ""

    /// Per-asset download state. Observed on purpose: the share sheet reads
    /// both to decide between a spinner and a download button.
    private var progressByID: [String: Double] = [:]
    private var downloadingIDs: Set<String> = []

    init(store: OfflineAssetStore, client: any ImmichClient, index: OfflineAssetIndex, accountID: String) {
        self.store = store
        self.client = client
        self.index = index
        self.accountID = accountID
    }

    // MARK: - Derived state

    /// Cached assets matching the search field. Matches on the same fields the
    /// screen shows, so what's typed is what's filtered.
    var filteredAssets: [CachedAssetInfo] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return cachedAssets }
        return cachedAssets.filter {
            $0.displayName.lowercased().contains(query) || $0.fileCreatedAt.lowercased().contains(query)
        }
    }

    var isFull: Bool {
        maxCacheSize > 0 && cacheUsage >= maxCacheSize
    }

    /// Fraction of the budget in use; `nil` when the budget is unlimited (the
    /// ring then shows an empty track instead of a meaningless fraction).
    var usageFraction: Double? {
        guard maxCacheSize > 0 else { return nil }
        return min(1, Double(cacheUsage) / Double(maxCacheSize))
    }

    func formattedUsage(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func isCached(_ assetID: String) -> Bool { index.isCached(assetID) }

    func isDownloading(_ assetID: String) -> Bool { downloadingIDs.contains(assetID) }

    /// 0...1 while downloading, `nil` when idle or when the server sent no
    /// `Content-Length` (the bar is then indeterminate).
    func progress(for assetID: String) -> Double? { progressByID[assetID] }

    // MARK: - Loading

    /// Reads the folder on disk. Without a pull: the `.task` and every
    /// "Try Again" call this. The cache is only replaced when the read
    /// succeeds; a failure sets `listingErrorMessage` and keeps what is shown.
    func load() async {
        maxCacheSize = await store.maxCacheSize
        await reload()
    }

    /// Pull-to-refresh: the same read, flagged so the screen keeps its current
    /// rendering (empty, error or files) while the system control spins.
    func refresh() async {
        refreshCount += 1
        isRefreshingListing = true
        defer {
            refreshCount -= 1
            isRefreshingListing = refreshCount > 0
        }
        await load()
    }

    private func reload() async {
        listingGeneration += 1
        let generation = listingGeneration
        isLoadingListing = true
        defer { if generation == listingGeneration { isLoadingListing = false } }
        do {
            let listing = try await store.listing()
            guard generation == listingGeneration else { return }
            let mine = listing.accountID == accountID
            cachedAssets = mine ? listing.items : []
            cacheUsage = mine ? listing.totalBytes : 0
            maxCacheSize = await store.maxCacheSize
            index.apply(listing, from: store)
            hasLoadedListing = true
            listingErrorMessage = nil
        } catch {
            // A cancelled read (the view left) changes nothing.
            guard generation == listingGeneration, let message = error.userFacingMessage else { return }
            listingErrorMessage = message
        }
    }

    // MARK: - Download

    /// Downloads the asset's original into the cache of `accountID`. When that
    /// account is no longer the active one — at the start or when the transfer
    /// ends — the store refuses or drops the download and it ends silently.
    ///
    /// Credentials are per-call: the server may change while this view model
    /// (bound to one account) lives, so it cannot hold them.
    ///
    /// `edited` (L-21): the copy follows the version the app displays. `true` (the default) asks for the
    /// server's edited rendering — the original for a photo without edits; `false` is for the
    /// re-download after the edits were removed. The file keeps its path: the screens re-read it through
    /// `OfflineAssetIndex` (`cachedAt` changes with each download).
    func downloadAsset(_ asset: AssetReactItem, baseURL: URL, token: String?, edited: Bool = true) async {
        guard !downloadingIDs.contains(asset.id) else { return }
        downloadingIDs.insert(asset.id)
        progressByID[asset.id] = 0
        errorMessage = nil
        defer {
            downloadingIDs.remove(asset.id)
            progressByID[asset.id] = nil
        }

        do {
            // The grid's `AssetReactItem` (a timeline cell) has no file name and
            // no announced size; the full DTO has both (`fileSizeInByte` lives
            // on the EXIF block, not on the asset). The announced size is what
            // lets the store refuse an oversized download *before* it starts.
            let dto = try await client.getAsset(id: asset.id)
            let info = try await store.download(
                accountID: accountID,
                assetID: asset.id,
                url: ImmichAssetURL.original(assetId: asset.id, baseURL: baseURL, edited: edited),
                token: token,
                fileName: dto.originalFileName,
                isVideo: asset.isVideo,
                ratio: asset.ratio,
                fileCreatedAt: asset.fileCreatedAt,
                duration: asset.duration,
                thumbhash: asset.thumbhash,
                announcedSize: dto.exifInfo?.fileSizeInByte.map(Int64.init),
                onProgress: { [weak self] received, expected in
                    Task { @MainActor in
                        guard let self, self.downloadingIDs.contains(asset.id) else { return }
                        // No Content-Length (chunked): leave it nil so the UI
                        // shows an indeterminate bar instead of a frozen 0 %.
                        self.progressByID[asset.id] = expected > 0
                            ? min(1, Double(received) / Double(expected))
                            : nil
                    }
                }
            )
            await reload()
            lastDownloadedID = info.id
        } catch where UserFacingError.isCancellation(error) {
            // Cancelled by a purge (logout / "Clear All"): not a failure to report.
        } catch let error as OfflineStoreError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Removal

    func removeFromOffline(_ assetID: String) async {
        guard await store.remove(assetID: assetID, accountID: accountID) else { return }
        index.remove(assetID)
        await reload()
    }

    /// Wipes this account's offline copies and records what happened: a purge
    /// never ends in silence. Copies the disk would not delete stay listed (and
    /// readable) and the message counts them.
    func clearAll() async {
        switch await store.clearAll(accountID: accountID) {
        case .cleared:
            index.removeAll()
            errorMessage = nil
            await reload()
            purgeResult = .succeeded
        case .refused:
            // Another account's storage: the shared mirror is not ours to touch.
            purgeResult = .failed(
                message: String(localized: "This offline storage belongs to another account. Nothing was removed.")
            )
        case .incomplete(let remaining):
            // The listing is read back from disk: what survived stays listed.
            await reload()
            purgeResult = .failed(message: String(localized: "\(remaining) offline items could not be removed."))
        }
    }

    func dismissPurgeResult() {
        purgeResult = nil
    }

    /// Persists a new budget; the store trims the cache down to it immediately.
    func setMaxCacheSize(_ bytes: Int64) async {
        await store.setMaxCacheSize(bytes)
        await reload()
    }

    func clearError() {
        errorMessage = nil
        lastDownloadedID = nil
    }
}

/// How a purge of the offline cache ended.
enum OfflinePurgeResult: Equatable {
    case succeeded
    case failed(message: String)
}
