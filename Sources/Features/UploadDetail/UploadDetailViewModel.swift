import Foundation
import Observation

/// Per-asset report of the last backup run: what is in flight (and how far its
/// iCloud download got), what the run held back, what failed, and the two
/// retries that name their assets.
///
/// It **composes** the process-wide `UploadViewModel` instead of building its
/// own engine. Two engines have independent `!running` guards, so they would
/// sweep the same library at once (double iCloud downloads), and
/// `engine.onProgressUpdate` is a single closure each run installs — the first
/// run to finish cuts it out from under the other (`DependencyContainer`, "One
/// VM, one run, one island").
///
/// It also stores nothing: every value below is a projection of that engine, so
/// a run started on any other screen shows up here without a refresh.
@MainActor
@Observable
final class UploadDetailViewModel {
    /// What the one in-flight asset is doing. The Backup screen owns the
    /// engine's `statusMessage` sentence; this screen says the same thing per
    /// asset, which is the difference between a log line and a report.
    enum InFlightState: Equatable {
        case idle
        case downloading(Double)
        case retrying(Int)
        case hashing
        case uploading
    }

    /// The run's single view model — and therefore the single engine.
    private let upload: UploadViewModel

    init(upload: UploadViewModel) {
        self.upload = upload
    }

    private var engine: BackupEngine { upload.engine }

    // MARK: - The run

    var phase: BackupEngine.Phase { engine.phase }
    var isRunning: Bool { upload.running }
    var isCancelling: Bool { engine.isCancelling }
    var progressFraction: Double { engine.progressFraction }
    var total: Int { engine.total }
    var examinedCount: Int { engine.examinedCount }
    var uploadedCount: Int { engine.uploadedCount }
    /// Bytes the run uploaded. The engine keeps no per-asset record of the
    /// successes, so "Uploaded" is a summary and never a list.
    var uploadedBytes: Int64 { engine.uploadedBytes }

    /// Nothing left to report: no run, nothing in flight, nothing held back,
    /// nothing failed, nothing uploaded. A run that finished while the app was
    /// closed leaves the engine empty, and an empty screen must say so rather
    /// than show three empty sections.
    var isEmpty: Bool {
        !isRunning && deferrals.isEmpty && failures.isEmpty && uploadedCount == 0
    }

    /// Pull-to-refresh. There is nothing to read: every value above is a live
    /// projection of the engine, so the screen is always current. It starts no
    /// request and no backup, and returns at once.
    func refresh() async {}

    // MARK: - Per-asset lists

    var failures: [BackupFailure] { engine.failures }
    var deferrals: [BackupDeferral] { engine.deferrals }
    var failedCount: Int { failures.count }
    var deferredCount: Int { deferrals.count }

    // MARK: - In flight

    var currentAssetID: String? { engine.currentAssetID }
    var currentFileName: String? { engine.currentFileName }

    /// The iCloud download fraction of the asset in flight. It is the only
    /// per-asset percentage that exists: `uploadAsset` reports no progress, so
    /// the upload state stays indeterminate rather than invented.
    var currentICloudFraction: Double? {
        currentAssetID.flatMap { engine.iCloudProgress[$0] }
    }

    /// 1-based retry attempt of the asset in flight, once iCloud stalled on it.
    var currentRetryAttempt: Int? {
        currentAssetID.flatMap { engine.iCloudRetryAttempts[$0] }
    }

    /// What the in-flight asset is doing, projected from the engine's
    /// per-asset iCloud maps and its phase — never from `statusMessage`, which
    /// stays the Backup screen's line.
    var currentState: InFlightState {
        guard let id = currentAssetID else { return .idle }
        if let fraction = engine.iCloudProgress[id] { return .downloading(fraction) }
        if let attempt = engine.iCloudRetryAttempts[id] { return .retrying(attempt) }
        return phase == .uploading ? .uploading : .hashing
    }

    /// Label of the in-flight state. `.idle` has no string: the header renders
    /// this only while an asset is in flight.
    var currentStateLabel: String {
        switch currentState {
        case .idle: ""
        case .downloading: String(localized: "Downloading from iCloud")
        case .retrying: String(localized: "Waiting for iCloud")
        case .hashing: String(localized: "Preparing to upload")
        case .uploading: String(localized: "Uploading")
        }
    }

    // MARK: - Actions

    func retry(id: String) async { await upload.retryAsset(id: id) }

    func retryAllFailed() async { await upload.retryAllFailed() }

    func cancel() { upload.cancelBackup() }

    // MARK: - Formatting

    /// The repo's one byte idiom (`OfflineDownloadViewModel.formattedUsage`),
    /// plus the honest case the engine can produce: a size the library wouldn't
    /// report for an iCloud-only original that was never exported.
    static func formattedBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return String(localized: "Unknown size") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// What a held-back asset is waiting for — two different user stories: a
    /// download that hasn't landed, a network that isn't allowed yet.
    static func deferralLabel(_ reason: BackupDeferralReason) -> String {
        reason.contains(.waitingForWiFi)
            ? String(localized: "Waiting for Wi-Fi")
            : String(localized: "Waiting for iCloud")
    }

    static func deferralIcon(_ reason: BackupDeferralReason) -> String {
        reason.contains(.waitingForWiFi) ? "wifi.slash" : "icloud.and.arrow.down"
    }
}
