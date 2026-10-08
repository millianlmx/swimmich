import Foundation
import Observation

/// Media Stats (gap G24): what the device and the server actually hold.
///
/// The server half is the same call the storage card makes
/// (`GET /api/server/statistics`); the local half is the two counts this app
/// really owns — the backup ledger's tracked assets and the offline cache.
///
/// The counters the Flutter page reads from its Drift database (stacks, people,
/// memories, faces…) are deliberately **absent**: iOS keeps no local asset
/// database, and a zero would be a lie dressed as a measurement.
@MainActor
@Observable
final class MediaStatsViewModel {
    private let client: any ImmichClient
    private let ledger: any BackupLedgerStoring
    private let offline: OfflineDownloadViewModel

    var photos = 0
    var videos = 0
    var usage: Int64 = 0
    /// nil when the server defines no quota — the row is then omitted, like the
    /// storage card's bar.
    var quotaSizeInBytes: Int64?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(client: any ImmichClient, ledger: any BackupLedgerStoring, offline: OfflineDownloadViewModel) {
        self.client = client
        self.ledger = ledger
        self.offline = offline
    }

    // MARK: - Local facts (no network)

    /// Assets the backup ledger tracks as uploaded.
    var trackedCount: Int { ledger.trackedCount() }

    var offlineCount: Int { offline.cachedAssets.count }

    var offlineBytes: Int64 { offline.cacheUsage }

    // MARK: - Loading

    /// Fetches the server's counters once per invocation, re-entrancy guarded —
    /// the same shape as the storage card, so the two cannot drift. The device's
    /// half is refreshed first: it comes from the offline cache, which is a
    /// projection, not a live read.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await offline.load()
        do {
            let stats = try await client.getServerStatistics()
            photos = stats.photos
            videos = stats.videos
            usage = Int64(stats.usage)
            // First user-level entry carrying a quota wins.
            quotaSizeInBytes = stats.usageByUser
                .first { ($0.quotaSizeInBytes ?? 0) > 0 }
                .flatMap { $0.quotaSizeInBytes }
                .map(Int64.init)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
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
