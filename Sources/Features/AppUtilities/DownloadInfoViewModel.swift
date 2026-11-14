import Foundation
import Observation

/// Download Info (gap G24): the **inventory of the offline cache already
/// written** — the files it holds, what they weigh, and a purge.
///
/// Not the live queue. In-flight transfers belong to `download-panel`'s panel,
/// and a second list of them here would be a second answer to the same
/// question. This view model owns no state at all: it projects
/// `OfflineDownloadViewModel`, which already owns the cache and the only byte
/// formatter of the repo, so the two screens cannot disagree about what is on
/// disk.
@MainActor
@Observable
final class DownloadInfoViewModel {
    private let offline: OfflineDownloadViewModel

    init(offline: OfflineDownloadViewModel) {
        self.offline = offline
    }

    /// Cached files, most recently written first.
    var files: [CachedAssetInfo] {
        offline.cachedAssets.sorted { $0.cachedAt > $1.cachedAt }
    }

    var fileCount: Int { files.count }

    var totalBytes: Int64 { offline.cacheUsage }

    /// The only byte formatter stays the offline screen's own — a second
    /// implementation would eventually round differently.
    func formattedTotalSize() -> String { offline.formattedUsage(totalBytes) }

    func formattedSize(_ info: CachedAssetInfo) -> String { offline.formattedUsage(info.size) }

    /// The second line of a row: the name inside the cache and when it landed.
    /// Pre-formatted here — the view formats neither a byte nor a date — and
    /// through `Date.formatted`, so an in-app language change is honored rather
    /// than frozen in a cached formatter.
    func subtitle(for info: CachedAssetInfo) -> String {
        "\(info.fileName) · \(info.cachedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Reading state (projected from the cache view model)

    var isLoadingListing: Bool { offline.isLoadingListing }
    var hasLoadedListing: Bool { offline.hasLoadedListing }
    var listingErrorMessage: String? { offline.listingErrorMessage }
    var isRefreshingListing: Bool { offline.isRefreshingListing }

    /// What the screen renders; `data` is the cached files.
    var renderState: ListRenderState {
        .resolve(
            isEmpty: files.isEmpty,
            hasLoaded: hasLoadedListing,
            isLoading: isLoadingListing,
            isRefreshing: isRefreshingListing,
            loadError: listingErrorMessage
        )
    }

    /// Reads the disk, without a pull: the `.task` and every "Try Again".
    func load() async { await offline.load() }

    /// Pull-to-refresh.
    func refresh() async { await offline.refresh() }

    func clearAll() async { await offline.clearAll() }

    /// How the last purge ended (success or why it failed), for the alert.
    var purgeResult: OfflinePurgeResult? { offline.purgeResult }

    func dismissPurgeResult() { offline.dismissPurgeResult() }
}
