import Foundation
import Observation

/// Media Stats (gap G24): what the device and the server actually hold.
///
/// The server half is the *account's* storage (`StorageStatsViewModel`: usage
/// and quota from `GET /api/users/me`, own counts from
/// `GET /api/assets/statistics`); instance totals live in Administration only.
/// The local half is the two counts this app really owns — the backup ledger's
/// tracked assets and the offline cache — and stays correct when the server
/// reads fail.
///
/// The counters the Flutter page reads from its Drift database (stacks, people,
/// memories, faces…) are deliberately **absent**: iOS keeps no local asset
/// database, and a zero would be a lie dressed as a measurement.
@MainActor
@Observable
final class MediaStatsViewModel {
    private let ledger: any BackupLedgerStoring
    private let offline: OfflineDownloadViewModel
    let storage: StorageStatsViewModel
    private(set) var isLoading = false

    init(client: any ImmichClient, ledger: any BackupLedgerStoring, offline: OfflineDownloadViewModel) {
        self.ledger = ledger
        self.offline = offline
        self.storage = StorageStatsViewModel(client: client)
    }

    // MARK: - Local facts (no network)

    /// Assets the backup ledger tracks as uploaded.
    var trackedCount: Int { ledger.trackedCount() }

    var offlineCount: Int { offline.cachedAssets.count }

    var offlineBytes: Int64 { offline.cacheUsage }

    /// Why the offline cache could not be read, or `nil`. While set, the cache
    /// facts above are not measurements and the screen shows "Unavailable".
    var offlineListingErrorMessage: String? { offline.listingErrorMessage }

    /// The account's own counts were read and are 0 photos and 0 videos.
    var serverCountsAreEmpty: Bool {
        if case .loaded(let counts) = storage.counts { return counts.total == 0 }
        return false
    }

    // MARK: - Loading

    /// Re-reads the device's half (the offline cache is a projection of the
    /// disk), then the account's two server reads. Action of the `.task`, the
    /// `.refreshable` and every "Try Again": the screen has no list, its rows
    /// stay in place, so there is no refreshing state.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        await offline.load()
        await storage.load()
    }

    // MARK: - Formatting (bytes and dates are never formatted in the view)

    func formattedUsage(_ bytes: Int64) -> String { StorageStatsViewModel.format(bytes) }

    /// When the ledger was last confronted with the server — "Never" if it
    /// never was, which is a fact and not an error.
    func formattedLastReconciliation() -> String {
        guard let date = ledger.lastReconciliation else { return String(localized: "Never") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
