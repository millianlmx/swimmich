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
        onLedgerChange?()
    }

    /// Fires the progress callback with the current processed count.
    private func notifyProgress() { onProgressUpdate?(processedCount, total) }

    private var isCancelled = false
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

    /// One candidate whose original is exported + hashed and waiting on disk
    /// for the dedup/upload chunk. A Live Photo also stages its paired video.
    private struct StagedAsset {
        let candidate: BackupCandidate
        let checksum: String
        let fileURL: URL
        var paired: PairedVideo?

        struct PairedVideo {
            let url: URL
            let checksum: String
            let fileName: String
            let duration: Int
        }
    }
    init(
        client: any ImmichClient,
        source: any BackupAssetSource,
        environment: any BackupEnvironment = SystemBackupEnvironment(),
        ledger: any BackupLedgerStoring = BackupLedger.inMemory(),
        albumSync: (any AlbumSyncServicing)? = nil,
        userID: (@MainActor () -> String?)? = nil
    ) {
        self.client = client
        self.source = source
        self.environment = environment
        self.ledger = ledger
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
        onLedgerChange?()
    }

    /// Async-cancellation — no preconditions, engine decides at the next item
    /// boundary. Call from a BG expiration handler.
    func cancel() {
        isCancelled = true
        isCancelling = true
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
        guard !(isCancelled || phase == .uploading || phase == .checking) else {
            if isCancelled { phase = .cancelled }
            return false
        }
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
        let restricted = !assetIDs.isEmpty
        if !restricted {
            // Confront the ledger with the server BEFORE scanning: an asset
            // deleted server-side is forgotten here, so it is a candidate in
            // this very run. A retry has no scan to reconcile for.
            await reconcileLedgerIfDue()
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
        if !restricted {
            remaining = remaining.filter { !ledger.isBackedUp(id: $0.id, signature: $0.fileModifiedAt) }
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

            do {
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
                var size = Self.fileSize(fileURL)
                var staged = StagedAsset(candidate: candidate, checksum: checksum, fileURL: fileURL)
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
                            staged.paired = StagedAsset.PairedVideo(
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
                batchBytes += size
                batch.append(staged)
                stagedCount += 1
                statusMessage = nil
                // Half a step banked: the export+hash of this asset is done.
                notifyProgress()
            } catch is BackupExportError {
                // iCloud original isn't local yet — not a failure. Deferred and
                // picked up on the next run once the download has landed.
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
        currentFileName = nil
        currentAssetID = nil
        statusMessage = nil
        commitLedger()
        ledger.save()
        await flushAlbumMirror()
        phase = isCancelled ? .cancelled : .done
        return true
    }

    /// Whether this candidate may be uploaded under the current network.
    /// Wi-Fi is always fine; on cellular the answer is per media kind, so a
    /// user can allow photos but not the multi-gigabyte videos.
    private func isUploadAllowedNow(_ candidate: BackupCandidate, _ settings: BackupSettings) -> Bool {
        if environment.hasWiFiConnection || !settings.onlyOnWiFi { return true }
        return candidate.kind == .image ? settings.allowCellularForPhotos : settings.allowCellularForVideos
    }

    /// Aborts the staging loop: drops the chunk's temp files (Live Photo pairs
    /// included), releases their half-step progress credit, flushes whatever the
    /// mirror already buffered, and parks the engine in `.cancelled`.
    private func cancelStaging(_ batch: inout [StagedAsset]) async -> Bool {
        Self.removeStaged(batch)
        stagedCount = max(0, stagedCount - batch.count)
        batch.removeAll()
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
        let outcome = await albumSync.flush(client: client)
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

        let items = current.map {
            AssetBulkUploadCheckRequest.Item(id: $0.candidate.id, checksum: $0.checksum)
        }
        // Per-asset lookup for the two paths that need more than the result:
        // the ledger record (reject = already on the server) and the Live Photo
        // repair (the reject carries the remote `assetId` to attach to).
        let entriesByID = Dictionary(
            current.map { ($0.candidate.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var acceptIDs: Set<String> = []
        do {
            let response = try await client.bulkUploadCheck(AssetBulkUploadCheckRequest(assets: items))
            for result in response.results {
                if result.action == "accept" {
                    acceptIDs.insert(result.id)
                } else {
                    rejectedCount += 1
                    release()
                    if let entry = entriesByID[result.id] {
                        ledger.markBackedUp(
                            id: result.id,
                            signature: entry.candidate.fileModifiedAt,
                            checksum: entry.checksum,
                            // A reject means the server already has this
                            // checksum, and it answers with the UUID it holds
                            // it under — the id the timeline renders. The DTO
                            // only requires `action` and `id`, so it can be
                            // absent; that is not a reason to forget an id
                            // learned by an earlier run.
                            serverAssetId: result.assetId
                        )
                        await repairLivePhotoIfNeeded(
                            entry,
                            remoteAssetID: result.assetId,
                            isTrashed: result.isTrashed == true
                        )
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

        // Drop the originals we won't upload — the repairs above already read
        // what they needed from their paired temp file.
        Self.removeStaged(current.filter { !acceptIDs.contains($0.candidate.id) })
        if current.count > acceptIDs.count { notifyProgress() }

        let uploads = current.filter { acceptIDs.contains($0.candidate.id) }
        guard !uploads.isEmpty else { return }
        if phase != .uploading {
            phase = .uploading
            if startedAt == nil { startedAt = Date() }
        }

        for (i, entry) in uploads.enumerated() {
            if isCancelled {
                Self.removeStaged(Array(uploads[i...]))
                release(uploads[i...].count)
                phase = .cancelled
                notifyProgress()
                return
            }
            currentFileName = entry.candidate.fileName
            currentAssetID = entry.candidate.id

            // The video goes up first, in `.hidden`, so it never shows alone in
            // the timeline; the still then carries its id. The other order
            // leaves a dead image visible for the length of the video upload.
            var livePhotoVideoID: String?
            if let paired = entry.paired {
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
                    livePhotoVideoID = video.id
                } catch {
                    // Without the video the still would be a dead Live Photo on
                    // the server, and forever rejected by checksum afterwards.
                    Self.removeStaged([entry])
                    release()
                    notifyProgress()
                    if UserFacingError.isCancellation(error) { continue }
                    failedCount += 1
                    lastError = error.userFacingMessage ?? UserFacingError.genericMessage
                    failures.append(BackupFailure(
                        assetID: entry.candidate.id,
                        name: entry.candidate.fileName,
                        reason: error.userFacingMessage ?? UserFacingError.genericMessage,
                        fileSize: Self.stagedFileSize(entry)
                    ))
                    continue
                }
            }
            do {
                let uploaded = try await client.uploadAsset(
                    fileURL: entry.fileURL,
                    fileCreatedAt: entry.candidate.fileCreatedAt,
                    fileModifiedAt: entry.candidate.fileModifiedAt,
                    filename: entry.candidate.fileName,
                    duration: entry.candidate.duration,
                    isFavorite: entry.candidate.isFavorite,
                    visibility: .timeline,
                    livePhotoVideoId: livePhotoVideoID,
                    checksum: entry.checksum,
                    deviceAssetId: entry.candidate.id,
                    deviceId: DeviceIdentity.current
                )
                uploadedCount += 1
                if let bytes = Self.stagedFileSize(entry) { uploadedBytes += bytes }
                ledger.markBackedUp(
                    id: entry.candidate.id,
                    signature: entry.candidate.fileModifiedAt,
                    checksum: entry.checksum,
                    // The UUID the timeline will render for this asset — the
                    // only moment the client is told it.
                    serverAssetId: uploaded.id
                )
                // The id just returned is the only chance to place this asset
                // in its mirror album without another server round-trip: the
                // ledger keeps no server id, so a missed one costs a
                // `bulk-upload-check` later.
                if !albumMap.isEmpty {
                    await albumSync.stage(assetID: uploaded.id, deviceAssetID: entry.candidate.id)
                }
            } catch {
                // A cancelled upload is not a failure: no count, no failure
                // entry, no message. Its staged file is released below.
                if !UserFacingError.isCancellation(error) {
                    failedCount += 1
                    lastError = error.userFacingMessage ?? UserFacingError.genericMessage
                    failures.append(BackupFailure(
                        assetID: entry.candidate.id,
                        name: entry.candidate.fileName,
                        reason: error.userFacingMessage ?? UserFacingError.genericMessage,
                        fileSize: Self.stagedFileSize(entry)
                    ))
                }
            }
            Self.removeStaged([entry])
            statusMessage = nil
            release()
            notifyProgress()
        }
    }

    /// A Live Photo whose still is already on the server ("reject") may have
    /// been uploaded as a dead image by an earlier run. The reject carries the
    /// remote `assetId`, so the missing video is uploaded and linked onto it:
    /// without this path those Live Photos stay broken forever — the server
    /// keeps rejecting the still by checksum and "Reset backup tracking" does
    /// not help. The repair is idempotent (a duplicate video upload returns the
    /// existing id, and the PATCH is absolute).
    private func repairLivePhotoIfNeeded(_ entry: StagedAsset, remoteAssetID: String?, isTrashed: Bool) async {
        guard let paired = entry.paired, let remoteAssetID, !isTrashed else { return }
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
        } catch {
            // The still IS on the server, so this is a warning, not a failed
            // asset: recorded for the failures list, retried next run.
            // A cancelled link is simply not done: nothing to record.
            guard !UserFacingError.isCancellation(error) else { return }
            failures.append(BackupFailure(
                assetID: entry.candidate.id,
                name: entry.candidate.fileName,
                reason: error.userFacingMessage ?? UserFacingError.genericMessage,
                fileSize: Self.stagedFileSize(entry)
            ))
            lastError = error.userFacingMessage ?? UserFacingError.genericMessage
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
    private func reconcileLedgerIfDue(force: Bool = false) async {
        guard environment.isOnline else { return }
        if !force, let last = ledger.lastReconciliation,
           Date().timeIntervalSince(last) < Self.reconcileInterval {
            return
        }
        let entries = ledger.entriesForReconciliation()
        var forgotten: [String] = []
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
                    forgotten.append(result.id)
                }
            } catch {
                // Not a run failure: abandon the pass, retry when next due.
                statusMessage = nil
                return
            }
        }
        ledger.forget(ids: forgotten)
        ledger.recordReconciliation(at: Date())
        commitLedger()
        statusMessage = nil
    }

    /// When the ledger was last confronted with the server (nil = never).
    var lastReconciliation: Date? { ledger.lastReconciliation }

    /// Runs the reconciliation now, ignoring the weekly throttle. Backs the
    /// non-destructive "Check server now" action.
    func reconcileNow() async {
        await reconcileLedgerIfDue(force: true)
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
    /// for a Live Photo, the paired video. `nil` when the temp file is
    /// unreadable, so a failure line says "Unknown size" instead of "0 B".
    private static func stagedFileSize(_ entry: StagedAsset) -> Int64? {
        var bytes = fileSize(entry.fileURL)
        if let paired = entry.paired { bytes += fileSize(paired.url) }
        return bytes > 0 ? Int64(bytes) : nil
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

    /// Deletes everything a chunk owns — the exported original and, for a Live
    /// Photo, its paired video. The single cleanup entry point on purpose: a
    /// missed pair leaks a second full-quality file per asset, and a cancelled
    /// run touches every exit path.
    private static func removeStaged(_ entries: [StagedAsset]) {
        for entry in entries {
            removeStagedFile(entry.fileURL)
            if let paired = entry.paired { removeStagedFile(paired.url) }
        }
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
        iCloudProgress = [:]
        iCloudRetryAttempts = [:]
        uploadedBytes = 0
        startedAt = nil
        albumMap = [:]
        albumMembership = [:]
        albumSyncOutcome = nil
    }
}