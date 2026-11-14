import CryptoKit
import Foundation

/// Upload conditions + scoping, persisted by `BackupSettingsStore`.
struct BackupSettings: Equatable, Sendable {
    var isEnabled = false
    /// Foreground auto-run gate: when on, app activation runs a scan (in
    /// addition to the OS background windows), and Photos insertions wake a run
    /// while the app is open. See
    /// `UploadViewModel.kickOffAutoBackupIfConfigured`.
    var autoDetectNewPhotos = false
    /// Whether the Photos change observer should be running. Detection is
    /// meaningless with auto-backup off — every run it would start is refused by
    /// the `isEnabled` gate — so both toggles are required.
    var shouldObserveLibraryChanges: Bool { isEnabled && autoDetectNewPhotos }
    var onlyOnWiFi = false
    var onlyWhenCharging = false
    /// Under `onlyOnWiFi`, whether each media kind may still upload over
    /// cellular. Decided per asset, so a user can allow photos (a few MB) while
    /// videos (potentially GBs) wait for Wi-Fi instead of choosing all-or-nothing.
    var allowCellularForPhotos = false
    var allowCellularForVideos = false
    /// Albums whose assets are left out of every run. User albums are
    /// `localIdentifier`s, smart albums are `BackupAlbum.SmartID` values. The
    /// resolution happens in the asset source, so the engine never sees album
    /// names — the filename heuristics this replaced were wrong on iOS
    /// (`!hasPrefix("IMG_")` excluded almost the whole camera roll,
    /// `!contains("WhatsApp")` filtered nothing).
    var excludedAlbumIDs: Set<String> = []
    var selectedAlbumIDs: Set<String> = []
    /// "Show backup status on thumbnails" (G6). Not an upload condition — the
    /// engine never reads it; it rides the snapshot so the badge gate is part
    /// of the same persisted preference set as everything the screen shows.
    var showSyncBadge = false
    /// Albums whose Photos contents are mirrored into a server album of the
    /// same name (one-way, device → server). Not a scope: it decides where an
    /// already-selected asset is *filed*, never what gets backed up. Empty by
    /// default, so an existing install behaves exactly as before.
    var syncedAlbumIDs: Set<String> = []
    /// "Also back up edits": an asset edited in place in Photos (or by an app
    /// that edits through PhotoKit) has its edited rendering uploaded too, and
    /// stacked on top of its original. Off by default; off, a run is exactly
    /// the original-only backup — no edit is exported, sent or stacked.
    var backUpEdits = false
}

/// A single asset the backup couldn't process, kept for the failures list.
struct BackupFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// Photos `localIdentifier` of the asset — a targeted retry needs a key the
    /// library answers to, and a file name is not one.
    let assetID: String
    let name: String
    let reason: String
    /// Bytes the run knew for this asset: the scan's size, or the size it
    /// measured on the exported original. `nil` means genuinely unknown, which
    /// the UI says out loud rather than showing "0 B".
    let fileSize: Int64?
}

/// Why assets were held back this run. Both cases are non-failures: the asset
/// is retried automatically on the next run. The UI needs to name the cause —
/// "Waiting for Wi-Fi" and "Waiting for iCloud" are different user stories.
struct BackupDeferralReason: OptionSet, Sendable {
    let rawValue: Int
    static let waitingForICloud = BackupDeferralReason(rawValue: 1 << 0)
    static let waitingForWiFi = BackupDeferralReason(rawValue: 1 << 1)
}

/// One asset held back from a run, with the reason and the size the run knew.
/// `deferredCount` says how many were held back; this says which — a count
/// can't be retried or explained asset by asset. `id` is the Photos
/// `localIdentifier` rather than a UUID for exactly that reason: it is the key
/// the retry names, and it keeps one asset to one entry.
struct BackupDeferral: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let reason: BackupDeferralReason
    let fileSize: Int64?
    let kind: BackupAssetKind
}

/// What one run did to the assets it was handed, captured the instant `run`
/// returns. `backedUpIDs` is proof, not a deduction: only assets the engine
/// wrote to the ledger (uploaded, or already on the server with their Live
/// Photo video linked) are in it.
struct BackupRunOutcome: Equatable, Sendable {
    let backedUpIDs: Set<String>
    let failures: [BackupFailure]
    let deferrals: [BackupDeferral]
    let wasCancelled: Bool
}

/// Background backup state machine. Pure orchestration over the injected
/// seams: `ImmichClient` (dedup + upload), `BackupAssetSource` (library),
/// `BackupEnvironment` (wifi/charging gates).
@Observable
@MainActor
final class BackupEngine {
    enum Phase: Equatable {
        case idle, checking, uploading, done, cancelled
    }

    let client: any ImmichClient
    let source: any BackupAssetSource
    let environment: any BackupEnvironment
    /// Persistent record of assets already backed up — lets a run skip them
    /// before export, so an iCloud library isn't re-downloaded every run.
    let ledger: any BackupLedgerStoring
    /// The edited versions already sent, beside the original ledger. Only
    /// read and written when `BackupSettings.backUpEdits` is on (and by the
    /// full reset).
    let editLedger: any BackupEditLedgerStoring

    private(set) var phase: Phase = .idle
    /// Total assets to process this run — the full filtered candidate count,
    /// known before any work. The progress-bar denominator.
    private(set) var total = 0
    private(set) var uploadedCount = 0
    private(set) var rejectedCount = 0
    private(set) var failedCount = 0
    /// Assets skipped this run because their iCloud original wasn't downloaded
    /// yet — NOT failures; they're retried automatically on the next run.
    private(set) var deferredCount = 0
    /// Why `deferredCount` grew: waiting on iCloud, on a permitted network, or
    /// both. Reset with the run.
    private(set) var deferralReason: BackupDeferralReason = []
    /// Assets whose original is exported + hashed and waiting on disk for the
    /// dedup/upload chunk. They are not finished, but the slow half of their
    /// work (an iCloud download, in the worst case) is done — the progress bar
    /// credits them half a step so it moves during the hash pass.
    private(set) var stagedCount = 0
    private(set) var lastError: String?
    /// Human-readable per-asset status (iCloud download / retry), or nil when
    /// nothing noteworthy is happening. Drives the "Downloading from iCloud…"
    /// line in the UI so a slow iCloud fetch isn't an opaque stall.
    private(set) var statusMessage: String?

    /// File name of the asset currently being exported/hashed/uploaded, or nil
    /// when between items. Drives the "Uploading IMG_1234.HEIC" line.
    private(set) var currentFileName: String?
    /// `localIdentifier` of the current asset, for a thumbnail preview.
    private(set) var currentAssetID: String?
    /// True once cancellation was requested but the engine hasn't yet reached a
    /// boundary — lets the UI show "Cancelling…" instead of a dead button.
    private(set) var isCancelling = false
    /// Every asset that failed this run (export/hash/dedup/upload), with reason.
    private(set) var failures: [BackupFailure] = []
    /// Bytes of the assets this run actually uploaded. The successes aren't
    /// listed asset by asset — the engine keeps no per-asset record of them —
    /// so this total is what the "Uploaded" summary reports.
    private(set) var uploadedBytes: Int64 = 0
    /// Which assets were held back this run, one entry per asset: the reason,
    /// the size and the kind `deferredCount` only counts.
    private(set) var deferrals: [BackupDeferral] = []
    /// iCloud download fraction per asset `localIdentifier`, and the 1-based
    /// retry attempt per asset. Keyed by asset, not a single scalar, so a
    /// download is attributed to the asset it belongs to; the entry of the
    /// asset the run has moved past is dropped, `reset()` clears the rest.
    private(set) var iCloudProgress: [String: Double] = [:]
    private(set) var iCloudRetryAttempts: [String: Int] = [:]
    /// When the upload phase began — the clock for the ETA estimate.
    private(set) var startedAt: Date?

    /// What the album mirror did, once a run (or a reorganization) has gone
    /// through it. Nil while the mirror is off. Read by the backup screen.
    private(set) var albumSyncOutcome: AlbumSyncOutcome?
    /// `deviceAlbumID → serverAlbumID` for this run. Empty means the mirror is
    /// inactive: an unmirrored asset costs no buffer entry and no request.
    private var albumMap: [String: String] = [:]
    /// `deviceAssetID → deviceAlbumIDs`, resolved once per run by the asset
    /// source, so staging an uploaded asset never calls back into Photos.
    private var albumMembership: [String: [String]] = [:]
    /// The one-way album mirror. A no-op unless `currentUserID` yields an
    /// account and the user picked albums to mirror.
    let albumSync: any AlbumSyncServicing
    /// The signed-in server account, read on demand rather than captured: the
    /// mirror is inactive while this returns nil, and `AlbumSyncStore` keys its
    /// mapping by it — capturing the id at construction would leave the mirror
    /// off for the whole session of a login that happens after the composition
    /// root was built.
    private let currentUserID: @MainActor () -> String?

    /// Assets whose outcome is final (uploaded, already-on-server, or failed) —
    /// the progress-bar numerator.
    var processedCount: Int { uploadedCount + rejectedCount + failedCount + deferredCount }

    /// Assets already looked at this run — finished or staged. The "N of M"
    /// counter next to the bar, so the number moves during the hash pass too.
    var examinedCount: Int { processedCount + stagedCount }

    /// 0...1 completion. Every asset is two half-steps: staged (original
    /// exported + hashed) then finalized (uploaded / already-on-server /
    /// failed / deferred). Crediting the staged half is what keeps the bar
    /// alive: with `processed / total` alone it sat at 0 through the whole
    /// export+hash pass and then jumped a full chunk at once — on a library
    /// the server already has, that reads as 0% frozen then 100%, i.e. a bug.
    var progressFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, (Double(processedCount) + 0.5 * Double(stagedCount)) / Double(total))
    }

    /// Whole-percent completion (0...100) for a "%" label.
    var progressPercent: Int { Int((progressFraction * 100).rounded()) }

    /// Rough seconds remaining, from the upload-phase throughput. Nil until we
    /// have measurable progress, so the UI can hide it early on.
    var estimatedSecondsRemaining: Int? {
        guard phase == .uploading, let startedAt, processedCount > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0 else { return nil }
        let rate = Double(processedCount) / elapsed
        guard rate > 0 else { return nil }
        let remaining = Double(max(0, total - processedCount))
        return Int((remaining / rate).rounded())
    }

    /// Progress callback (processed, total) fired on the main actor after every
    /// asset outcome — upload, dedup-reject, failure, or iCloud defer — so the
    /// Live Activity mirrors the in-app `processedCount / total` bar exactly.
    var onProgressUpdate: ((_ processed: Int, _ total: Int) -> Void)?

    /// Fired after every ledger write this engine commits — once per chunk, at
    /// run end, after a reconciliation pass, and on a full reset. The ledger is
    /// what the thumbnail badge reads, so this is the wake-up call that puts a
    /// freshly uploaded asset's badge on screen while the app is open.
    var onLedgerChange: (() -> Void)?

    /// Persists the ledger and tells the UI it changed. The two belong together:
    /// `save()` is the boundary where the engine's work becomes durable, so it is
    /// also the only point worth mirroring.
    private func commitLedger() {
        ledger.save()
        editLedger.save()
        onLedgerChange?()
    }

    /// Fires the progress callback with the current processed count.
    private func notifyProgress() { onProgressUpdate?(processedCount, total) }

    private var isCancelled = false
    /// The pipeline Task of the run in flight (nil when idle).
    private var activeRun: Task<Bool, Never>?
    /// True from the moment `run` starts its pipeline until it has returned —
    /// including the instant after `phase` reads `.done`, when a new run must
    /// still be refused.
    var isRunActive: Bool { activeRun != nil }
    /// Assets this run wrote to the ledger — exactly the `markBackedUp` calls of
    /// `processBatch`: uploaded, or already on the server with their Live Photo
    /// video linked. What a caller that asked for specific assets reads to know
    /// which of them are really on the server; "requested minus failed" would
    /// count deferred and cancelled assets as sent.
    private(set) var backedUpIDs: Set<String> = []
    /// Assets whose stack was attempted by the element's own pass this run, so
    /// the pending-stacks pass does not try (and warn about) them twice.
    private var stackAttemptedIDs: Set<String> = []
    /// The result of the last run, for a restricted caller (the Upload of "On
    /// this device"). Read right after `run` returns, before any suspension.
    var runOutcome: BackupRunOutcome {
        BackupRunOutcome(backedUpIDs: backedUpIDs, failures: failures, deferrals: deferrals, wasCancelled: phase == .cancelled)
    }
    /// Chunk size for every batched server call a run makes: the dedup check,
    /// the ledger reconciliation, and the album mirror's batch size (which the
    /// service receives from here, never a copy of its own).
    static let checkChunkSize = 100
    /// Disk ceiling for one hash chunk's retained originals. Videos can be
    /// large; flush (dedup + upload + delete) once a chunk's temp files exceed
    /// this so disk stays bounded even with big movies in a chunk.
    private static let maxBatchBytes = 512 << 20
    /// How often the ledger is confronted with the server. The pass costs no
    /// media bytes, but it is still a full sweep of the tracked set — weekly
    /// is enough to catch an asset deleted server-side.
    static let reconcileInterval: TimeInterval = 7 * 24 * 3600

    /// One candidate staged on disk for the dedup/upload chunk: its original
    /// (exported + hashed; a Live Photo also stages its paired video) and/or
    /// its edited rendering. An "edit only" element — original already on the
    /// server — has no `original`.
    private struct StagedAsset {
        let candidate: BackupCandidate
        var original: StagedOriginal?
        var edit: StagedEdit?
        /// Adjusted in Photos but without an edited resource: the current
        /// rendering is the original, recorded once the original is on the
        /// server.
        var renderingIsOriginal = false
    }

    private struct StagedOriginal {
        let checksum: String
        let fileURL: URL
        var paired: StagedPairedVideo?
    }

    private struct StagedEdit {
        let url: URL
        let checksum: String
        let fileName: String
        var paired: StagedPairedVideo?
    }

    private struct StagedPairedVideo {
        let url: URL
        let checksum: String
        let fileName: String
        let duration: Int
    }

    /// What one candidate needs this run (`BackupSettings.backUpEdits` on).
    private struct ItemPlan {
        var needsOriginal: Bool
        var needsEdit: Bool
    }

    init(
        client: any ImmichClient,
        source: any BackupAssetSource,
        environment: any BackupEnvironment = SystemBackupEnvironment(),
        ledger: any BackupLedgerStoring = BackupLedger.inMemory(),
        editLedger: any BackupEditLedgerStoring = BackupEditLedger.inMemory(),
        albumSync: (any AlbumSyncServicing)? = nil,
        userID: (@MainActor () -> String?)? = nil
    ) {
        self.client = client
        self.source = source
        self.environment = environment
        self.ledger = ledger
        self.editLedger = editLedger
        // A default service keeps the engine usable without the composition
        // root (tests), and is inert without a user id.
        self.albumSync = albumSync
            ?? AlbumSyncService(mapping: AlbumSyncStore(), batchSize: Self.checkChunkSize)
        self.currentUserID = userID ?? { nil }
    }

    /// Number of assets the ledger already tracks as backed up.
    var trackedAssetCount: Int { ledger.trackedCount() }

    /// The tracked `(device asset id, checksum)` pairs — what the album mirror's
    /// catch-up walks to recover the server id of an already-uploaded asset.
    func entriesForReconciliation() -> [(id: String, checksum: String)] {
        ledger.entriesForReconciliation()
    }

    /// Clears the backup ledger — the next run re-backs-up everything.
    func forgetAllBackedUp() {
        ledger.removeAll()
        editLedger.removeAll()
        onLedgerChange?()
    }

    /// Stops the run in flight, if any: flags the staging loop and cancels the
    /// pipeline Task so the in-flight export or network call ends now. No run
    /// in flight → no-op: nothing is remembered for the next run. Must be
    /// called on the main actor.
    func cancel() {
        guard let work = activeRun else { return }
        isCancelled = true
        isCancelling = true
        work.cancel()
    }

    /// `cancel()` plus a wait: returns once the run in flight has fully wound
    /// down, so nothing reaches the ledger after this returns, then releases
    /// the engine — the next `run` is accepted (a signed-out user may sign in
    /// and back up again). No run in flight → no-op.
    func stopAndWait() async {
        guard let work = activeRun else { return }
        cancel()
        _ = await work.value
        releaseRun(work)
    }

    /// Ends `work`'s hold on the engine and re-arms it — only if `work` still
    /// holds it: `run()` and `stopAndWait()` both wait on the same Task and
    /// resume in no guaranteed order; the later one must not release a run
    /// started in between.
    private func releaseRun(_ work: Task<Bool, Never>) {
        guard activeRun == work else { return }
        activeRun = nil
        isCancelled = false
        isCancelling = false
    }

    /// Surfaces a pre-run error to the UI (e.g. missing Photos permission)
    /// without entering the pipeline.
    func reportError(_ message: String) {
        lastError = message
    }

    /// Runs the backup pipeline. `manual == true` (Run now / resume /
    /// backfill) is an explicit user action: it ignores the automatic gates
    /// (isEnabled, Wi-Fi-only, charging-only), which only govern the
    /// unattended background path (`manual == false`).
    ///
    /// The pipeline avoids holding originals in memory and avoids downloading an
    /// iCloud-optimized library twice: each candidate's original is exported to
    /// a temp file, SHA1-hashed by streaming that file, and the temp file is
    /// kept until dedup. Accepted assets upload one at a time straight from that
    /// same file, then it's deleted; rejected files are deleted at dedup. Work
    /// is chunked by `checkChunkSize` items or `maxBatchBytes` on disk, so
    /// uploads start quickly and disk use stays bounded.
    /// Returns whether the run actually entered the pipeline: `false` means an
    /// automatic gate rejected it (disabled, no Wi-Fi, not charging) or another
    /// run already owns the engine, so no phase transition — and no Live
    /// Activity, notification or history entry — belongs to this call.
    ///
    /// `only` restricts the run to the named Photos `localIdentifiers` — the
    /// retry path. Such a run reads those assets by identifier
    /// (`fetchCandidates(ids:)`), skips the ledger reconciliation and skips the
    /// ledger filter: the user named the assets, so an asset the ledger counts
    /// as done (a Live Photo whose still is on the server while its link
    /// warning still stands) must be re-decided instead of filtered out
    /// forever. Everything downstream — `total = remaining.count`, the staging
    /// loop, `processBatch`, the ledger writes, the counters — is the same
    /// code as a full run.
    @discardableResult
    func run(settings: BackupSettings, manual: Bool = false, only assetIDs: [String] = []) async -> Bool {
        guard activeRun == nil, phase != .uploading, phase != .checking else { return false }
        if !manual {
            guard settings.isEnabled else { return false }

            // Environment gate — phase stays idle, nothing hits the network.
            // Offline is the only pre-run network refusal: "not on Wi-Fi" is
            // decided per asset, so photos can go up over cellular while
            // videos wait, instead of the whole run being all-or-nothing.
            guard environment.isOnline else {
                lastError = String(localized: "Backup needs a network connection.")
                return false
            }
            if settings.onlyWhenCharging && !environment.isCharging {
                lastError = String(localized: "Backup requires charging.")
                return false
            }
        }
        reset()
        lastError = nil
        phase = .checking
        // The pipeline runs in a stored Task so `cancel()` / `stopAndWait()`
        // can cancel the in-flight calls and join it. The caller's own
        // cancellation is forwarded to that Task, exactly as when the body ran
        // inline. The run holds the engine until this call returns.
        let work = Task { await self.runPipeline(settings: settings, manual: manual, only: assetIDs) }
        activeRun = work
        let entered = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        releaseRun(work)
        return entered
    }

    /// Body of `run` after the guards and the synchronous phase transition.
    private func runPipeline(settings: BackupSettings, manual: Bool, only assetIDs: [String]) async -> Bool {
        let restricted = !assetIDs.isEmpty
        if !restricted {
            // Confront the ledger with the server BEFORE scanning: an asset
            // deleted server-side is forgotten here, so it is a candidate in
            // this very run. A retry has no scan to reconcile for.
            await reconcileLedgerIfDue(includeEdits: settings.backUpEdits)
        }
        // Enumerating the library and reading each asset's metadata is heavy
        // Photos work; run it off the main actor so the UI never freezes while
        // the engine is "Checking library…".
        let source = self.source
        let albumIDs = settings.selectedAlbumIDs
        let excludedAlbumIDs = settings.excludedAlbumIDs
        var remaining = await Task.detached(priority: .utility) {
            // Clear leftover temp originals from a previous run that a jetsam
            // OOM/expiration killed before it could delete them, then scan.
            source.purgeStaleExports()
            // A retry names its assets: reading a handful of identifiers is a
            // point lookup, where the enumeration is a whole-library scan.
            if restricted { return source.fetchCandidates(ids: assetIDs) }
            return source.fetchCandidates(in: albumIDs, excluding: excludedAlbumIDs)
        }.value

        // Skip assets already backed up (uploaded or server-confirmed
        // duplicate) with the same modification signature — the whole point of
        // the ledger: an iCloud-optimized library must not be re-downloaded
        // every run just to be re-hashed and rejected.
        let ledger = self.ledger
        // A restricted run keeps its named assets even when the ledger counts
        // them as done: the case a retry exists for — the still is on the
        // server, its Live Photo link warning isn't — is exactly the case the
        // ledger is wrong about.
        // With "Also back up edits" on, each candidate is planned once: does it
        // need its original exported, its edited rendering exported, or both?
        // Off, every candidate is just an original, as before.
        var plans: [String: ItemPlan] = [:]
        if settings.backUpEdits {
            for candidate in remaining { plans[candidate.id] = editPlan(for: candidate, restricted: restricted) }
        }
        if !restricted {
            remaining = remaining.filter {
                if let plan = plans[$0.id] { return plan.needsOriginal || plan.needsEdit }
                return !ledger.isBackedUp(id: $0.id, signature: $0.fileModifiedAt)
            }
        }

        // One album resolution per run, before any asset is staged: album names
        // and per-album membership come out of Photos here, so the upload loop
        // never pays a Photos round-trip per asset.
        await resolveAlbumMirror(settings: settings)

        // Denominator is fixed now: everything that passed the filters is an
        // asset to process, whether it uploads, dedups, or fails.
        total = remaining.count

        var batch: [StagedAsset] = []
        var batchBytes = 0
        var index = 0
        while index < remaining.count {
            if isCancelled { return await cancelStaging(&batch) }
            let candidate = remaining[index]
            index += 1
            // Per-asset iCloud reporting belongs to the asset being worked on:
            // drop the entry of the one the run just left behind, whatever
            // ended it — `reset()` clears whatever the last asset leaves.
            if let left = currentAssetID, left != candidate.id {
                iCloudProgress[left] = nil
                iCloudRetryAttempts[left] = nil
            }
            currentFileName = candidate.fileName
            currentAssetID = candidate.id
            statusMessage = nil

            // Network policy, decided per asset and *before* the export: an
            // asset that may not be uploaded right now must not cost an iCloud
            // download and a SHA1 pass first. A manual run is an explicit user
            // action, so it overrides the policy like it overrides the gates.
            guard manual || isUploadAllowedNow(candidate, settings) else {
                deferredCount += 1
                deferralReason.insert(.waitingForWiFi)
                recordDeferral(candidate, reason: .waitingForWiFi)
                notifyProgress()
                if isCancelled { return await cancelStaging(&batch) }
                continue
            }

            let plan = plans[candidate.id] ?? ItemPlan(needsOriginal: true, needsEdit: false)

            // The edited rendering is exported before the original: an iCloud
            // rendering that is not local yet defers the whole element, and
            // the original must not be downloaded for nothing.
            var edit: StagedEdit?
            var renderingIsOriginal = false
            if plan.needsEdit {
                do {
                    edit = try await stageEdit(for: candidate)
                    // Adjusted, yet no edited resource: the current rendering
                    // is the original.
                    renderingIsOriginal = edit == nil
                } catch is BackupExportError {
                    deferredCount += 1
                    deferralReason.insert(.waitingForICloud)
                    recordDeferral(candidate, reason: .waitingForICloud)
                    statusMessage = nil
                    notifyProgress()
                    if isCancelled { return await cancelStaging(&batch) }
                    continue
                } catch {
                    if UserFacingError.isCancellation(error) {
                        if isCancelled { return await cancelStaging(&batch) }
                        continue
                    }
                    failures.append(BackupFailure(
                        assetID: candidate.id,
                        name: candidate.fileName,
                        reason: Self.editFailedReason,
                        fileSize: candidate.fileSize
                    ))
                    lastError = Self.editFailedReason
                    if !plan.needsOriginal {
                        // An edit-only element has nothing else to do: failed.
                        failedCount += 1
                        notifyProgress()
                        if isCancelled { return await cancelStaging(&batch) }
                        continue
                    }
                    // The original goes on alone; the warning stays listed.
                }
                if renderingIsOriginal && !plan.needsOriginal {
                    // Already on the server under the original's checksum:
                    // closed here, and recorded so no pass exports it again.
                    if let tracked = ledger.trackedEntry(id: candidate.id),
                       tracked.serverAssetId != nil, let checksum = tracked.checksum {
                        recordRenderingIsOriginal(candidate, originalChecksum: checksum)
                        rejectedCount += 1
                        backedUpIDs.insert(candidate.id)
                    } else {
                        failedCount += 1
                        failures.append(BackupFailure(
                            assetID: candidate.id,
                            name: candidate.fileName,
                            reason: Self.editFailedReason,
                            fileSize: candidate.fileSize
                        ))
                        lastError = Self.editFailedReason
                    }
                    notifyProgress()
                    if isCancelled { return await cancelStaging(&batch) }
                    continue
                }
            }

            do {
                var staged = StagedAsset(candidate: candidate, edit: edit, renderingIsOriginal: renderingIsOriginal)
                var size = Self.editBytes(staged)
                if plan.needsOriginal {
                    let fileURL = try await source.exportOriginal(for: candidate) { [weak self] state in
                        Task { @MainActor in self?.applyExportState(state) }
                    }
                    let checksum: String
                    do {
                        checksum = try await Task.detached(priority: .utility) {
                            try Self.streamingSHA1Base64(fileURL)
                        }.value
                    } catch {
                        Self.removeStagedFile(fileURL)
                        throw error
                    }
                    // Keep the exported original on disk so the upload phase streams
                    // straight from it — an iCloud-optimized library must not be
                    // downloaded twice (hash + upload).
                    size += Self.fileSize(fileURL)
                    var original = StagedOriginal(checksum: checksum, fileURL: fileURL)
                    if candidate.isLivePhoto {
                        var pairedURL: URL?
                        do {
                            if let paired = try await source.exportPairedVideo(for: candidate, onState: { [weak self] state in
                                Task { @MainActor in self?.applyExportState(state) }
                            }) {
                                pairedURL = paired.url
                                let pairedChecksum = try await Task.detached(priority: .utility) {
                                    try Self.streamingSHA1Base64(paired.url)
                                }.value
                                original.paired = StagedPairedVideo(
                                    url: paired.url, checksum: pairedChecksum,
                                    fileName: paired.fileName, duration: paired.duration
                                )
                                size += Self.fileSize(paired.url)
                            }
                        } catch {
                            // The still and its video share one fate: a still
                            // uploaded without its video is a dead Live Photo, and
                            // the server would then reject the still by checksum
                            // forever.
                            Self.removeStagedFile(fileURL)
                            if let pairedURL { Self.removeStagedFile(pairedURL) }
                            throw error
                        }
                    }
                    staged.original = original
                }
                batchBytes += size
                batch.append(staged)
                stagedCount += 1
                statusMessage = nil
                // Half a step banked: the export+hash of this asset is done.
                notifyProgress()
            } catch is BackupExportError {
                // iCloud original isn't local yet — not a failure. Deferred and
                // picked up on the next run once the download has landed. The
                // element's edit files go with it: the pass starts over.
                Self.removeStagedEdit(edit)
                deferredCount += 1
                deferralReason.insert(.waitingForICloud)
                recordDeferral(candidate, reason: .waitingForICloud)
                statusMessage = nil
                notifyProgress()
                if isCancelled { return await cancelStaging(&batch) }
                continue
            } catch {
                Self.removeStagedEdit(edit)
                if UserFacingError.isCancellation(error) {
                    if isCancelled { return await cancelStaging(&batch) }
                    continue
                }
                failedCount += 1
                lastError = error.userFacingMessage ?? UserFacingError.genericMessage
                failures.append(BackupFailure(
                    assetID: candidate.id,
                    name: candidate.fileName,
                    reason: error.userFacingMessage ?? UserFacingError.genericMessage,
                    fileSize: candidate.fileSize
                ))
                notifyProgress()
                if isCancelled { return await cancelStaging(&batch) }
                continue
            }
            if batch.count >= Self.checkChunkSize || batchBytes >= Self.maxBatchBytes {
                await processBatch(&batch)
                batchBytes = 0
                commitLedger()
                if isCancelled {
                    notifyProgress()
                    return await cancelStaging(&batch)
                }
            }
        }
        if !batch.isEmpty {
            if isCancelled {
                Self.removeStaged(batch)
                stagedCount = max(0, stagedCount - batch.count)
                batch.removeAll()
            } else {
                await processBatch(&batch)
            }
        }
        // Stacks left pending — by a failed `POST /api/stacks` of an earlier
        // pass, or by an original this pass has just learned the id of. A Stop
        // skips the pass.
        if settings.backUpEdits, !isCancelled {
            await stackPendingEdits(only: restricted ? Set(assetIDs) : nil)
        }
        currentFileName = nil
        currentAssetID = nil
        statusMessage = nil
        commitLedger()
        ledger.save()
        await flushAlbumMirror()
        phase = isCancelled ? .cancelled : .done
        return true
    }

    /// What one candidate needs, with the edit setting on.
    /// - `needsEdit`: adjusted in Photos, and the edit ledger lacks a rendering
    ///   for its current modification date.
    /// - `needsOriginal`: a restricted run (the user named it), or the original
    ///   ledger lacks it at this date, or an edit has to be sent or stacked and
    ///   the ledger knows neither the original's server id nor its checksum
    ///   (entries of the v1 and v2 files) — the original is then exported and
    ///   checked once, and the server's `reject` hands over the id.
    private func editPlan(for candidate: BackupCandidate, restricted: Bool) -> ItemPlan {
        let record = editLedger.record(id: candidate.id)
        let needsEdit = candidate.hasAdjustments && record?.signature != candidate.fileModifiedAt
        let tracked = ledger.trackedEntry(id: candidate.id)
        let originalUnknown = tracked?.serverAssetId == nil || tracked?.checksum == nil
        let editPending = needsEdit || record?.isStacked == false
        let needsOriginal = restricted
            || !ledger.isBackedUp(id: candidate.id, signature: candidate.fileModifiedAt)
            || (editPending && originalUnknown)
        return ItemPlan(needsOriginal: needsOriginal, needsEdit: needsEdit)
    }

    /// Exports the candidate's edited rendering (and a Live Photo's video) and
    /// hashes it by streaming. Nil when Photos has no edited resource. Throws
    /// like the original's export; its temp files are removed on a failed hash.
    private func stageEdit(for candidate: BackupCandidate) async throws -> StagedEdit? {
        guard let rendering = try await source.exportEditedRendering(for: candidate, onState: { [weak self] state in
            Task { @MainActor in self?.applyExportState(state) }
        }) else { return nil }
        do {
            let checksum = try await Task.detached(priority: .utility) {
                try Self.streamingSHA1Base64(rendering.url)
            }.value
            var paired: StagedPairedVideo?
            if let video = rendering.pairedVideo {
                let pairedChecksum = try await Task.detached(priority: .utility) {
                    try Self.streamingSHA1Base64(video.url)
                }.value
                paired = StagedPairedVideo(
                    url: video.url, checksum: pairedChecksum, fileName: video.fileName, duration: video.duration
                )
            }
            return StagedEdit(url: rendering.url, checksum: checksum, fileName: rendering.fileName, paired: paired)
        } catch {
            Self.removeStagedFile(rendering.url)
            if let video = rendering.pairedVideo { Self.removeStagedFile(video.url) }
            throw error
        }
    }

    /// Whether this candidate may be uploaded under the current network.
    /// Wi-Fi is always fine; on cellular the answer is per media kind, so a
    /// user can allow photos but not the multi-gigabyte videos.
    private func isUploadAllowedNow(_ candidate: BackupCandidate, _ settings: BackupSettings) -> Bool {
        if environment.hasWiFiConnection || !settings.onlyOnWiFi { return true }
        return candidate.kind == .image ? settings.allowCellularForPhotos : settings.allowCellularForVideos
    }

    /// Aborts the staging loop (`cancel()` / `stopAndWait()`): drops the chunk's
    /// temp files (Live Photo pairs included), releases their half-step
    /// progress credit, flushes whatever the mirror already buffered, and
    /// parks the engine in `.cancelled`.
    private func cancelStaging(_ batch: inout [StagedAsset]) async -> Bool {
        Self.removeStaged(batch)
        stagedCount = max(0, stagedCount - batch.count)
        batch.removeAll()
        // Same reset as a normal end: the Upload detail screen reads
        // `currentAssetID`, and a Stop must not leave it on the interrupted asset.
        currentFileName = nil
        currentAssetID = nil
        statusMessage = nil
        phase = .cancelled
        notifyProgress()
        // A cancelled run still mounted assets: without this flush they would
        // sit in the service's buffer and only reach their album on the next
        // run — or never, if the mirror is turned off in between.
        await flushAlbumMirror()
        return true
    }

    // MARK: - Album mirror (device → server)

    /// Resolves the device→server album map for this run, plus the inverse
    /// membership index the staging loop needs.
    ///
    /// A failure here must not interrupt the backup: the mirror is simply
    /// inactive for this run (`?? [:]`) and the upload carries on. Assets are
    /// then backed up and can be sorted into their album later with
    /// "Reorganize into album", which is exactly what that action is for.
    private func resolveAlbumMirror(settings: BackupSettings) async {
        albumMap = [:]
        albumMembership = [:]
        guard let userID = currentUserID(), !settings.syncedAlbumIDs.isEmpty else { return }
        let synced = settings.syncedAlbumIDs
        let source = self.source
        // Photos work on the utility queue, like the scan itself: enumerating
        // albums is heavy enough to stutter the UI on the main actor.
        let deviceAlbums = await Task.detached(priority: .utility) { source.fetchAlbums() }.value
        let membership = await Task.detached(priority: .utility) {
            source.albumMembership(deviceAlbumIDs: synced)
        }.value
        albumMembership = membership
        albumMap = (try? await albumSync.resolveAlbums(
            deviceAlbums: deviceAlbums,
            syncedDeviceAlbumIDs: synced,
            albumMembership: membership,
            userID: userID,
            client: client
        )) ?? [:]
    }

    /// Sends what the mirror buffered and publishes the result. Called at the
    /// end of a run and on the cancellation path — never per asset, or a run
    /// would make one `PUT /albums/{id}/assets` per photo.
    private func flushAlbumMirror() async {
        let albumSync = self.albumSync
        let client = self.client
        // Unstructured on purpose: it does not inherit the run's cancellation.
        // The service empties its buffer before sending, so a flush run inside
        // the cancelled pipeline Task would fail every PUT and lose those
        // album adds.
        let outcome = await Task { await albumSync.flush(client: client) }.value
        // An inactive mirror stays silent: a user who never picked an album
        // must not be shown "0 added · 0 already there · 0 failed".
        if !albumMap.isEmpty || !outcome.isEmpty { albumSyncOutcome = outcome }
    }

    /// Sorts the assets an earlier run already uploaded into the mirrored
    /// albums — no re-upload: each ledger entry's server id is recovered with
    /// `bulk-upload-check`. Backs "Reorganize into album".
    ///
    /// Resolves the albums first, exactly like a run, so an album whose server
    /// twin does not exist yet is created here instead of silently skipped.
    @discardableResult
    func reorganizeAlbums(
        entries: [(id: String, checksum: String)],
        syncedDeviceAlbumIDs: Set<String>
    ) async -> AlbumSyncOutcome {
        guard let userID = currentUserID(), !syncedDeviceAlbumIDs.isEmpty else { return AlbumSyncOutcome() }
        let source = self.source
        let deviceAlbums = await Task.detached(priority: .utility) { source.fetchAlbums() }.value
        let membership = await Task.detached(priority: .utility) {
            source.albumMembership(deviceAlbumIDs: syncedDeviceAlbumIDs)
        }.value
        albumMembership = membership
        albumMap = (try? await albumSync.resolveAlbums(
            deviceAlbums: deviceAlbums,
            syncedDeviceAlbumIDs: syncedDeviceAlbumIDs,
            albumMembership: membership,
            userID: userID,
            client: client
        )) ?? [:]
        let outcome = await albumSync.reorganize(
            entries: entries,
            albumMembership: membership,
            userID: userID,
            client: client
        )
        albumSyncOutcome = outcome
        return outcome
    }

    /// Dedup-checks one chunk's checksums against the server, then uploads each
    /// accepted candidate — one at a time — straight from the original that was
    /// already exported to disk during the hash pass (no second download from
    /// iCloud). A Live Photo uploads its paired video first, hidden, then the
    /// still carrying the video's id. Temp files for rejected candidates are
    /// deleted here; each upload's temp file is deleted right after it
    /// finishes. Progress is driven by `processedCount / total`, so the bar
    /// advances for every asset — uploaded, already-on-server, or failed —
    /// against the fixed run total.
    private func processBatch(_ batch: inout [StagedAsset]) async {
        let current = batch
        batch.removeAll()
        // Each staged asset holds half a progress unit until its outcome is
        // known; release them one at a time as outcomes land, so the bar keeps
        // climbing inside the chunk instead of stepping once at its end. The
        // defer covers assets the server answered for neither way.
        var held = current.count
        func release(_ n: Int = 1) {
            let amount = min(n, held)
            held -= amount
            stagedCount = max(0, stagedCount - amount)
        }
        defer { release(held) }

        // One request for the whole chunk: each staged original under its own
        // id, each edited rendering under `<id>#edit`.
        var items: [AssetBulkUploadCheckRequest.Item] = []
        for entry in current {
            if let original = entry.original {
                items.append(AssetBulkUploadCheckRequest.Item(id: entry.candidate.id, checksum: original.checksum))
            }
            if let edit = entry.edit {
                items.append(AssetBulkUploadCheckRequest.Item(id: Self.editCheckID(entry.candidate.id), checksum: edit.checksum))
            }
        }
        // Per-asset lookup for the two paths that need more than the result:
        // the ledger record (reject = already on the server) and the Live Photo
        // repair (the reject carries the remote `assetId` to attach to).
        let entriesByID = Dictionary(
            current.map { ($0.candidate.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var acceptIDs: Set<String> = []
        // An original the server already holds whose element also carries an
        // edit: its outcome waits for the edit, so it is acted on below.
        var heldRejects: [String: AssetBulkUploadCheckResponse.Result] = [:]
        var editResults: [String: AssetBulkUploadCheckResponse.Result] = [:]
        do {
            let response = try await client.bulkUploadCheck(AssetBulkUploadCheckRequest(assets: items))
            for result in response.results {
                if let candidateID = Self.editCandidateID(result.id) {
                    editResults[candidateID] = result
                } else if result.action == "accept" {
                    acceptIDs.insert(result.id)
                } else if let entry = entriesByID[result.id], entry.edit != nil {
                    heldRejects[result.id] = result
                } else {
                    rejectedCount += 1
                    release()
                    if let entry = entriesByID[result.id], let original = entry.original {
                        // The ledger is written only once the Live Photo video
                        // (if any) is uploaded and linked.
                        if await repairLivePhotoIfNeeded(
                            entry,
                            remoteAssetID: result.assetId,
                            isTrashed: result.isTrashed == true
                        ) {
                            ledger.markBackedUp(
                                id: result.id,
                                signature: entry.candidate.fileModifiedAt,
                                checksum: original.checksum,
                                // A reject means the server already has this
                                // checksum, and it answers with the UUID it holds
                                // it under — the id the timeline renders. The DTO
                                // only requires `action` and `id`, so it can be
                                // absent; that is not a reason to forget an id
                                // learned by an earlier run.
                                serverAssetId: result.assetId
                            )
                            backedUpIDs.insert(result.id)
                            if entry.renderingIsOriginal {
                                recordRenderingIsOriginal(entry.candidate, originalChecksum: original.checksum)
                            }
                        }
                    }
                }
            }
        } catch {
            Self.removeStaged(current)
            release(current.count)
            if UserFacingError.isCancellation(error) {
                if isCancelled { phase = .cancelled }
                notifyProgress()
                return
            }
            failedCount += current.count
            for entry in current {
                failures.append(BackupFailure(
                    assetID: entry.candidate.id,
                    name: entry.candidate.fileName,
                    reason: error.userFacingMessage ?? UserFacingError.genericMessage,
                    fileSize: Self.stagedFileSize(entry)
                ))
            }
            lastError = error.userFacingMessage ?? UserFacingError.genericMessage
            notifyProgress()
            if isCancelled { phase = .cancelled }
            return
        }

        // What still needs the network: accepted originals, originals held back
        // for their edit, and edit-only elements the server answered for.
        let work = current.filter { entry in
            let id = entry.candidate.id
            if entry.original != nil { return acceptIDs.contains(id) || heldRejects[id] != nil }
            return editResults[id] != nil
        }
        let workIDs = Set(work.map(\.candidate.id))
        // Drop the files we won't upload — the repairs above already read what
        // they needed from their paired temp file.
        Self.removeStaged(current.filter { !workIDs.contains($0.candidate.id) })
        for entry in work where !acceptIDs.contains(entry.candidate.id) { Self.removeOriginal(entry) }
        if current.count > work.count { notifyProgress() }

        guard !work.isEmpty else { return }
        if phase != .uploading {
            phase = .uploading
            if startedAt == nil { startedAt = Date() }
        }

        for (i, entry) in work.enumerated() {
            if isCancelled {
                Self.removeStaged(Array(work[i...]))
                release(work[i...].count)
                phase = .cancelled
                notifyProgress()
                return
            }
            let candidate = entry.candidate
            currentFileName = candidate.fileName
            currentAssetID = candidate.id

            // Closes one element: its temp files, the status line and its
            // half-step of progress.
            func finishElement() {
                Self.removeStaged([entry])
                statusMessage = nil
                release()
                notifyProgress()
            }

            var originalSent = false
            if let original = entry.original {
                if acceptIDs.contains(candidate.id) {
                    // The video goes up first, in `.hidden`, so it never shows
                    // alone in the timeline; the still then carries its id. The
                    // other order leaves a dead image visible for the length of
                    // the video upload.
                    var livePhotoVideoID: String?
                    if let paired = original.paired {
                        do {
                            let video = try await client.uploadAsset(
                                fileURL: paired.url,
                                fileCreatedAt: candidate.fileCreatedAt,
                                fileModifiedAt: candidate.fileModifiedAt,
                                filename: paired.fileName,
                                duration: paired.duration,
                                isFavorite: false,
                                visibility: .hidden,
                                livePhotoVideoId: nil,
                                checksum: paired.checksum,
                                deviceAssetId: candidate.id,
                                deviceId: DeviceIdentity.current
                            )
                            livePhotoVideoID = video.id
                        } catch {
                            // Without the video the still would be a dead Live
                            // Photo on the server, and forever rejected by
                            // checksum afterwards.
                            finishElement()
                            if UserFacingError.isCancellation(error) { continue }
                            failedCount += 1
                            lastError = error.userFacingMessage ?? UserFacingError.genericMessage
                            failures.append(BackupFailure(
                                assetID: candidate.id,
                                name: candidate.fileName,
                                reason: error.userFacingMessage ?? UserFacingError.genericMessage,
                                fileSize: Self.stagedFileSize(entry)
                            ))
                            continue
                        }
                    }
                    do {
                        let uploaded = try await client.uploadAsset(
                            fileURL: original.fileURL,
                            fileCreatedAt: candidate.fileCreatedAt,
                            fileModifiedAt: candidate.fileModifiedAt,
                            filename: candidate.fileName,
                            duration: candidate.duration,
                            isFavorite: candidate.isFavorite,
                            visibility: .timeline,
                            livePhotoVideoId: livePhotoVideoID,
                            checksum: original.checksum,
                            deviceAssetId: candidate.id,
                            deviceId: DeviceIdentity.current
                        )
                        uploadedCount += 1
                        originalSent = true
                        let bytes = Self.originalBytes(entry)
                        if bytes > 0 { uploadedBytes += Int64(bytes) }
                        ledger.markBackedUp(
                            id: candidate.id,
                            signature: candidate.fileModifiedAt,
                            checksum: original.checksum,
                            // The UUID the timeline will render for this asset — the
                            // only moment the client is told it.
                            serverAssetId: uploaded.id
                        )
                        backedUpIDs.insert(candidate.id)
                        if entry.renderingIsOriginal {
                            recordRenderingIsOriginal(candidate, originalChecksum: original.checksum)
                        }
                        // The id just returned is the only chance to place this
                        // asset in its mirror album without another server
                        // round-trip: the ledger keeps no server id, so a missed
                        // one costs a `bulk-upload-check` later.
                        if !albumMap.isEmpty {
                            await albumSync.stage(assetID: uploaded.id, deviceAssetID: candidate.id)
                        }
                    } catch {
                        // A cancelled upload is not a failure: no count, no
                        // failure entry, no message. Its staged file is released
                        // below. A failed original abandons the edit with it.
                        if !UserFacingError.isCancellation(error) {
                            failedCount += 1
                            lastError = error.userFacingMessage ?? UserFacingError.genericMessage
                            failures.append(BackupFailure(
                                assetID: candidate.id,
                                name: candidate.fileName,
                                reason: error.userFacingMessage ?? UserFacingError.genericMessage,
                                fileSize: Self.stagedFileSize(entry)
                            ))
                        }
                        finishElement()
                        continue
                    }
                } else if let result = heldRejects[candidate.id] {
                    if await repairLivePhotoIfNeeded(
                        entry,
                        remoteAssetID: result.assetId,
                        isTrashed: result.isTrashed == true
                    ) {
                        ledger.markBackedUp(
                            id: candidate.id,
                            signature: candidate.fileModifiedAt,
                            checksum: original.checksum,
                            serverAssetId: result.assetId
                        )
                        backedUpIDs.insert(candidate.id)
                    } else {
                        // The original's own outcome is the element's: the Live
                        // Photo link was not written, so the edit is dropped.
                        rejectedCount += 1
                        finishElement()
                        continue
                    }
                }
            }

            var step = EditStepResult()
            if let edit = entry.edit, let check = editResults[candidate.id] {
                step = await processEdit(entry, edit: edit, check: check)
                if entry.original == nil, step.recorded { backedUpIDs.insert(candidate.id) }
            }
            if !originalSent {
                // One outcome per element: sent if the edit went up, else
                // already on the server — unless it failed or was cancelled.
                if step.uploaded {
                    uploadedCount += 1
                } else if !step.failedCounted && !step.cancelled {
                    rejectedCount += 1
                }
            }
            finishElement()
        }
    }

    private struct EditStepResult {
        /// The edited rendering was sent in this pass.
        var uploaded = false
        /// The element was counted as failed (an edit-only element whose edit
        /// could not be sent). An element whose original was handled in the same
        /// pass gets a warning instead and is never counted.
        var failedCounted = false
        var cancelled = false
        /// The edit ledger now holds the rendering (stack done or pending).
        var recorded = false
    }

    /// Sends one element's edited rendering, files it in the mirrored albums
    /// and stacks it on its original, writing the edit ledger at the end.
    /// `check` is the server's answer for the rendering's checksum.
    private func processEdit(
        _ entry: StagedAsset,
        edit: StagedEdit,
        check: AssetBulkUploadCheckResponse.Result
    ) async -> EditStepResult {
        let candidate = entry.candidate
        let originalHandled = entry.original != nil
        var step = EditStepResult()

        func reportEditFailure() {
            let reason = Self.editFailedReason
            failures.append(BackupFailure(
                assetID: candidate.id,
                name: candidate.fileName,
                reason: reason,
                fileSize: Self.stagedFileSize(entry)
            ))
            lastError = reason
            if !originalHandled {
                failedCount += 1
                step.failedCounted = true
            }
        }

        let editServerID: String
        if check.action == "accept" {
            var videoID: String?
            if let paired = edit.paired {
                do {
                    let video = try await client.uploadAsset(
                        fileURL: paired.url,
                        fileCreatedAt: candidate.fileCreatedAt,
                        fileModifiedAt: candidate.fileModifiedAt,
                        filename: paired.fileName,
                        duration: paired.duration,
                        isFavorite: false,
                        visibility: .hidden,
                        livePhotoVideoId: nil,
                        checksum: paired.checksum,
                        deviceAssetId: candidate.id,
                        deviceId: DeviceIdentity.current
                    )
                    videoID = video.id
                } catch {
                    if UserFacingError.isCancellation(error) { step.cancelled = true } else { reportEditFailure() }
                    return step
                }
            }
            do {
                let uploaded = try await client.uploadAsset(
                    fileURL: edit.url,
                    fileCreatedAt: candidate.fileCreatedAt,
                    fileModifiedAt: candidate.fileModifiedAt,
                    filename: edit.fileName,
                    duration: candidate.duration,
                    isFavorite: candidate.isFavorite,
                    visibility: .timeline,
                    livePhotoVideoId: videoID,
                    checksum: edit.checksum,
                    deviceAssetId: candidate.id,
                    deviceId: DeviceIdentity.current
                )
                editServerID = uploaded.id
            } catch {
                if UserFacingError.isCancellation(error) { step.cancelled = true } else { reportEditFailure() }
                return step
            }
            step.uploaded = true
            uploadedBytes += Int64(Self.editBytes(entry))
            // The edit joins the mirrored albums its original is filed in.
            if !albumMap.isEmpty {
                await albumSync.stage(assetID: editServerID, deviceAssetID: candidate.id)
            }
        } else if let existing = check.assetId {
            // The server already holds these bytes (a retry after a failed
            // stack, or "Reset backup tracking"): nothing to send.
            editServerID = existing
        } else {
            reportEditFailure()
            return step
        }

        // The original's server id: the one this pass just learned, else the
        // ledger's (see `originalUnknown`).
        let originalServerID = ledger.trackedEntry(id: candidate.id)?.serverAssetId
        let previous = editLedger.record(id: candidate.id)
        if let previous, previous.serverAssetId == editServerID, previous.isStacked {
            // Same rendering, already stacked: only the date moved (a metadata
            // change such as a favorite) — no request.
            var updated = previous
            updated.signature = candidate.fileModifiedAt
            editLedger.upsert(id: candidate.id, updated)
            step.recorded = true
            return step
        }
        let previousHead = previous.flatMap {
            $0.serverAssetId == editServerID ? $0.previousServerAssetId : $0.serverAssetId
        }
        stackAttemptedIDs.insert(candidate.id)
        var isStacked = false
        var keptPrevious = previousHead
        switch await stackOnOriginal(editID: editServerID, previousID: previousHead, originalID: originalServerID) {
        case .stacked(let droppedPrevious):
            isStacked = true
            if droppedPrevious { keptPrevious = nil }
        case .failed:
            reportStackWarning(assetID: candidate.id, name: candidate.fileName)
        case .cancelled:
            break
        }
        editLedger.upsert(id: candidate.id, BackupEditRecord(
            signature: candidate.fileModifiedAt,
            checksum: edit.checksum,
            serverAssetId: editServerID,
            originalServerAssetId: originalServerID,
            previousServerAssetId: keptPrevious,
            isStacked: isStacked,
            fileName: edit.fileName
        ))
        step.recorded = true
        return step
    }

    private enum StackResult {
        case stacked(droppedPrevious: Bool)
        case failed
        case cancelled
    }

    /// `POST /api/stacks` with the edit in front, then the previous head, then
    /// the original (the server makes the first id the primary and merges any
    /// stack whose primary is in the list). A 400 means an id is unknown to the
    /// server — a stale previous head — so it is tried once more without it.
    private func stackOnOriginal(editID: String, previousID: String?, originalID: String?) async -> StackResult {
        let ids = Self.distinct([editID, previousID, originalID])
        guard ids.count >= 2 else { return .failed }
        do {
            _ = try await client.createStack(assetIds: ids)
            return .stacked(droppedPrevious: false)
        } catch {
            if UserFacingError.isCancellation(error) { return .cancelled }
            guard case APIError.serverError(400, _) = error, let previousID, ids.contains(previousID) else {
                return .failed
            }
            let retry = Self.distinct([editID, originalID])
            guard retry.count >= 2 else { return .failed }
            do {
                _ = try await client.createStack(assetIds: retry)
                return .stacked(droppedPrevious: true)
            } catch {
                return UserFacingError.isCancellation(error) ? .cancelled : .failed
            }
        }
    }

    private static func distinct(_ ids: [String?]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { $0 }.filter { seen.insert($0).inserted }
    }

    /// The edit is on the server but not stacked: a warning (never a failed
    /// element), retried by the next pass without sending the file again.
    private func reportStackWarning(assetID: String, name: String) {
        let reason = Self.editStackFailedReason
        failures.append(BackupFailure(assetID: assetID, name: name, reason: reason, fileSize: nil))
        lastError = reason
    }

    /// Builds the stacks still pending in the edit ledger. Runs once per
    /// pass, after the last chunk: the chunks may just have written the id of
    /// an original the ledger lacked. Sends, exports and hashes nothing, and
    /// is outside the run's total and progress.
    private func stackPendingEdits(only restrictedIDs: Set<String>?) async {
        for id in editLedger.pendingStackIDs() {
            if isCancelled { return }
            if stackAttemptedIDs.contains(id) { continue }
            if let restrictedIDs, !restrictedIDs.contains(id) { continue }
            guard let record = editLedger.record(id: id) else { continue }
            // The ledger's id first: an original purged, forgotten and sent
            // again has a new one.
            let originalID = ledger.trackedEntry(id: id)?.serverAssetId ?? record.originalServerAssetId
            guard Self.distinct([record.serverAssetId, record.previousServerAssetId, originalID]).count >= 2 else {
                continue
            }
            switch await stackOnOriginal(
                editID: record.serverAssetId, previousID: record.previousServerAssetId, originalID: originalID
            ) {
            case .stacked(let droppedPrevious):
                var updated = record
                updated.isStacked = true
                updated.originalServerAssetId = originalID
                if droppedPrevious { updated.previousServerAssetId = nil }
                editLedger.upsert(id: id, updated)
            case .failed:
                failures.append(BackupFailure(
                    assetID: id, name: record.fileName, reason: Self.editStackFailedReason, fileSize: nil
                ))
                lastError = Self.editStackFailedReason
            case .cancelled:
                return
            }
        }
    }

    /// An asset Photos reports as edited but without any edited resource: its
    /// current rendering *is* the original. Recorded so no later pass exports
    /// it again, and so Free Up Space confirms it through the original's
    /// checksum. An existing record only has its date moved.
    private func recordRenderingIsOriginal(_ candidate: BackupCandidate, originalChecksum: String) {
        if var existing = editLedger.record(id: candidate.id) {
            existing.signature = candidate.fileModifiedAt
            editLedger.upsert(id: candidate.id, existing)
        } else if let originalID = ledger.trackedEntry(id: candidate.id)?.serverAssetId {
            editLedger.upsert(id: candidate.id, BackupEditRecord(
                signature: candidate.fileModifiedAt,
                checksum: originalChecksum,
                serverAssetId: originalID,
                originalServerAssetId: originalID,
                previousServerAssetId: nil,
                isStacked: true,
                fileName: candidate.fileName
            ))
        }
    }

    static var editFailedReason: String { String(localized: "The edited version could not be backed up.") }
    static var editStackFailedReason: String {
        String(localized: "The edited version was backed up but could not be stacked on the original.")
    }

    private static let editCheckSuffix = "#edit"
    private static func editCheckID(_ id: String) -> String { id + editCheckSuffix }
    private static func editCandidateID(_ checkID: String) -> String? {
        checkID.hasSuffix(editCheckSuffix) ? String(checkID.dropLast(editCheckSuffix.count)) : nil
    }

    /// A Live Photo whose still is already on the server ("reject") may have
    /// been uploaded as a dead image by an earlier run. The reject carries the
    /// remote `assetId`, so the missing video is uploaded and linked onto it:
    /// without this path those Live Photos stay broken forever — the server
    /// keeps rejecting the still by checksum and "Reset backup tracking" does
    /// not help. The repair is idempotent (a duplicate video upload returns the
    /// existing id, and the PUT is absolute).
    ///
    /// Returns whether the ledger may now be written for this asset: only after
    /// the video is uploaded and linked (or there is nothing to link). A failed
    /// or cancelled repair leaves the asset out of the ledger, so the next run
    /// (or a restricted retry) goes through here again instead of filtering a
    /// dead Live Photo out as done.
    private func repairLivePhotoIfNeeded(_ entry: StagedAsset, remoteAssetID: String?, isTrashed: Bool) async -> Bool {
        guard let paired = entry.original?.paired else { return true }
        guard !isTrashed else { return true }
        guard let remoteAssetID else {
            // The server holds the still but did not say under which id, so the
            // video cannot be attached: a warning, and no ledger entry.
            let reason = String(localized: "The Live Photo video could not be linked.")
            failures.append(BackupFailure(
                assetID: entry.candidate.id,
                name: entry.candidate.fileName,
                reason: reason,
                fileSize: Self.stagedFileSize(entry)
            ))
            lastError = reason
            return false
        }
        do {
            let video = try await client.uploadAsset(
                fileURL: paired.url,
                fileCreatedAt: entry.candidate.fileCreatedAt,
                fileModifiedAt: entry.candidate.fileModifiedAt,
                filename: paired.fileName,
                duration: paired.duration,
                isFavorite: false,
                visibility: .hidden,
                livePhotoVideoId: nil,
                checksum: paired.checksum,
                deviceAssetId: entry.candidate.id,
                deviceId: DeviceIdentity.current
            )
            _ = try await client.updateAsset(
                id: remoteAssetID,
                dto: UpdateAssetDto(livePhotoVideoId: video.id)
            )
            return true
        } catch {
            // The still IS on the server, so this is a warning, not a failed
            // asset: recorded for the failures list, retried next run.
            // A cancelled link is simply not done: nothing to record.
            guard !UserFacingError.isCancellation(error) else { return false }
            failures.append(BackupFailure(
                assetID: entry.candidate.id,
                name: entry.candidate.fileName,
                reason: error.userFacingMessage ?? UserFacingError.genericMessage,
                fileSize: Self.stagedFileSize(entry)
            ))
            lastError = error.userFacingMessage ?? UserFacingError.genericMessage
            return false
        }
    }

    /// Confronts the ledger with the server. Without this the ledger is only
    /// ever invalidated by the destructive "Reset backup tracking", so an asset
    /// deleted server-side stays marked as backed up and is filtered out of
    /// every run — it never comes back.
    ///
    /// The pass costs no media bytes: the checksums are already stored, so it
    /// is one `bulk-upload-check` per `checkChunkSize` tracked entries, at most
    /// once per `reconcileInterval`. A network error is not a run failure — the
    /// pass is abandoned and retried when next due.
    private func reconcileLedgerIfDue(force: Bool = false, includeEdits: Bool = false) async {
        guard environment.isOnline else { return }
        if !force, let last = ledger.lastReconciliation,
           Date().timeIntervalSince(last) < Self.reconcileInterval {
            return
        }
        var entries = ledger.entriesForReconciliation()
        // The edited renderings ride in the same chunks under `<id>#edit`. An
        // `accept` on one forgets the edit only — never the original.
        if includeEdits {
            entries += editLedger.entriesForReconciliation().map {
                (id: Self.editCheckID($0.id), checksum: $0.checksum)
            }
        }
        var forgotten: [String] = []
        var forgottenEdits: [String] = []
        var index = 0
        while index < entries.count {
            let chunk = Array(entries[index..<min(index + Self.checkChunkSize, entries.count)])
            index += Self.checkChunkSize
            statusMessage = String(localized: "Checking server…")
            do {
                let response = try await client.bulkUploadCheck(
                    AssetBulkUploadCheckRequest(assets: chunk.map {
                        AssetBulkUploadCheckRequest.Item(id: $0.id, checksum: $0.checksum)
                    })
                )
                for result in response.results where result.action == "accept" {
                    // `accept` = the server no longer has it (deleted, purged,
                    // restored from an older backup, other account) → forget, so
                    // the scan that follows re-uploads it. A trashed asset comes
                    // back as a `reject` with `isTrashed`, so it is kept.
                    if let editID = Self.editCandidateID(result.id) {
                        forgottenEdits.append(editID)
                    } else {
                        forgotten.append(result.id)
                    }
                }
            } catch {
                // Not a run failure: abandon the pass, retry when next due.
                statusMessage = nil
                return
            }
        }
        ledger.forget(ids: forgotten)
        editLedger.forget(ids: forgottenEdits)
        ledger.recordReconciliation(at: Date())
        commitLedger()
        statusMessage = nil
    }

    /// When the ledger was last confronted with the server (nil = never).
    var lastReconciliation: Date? { ledger.lastReconciliation }

    /// Runs the reconciliation now, ignoring the weekly throttle. Backs the
    /// non-destructive "Check server now" action.
    func reconcileNow(includeEdits: Bool = false) async {
        await reconcileLedgerIfDue(force: true, includeEdits: includeEdits)
    }

    /// Maps a per-asset export event into the observable `statusMessage` — kept
    /// as-is for the Backup screen, which owns that line — and into the
    /// per-asset maps the detail screen reads, so an iCloud download can be
    /// attributed to the asset it belongs to.
    private func applyExportState(_ state: BackupExportState) {
        switch state {
        case .downloadingFromICloud(let fraction):
            let clamped = min(max(fraction, 0), 1)
            if let id = currentAssetID { iCloudProgress[id] = clamped }
            let pct = Int((clamped * 100).rounded())
            statusMessage = String(localized: "Downloading from iCloud… \(pct)%")
        case .retryingICloud(let attempt):
            if let id = currentAssetID { iCloudRetryAttempts[id] = attempt }
            statusMessage = String(localized: "iCloud not ready yet — retrying (\(attempt))…")
        }
    }

    /// Records a held-back asset, replacing the entry of the same asset rather
    /// than appending a second one: the same asset can come back through a run
    /// more than once (a retry, a source that yields it twice), and "held back"
    /// is a state, not an event log.
    private func recordDeferral(_ candidate: BackupCandidate, reason: BackupDeferralReason) {
        let entry = BackupDeferral(
            id: candidate.id,
            name: candidate.fileName,
            reason: reason,
            fileSize: candidate.fileSize,
            kind: candidate.kind
        )
        if let index = deferrals.firstIndex(where: { $0.id == candidate.id }) {
            deferrals[index] = entry
        } else {
            deferrals.append(entry)
        }
    }

    /// Bytes the run measured on disk for one staged entry — the original plus,
    /// for a Live Photo, the paired video, plus the edited rendering (and its
    /// paired video). `nil` when the temp files are unreadable, so a failure
    /// line says "Unknown size" instead of "0 B".
    private static func stagedFileSize(_ entry: StagedAsset) -> Int64? {
        let bytes = originalBytes(entry) + editBytes(entry)
        return bytes > 0 ? Int64(bytes) : nil
    }

    private static func originalBytes(_ entry: StagedAsset) -> Int {
        guard let original = entry.original else { return 0 }
        var bytes = fileSize(original.fileURL)
        if let paired = original.paired { bytes += fileSize(paired.url) }
        return bytes
    }

    private static func editBytes(_ entry: StagedAsset) -> Int {
        guard let edit = entry.edit else { return 0 }
        var bytes = fileSize(edit.url)
        if let paired = edit.paired { bytes += fileSize(paired.url) }
        return bytes
    }

    /// Size of a temp export, for the chunk's disk budget. 0 when unreadable —
    /// the budget is a guard rail, not a ledger.
    private static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    }

    /// Best-effort delete of one temp file.
    private static func removeStagedFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes everything a chunk owns — the exported original, the edited
    /// rendering and, for a Live Photo, their paired videos. The single cleanup
    /// entry point on purpose: a missed pair leaks a second full-quality file
    /// per asset, and a cancelled run touches every exit path.
    private static func removeStaged(_ entries: [StagedAsset]) {
        for entry in entries {
            removeOriginal(entry)
            removeEdit(entry)
        }
    }

    private static func removeOriginal(_ entry: StagedAsset) {
        guard let original = entry.original else { return }
        removeStagedFile(original.fileURL)
        if let paired = original.paired { removeStagedFile(paired.url) }
    }

    private static func removeEdit(_ entry: StagedAsset) {
        removeStagedEdit(entry.edit)
    }

    private static func removeStagedEdit(_ edit: StagedEdit?) {
        guard let edit else { return }
        removeStagedFile(edit.url)
        if let paired = edit.paired { removeStagedFile(paired.url) }
    }

    /// base64-encoded SHA1 of a file's bytes (matches `x-immich-checksum`),
    /// computed by streaming the file in 64 KiB POSIX chunks — never loads the
    /// whole file into memory. Uses POSIX `open`/`read`/`close` instead of
    /// `FileHandle` to give the OS a clean file descriptor signal for memory
    /// reclamation during large-file hashing.
    nonisolated static func streamingSHA1Base64(_ fileURL: URL) throws -> String {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open \(fileURL.path)"])
        }
        defer { close(fd) }
        var hasher = Insecure.SHA1()
        let bufSize = 64 << 10 // 64KB chunks
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, bufSize)
            if n < 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "Read error: \(String(cString: strerror(errno)))"])
            }
            if n == 0 { break } // EOF
            hasher.update(data: Data(bytes: buf, count: n))
        }
        return Data(hasher.finalize()).base64EncodedString()
    }

    private func reset() {
        isCancelled = false
        isCancelling = false
        total = 0
        uploadedCount = 0
        rejectedCount = 0
        failedCount = 0
        deferredCount = 0
        deferralReason = []
        stagedCount = 0
        statusMessage = nil
        currentFileName = nil
        currentAssetID = nil
        failures = []
        deferrals = []
        backedUpIDs = []
        iCloudProgress = [:]
        iCloudRetryAttempts = [:]
        uploadedBytes = 0
        startedAt = nil
        albumMap = [:]
        albumMembership = [:]
        albumSyncOutcome = nil
        stackAttemptedIDs = []
    }
}