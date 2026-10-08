import Foundation
import Observation

/// Drives the offline cache from the UI: the storage screen, the viewer's
/// "Download for Offline" action and the badge index.
///
/// It owns no transport of its own — every byte and every index mutation goes
/// through `OfflineAssetStore`, which is the single source of truth on disk.
/// After each mutation the mirror (`OfflineAssetIndex`) is refreshed, because
/// the timeline badge reads it.
@MainActor
@Observable
final class OfflineDownloadViewModel {
    private let store: OfflineAssetStore
    private let client: any ImmichClient
    let index: OfflineAssetIndex

    /// Cached assets, most recent first — the storage screen's list.
    private(set) var cachedAssets: [CachedAssetInfo] = []
    /// Bytes currently held on disk.
    private(set) var cacheUsage: Int64 = 0
    /// Configured budget in bytes (`0` = unlimited).
    private(set) var maxCacheSize: Int64 = OfflineAssetStore.defaultMaxCacheSize
    private(set) var errorMessage: String?
    /// Asset that most recently finished downloading — drives the success haptic.
    private(set) var lastDownloadedID: String?

    var searchQuery: String = ""

    /// Per-asset download state. Observed on purpose: the share sheet reads
    /// both to decide between a spinner and a download button.
    private var progressByID: [String: Double] = [:]
    private var downloadingIDs: Set<String> = []

    init(store: OfflineAssetStore, client: any ImmichClient, index: OfflineAssetIndex) {
        self.store = store
        self.client = client
        self.index = index
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

    func load() async {
        maxCacheSize = await store.maxCacheSize
        await reload()
    }

    private func reload() async {
        let cached = await store.allCached()
        cachedAssets = cached
        cacheUsage = await store.totalBytes()
        maxCacheSize = await store.maxCacheSize
        await index.refresh(from: store)
    }

    // MARK: - Download

    /// Downloads the asset's original into the cache.
    ///
    /// Credentials are per-call: this view model is built once in the app
    /// container, long before a server is connected, so it cannot hold them.
    func downloadAsset(_ asset: AssetReactItem, baseURL: URL, token: String?) async {
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
                assetID: asset.id,
                url: ImmichAssetURL.original(assetId: asset.id, baseURL: baseURL),
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
        } catch let error as OfflineStoreError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Removal

    func removeFromOffline(_ assetID: String) async {
        await store.remove(assetID: assetID)
        index.remove(assetID)
        await reload()
    }

    func clearAll() async {
        await store.clearAll()
        index.removeAll()
        errorMessage = nil
        await reload()
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
