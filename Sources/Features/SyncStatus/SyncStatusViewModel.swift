import Foundation
import Observation

/// One screen's worth of the local sync state: what the ledger holds, what the
/// current run is doing, and what is pinned offline for how many bytes.
///
/// It owns **no** state and builds no engine. The upload run has exactly one
/// owner per process (`UploadViewModel` — a second `BackupEngine` would fight
/// for the Live Activity and, worse, report an empty queue while the real run
/// is in flight), and the offline index has a single writer
/// (`OfflineDownloadViewModel` over the process-wide store). Every property
/// below is therefore a *projection* of one of those two view models, read at
/// display time, so this screen can never drift from the engine it describes.
///
/// The actions are delegated the same way: each one is sent to the view model
/// that owns the state, never re-implemented here.
@MainActor
@Observable
final class SyncStatusViewModel {
    private let upload: UploadViewModel
    private let offline: OfflineDownloadViewModel

    init(upload: UploadViewModel, offline: OfflineDownloadViewModel) {
        self.upload = upload
        self.offline = offline
    }

    // MARK: - Ledger + run counters

    /// Assets the ledger records as already backed up.
    var trackedCount: Int { upload.trackedAssetCount }
    /// Assets of the current run whose outcome is not settled yet: the run's
    /// denominator minus everything already finalized. `total` keeps its value
    /// after the run ends, so reading it raw would show work that is done.
    var pendingCount: Int { max(0, upload.engine.total - upload.engine.processedCount) }
    /// Exported + hashed and waiting for the dedup/upload chunk — the backlog
    /// the queue is actually working through.
    var stagedCount: Int { upload.engine.stagedCount }
    var uploadedCount: Int { upload.engine.uploadedCount }
    /// Assets the server already had: skipped, not failures.
    var alreadyOnServerCount: Int { upload.engine.rejectedCount }
    var failedCount: Int { upload.engine.failedCount }
    /// Held back this run: the iCloud original was not local yet. Retried
    /// automatically, which is why it is not one of the failure counters.
    var deferredCount: Int { upload.engine.deferredCount }
    var waitingForWiFi: Bool { upload.engine.deferralReason.contains(.waitingForWiFi) }
    var waitingForICloud: Bool { upload.engine.deferralReason.contains(.waitingForICloud) }
    var failures: [BackupFailure] { upload.engine.failures }
    var currentFileName: String? { upload.engine.currentFileName }

    // MARK: - Offline index

    var offlineCount: Int { offline.cachedAssets.count }
    var offlineBytes: Int64 { offline.cacheUsage }

    /// Bytes of the offline cache, formatted by the download view model — the
    /// only byte formatter in the app. A second one here is how two screens
    /// start showing the same file with two different sizes.
    func formattedOfflineBytes() -> String { offline.formattedUsage(offline.cacheUsage) }

    // MARK: - Run state

    var phase: BackupEngine.Phase { upload.engine.phase }
    var isRunning: Bool { upload.running }
    var isCancelling: Bool { upload.engine.isCancelling }
    var progressFraction: Double { upload.engine.progressFraction }
    /// Most recent completed run — the same history the Backup screen lists.
    var lastRun: UploadHistoryEntry? { upload.uploadHistory.last }
    /// When the ledger was last confronted with the server (nil = never).
    var lastServerCheck: Date? { upload.lastReconciliation }

    // MARK: - Errors + empty state

    var runErrorMessage: String? { upload.engine.lastError }
    var offlineErrorMessage: String? { offline.listingErrorMessage ?? offline.errorMessage }
    var hasPendingWork: Bool { isRunning || pendingCount > 0 || stagedCount > 0 }
    /// Nothing recorded anywhere yet: the screen shows its empty state instead
    /// of a grid of zeros that would suggest a finished, empty library.
    var isEmpty: Bool {
        trackedCount == 0 && offlineCount == 0 && lastRun == nil && !hasPendingWork
    }

    // MARK: - Dates

    func formattedLastRun() -> String { Self.formatted(lastRun?.date) }
    func formattedLastServerCheck() -> String { Self.formatted(lastServerCheck) }

    private static func formatted(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Actions

    /// Picks the queue back up and waits for the run to settle, so the button's
    /// busy state lives exactly as long as the work does.
    func runNow() async {
        upload.resumeUpload()
        await upload.awaitCurrentBackup()
    }

    func cancelRun() { upload.cancelBackup() }

    func reconcileNow() async { await upload.reconcileNow() }

    func resetLedger() { upload.resetBackupTracking() }

    func clearOfflineCache() async { await offline.clearAll() }

    func clearOfflineError() { offline.clearError() }

    /// Re-reads the offline index from disk. The run counters need no reload:
    /// they are read straight off the observed engine.
    func refresh() async { await offline.load() }
}
