import Foundation
import Observation

/// Drives "Free Up Space": scan, review, then delete the local originals of
/// assets the server provably already holds.
///
/// Two independent questions decide what may be removed, and both have to be
/// answered before anything is touched:
///
///  1. **The server still has it** — the ledger knows which assets were
///     uploaded, but the ledger is a *write cache*, not the server's truth: an
///     asset deleted server-side stays in it (which is why
///     `BackupEngine.reconcileLedgerIfDue` exists at all). So every tracked
///     entry is replayed through `bulk-upload-check` first, and only a
///     `reject` — "I already have these bytes" — counts as proof.
///  2. **The device may drop it** — `LocalCleanupSource` resolves that side:
///     shared albums, kept albums, favorites, media category and the cutoff.
///
/// Deleting on the strength of the ledger alone would destroy the only
/// remaining copy of an asset the server no longer has. That is the single
/// expensive mistake this feature can make, and the whole flow is arranged
/// around not making it: scan → explicit review → confirmation.
@Observable
@MainActor
final class FreeUpSpaceViewModel {
    let client: any ImmichClient
    let source: any LocalCleanupSource
    let albumSource: any BackupAssetSource
    let ledger: any BackupLedgerStoring
    var settings: CleanupSettingsStore

    /// Mirrors `BackupEngine.checkChunkSize`. The dedup check is chunked the
    /// same way on both screens, so the server sees one request shape whatever
    /// drives it (100 entries × 2 short strings — no media bytes, ever).
    private static let serverCheckChunkSize = 100

    var albums: [BackupAlbum] = []
    var candidates: [CleanupCandidate] = []
    var isScanning = false
    var isDeleting = false
    var scannedCount = 0
    var skippedNotOnServer = 0
    var skippedInSharedAlbum = 0
    /// Set once a deletion succeeds; drives the success alert. The view clears
    /// it (`acknowledgeDeletion`) so the next deletion is a fresh transition.
    var lastDeletedCount: Int?
    var errorMessage: String?

    /// Bumped by every filter change. A scan in flight captured the filters it
    /// started with; when this moves, its results describe a library the user
    /// no longer asked about and are dropped instead of assigned.
    private var scanGeneration = 0

    init(
        client: any ImmichClient,
        source: any LocalCleanupSource,
        albumSource: any BackupAssetSource,
        ledger: any BackupLedgerStoring,
        settings: CleanupSettingsStore
    ) {
        self.client = client
        self.source = source
        self.albumSource = albumSource
        self.ledger = ledger
        self.settings = settings
    }

    // MARK: - Projections

    /// Without a cutoff there is nothing to scan: upstream's
    /// `cutoffDaysAgo == -1` short-circuits `scanAssets()`.
    var canScan: Bool { settings.cutoffDate != nil && !isScanning && !isDeleting }

    var reclaimableBytes: Int64 {
        candidates.reduce(0) { $0 + $1.byteSize }
    }

    /// A finished scan that found nothing to remove — distinct from "not
    /// scanned yet", which must show the settings, not an empty state.
    var hasNothingToFreeUp: Bool { scannedCount > 0 && candidates.isEmpty }

    var hasKeepFilters: Bool {
        settings.keepFavorites || settings.keepMediaType != .none || !settings.keepAlbumIDs.isEmpty
    }

    /// The section footer, computed from the active filters rather than fixed:
    /// a screen that claims to keep favorites while the toggle is off is a
    /// screen whose delete button can't be trusted.
    var keepSummary: String {
        guard hasKeepFilters else {
            return String(localized: "Nothing is kept: every backed-up original before the cutoff can be removed.")
        }
        var parts: [String] = []
        if settings.keepFavorites { parts.append(String(localized: "favorites")) }
        if settings.keepMediaType == .photos { parts.append(String(localized: "photos")) }
        if settings.keepMediaType == .videos { parts.append(String(localized: "videos")) }
        if !settings.keepAlbumIDs.isEmpty {
            parts.append(String(localized: "\(settings.keepAlbumIDs.count) albums"))
        }
        return String(localized: "Kept on this device: \(ListFormatter.localizedString(byJoining: parts)).")
    }

    /// One VoiceOver element per review cell: a grid of hundreds of thumbnails
    /// read as "image, button, image, button" is unusable.
    func accessibilityLabel(for candidate: CleanupCandidate) -> String {
        let kind = candidate.kind == .video ? String(localized: "Video") : String(localized: "Photo")
        let date = candidate.creationDate.formatted(date: .abbreviated, time: .omitted)
        return "\(kind), \(date), \(StorageStatsViewModel.format(candidate.byteSize))"
    }

    // MARK: - Albums

    /// Albums are read once per appearance. Pruning first keeps the picker and
    /// the stored set consistent; the messaging-app defaults are applied only
    /// while they have never been applied.
    func loadAlbums() {
        albums = albumSource.fetchAlbums()
        settings.pruneStaleAlbums(existing: Set(albums.map(\.id)))
        settings.applyDefaultKeepAlbums(albums)
    }

    // MARK: - Filters
    //
    // Every filter mutation discards the scan — upstream's `CleanupNotifier`
    // clears `assetsToDelete` in `setSelectedDate`, `setKeepFavorites`,
    // `setKeepMediaType` and `toggleKeepAlbum` alike. A scan describes the
    // library *under one set of filters*; keeping its candidates after a change
    // would let the review screen delete a file the new filters say to keep.

    func setCutoff(_ date: Date?) {
        settings.cutoffDate = date
        candidates = []
        scannedCount = 0
        skippedNotOnServer = 0
        skippedInSharedAlbum = 0
        scanGeneration += 1
    }

    func setKeepFavorites(_ keep: Bool) {
        settings.keepFavorites = keep
        candidates = []
        scannedCount = 0
        skippedNotOnServer = 0
        skippedInSharedAlbum = 0
        scanGeneration += 1
    }

    func setKeepMediaType(_ type: CleanupKeepMediaType) {
        settings.keepMediaType = type
        candidates = []
        scannedCount = 0
        skippedNotOnServer = 0
        skippedInSharedAlbum = 0
        scanGeneration += 1
    }

    /// Whole-set write behind `AlbumPickerView`'s `@Binding`. Expressed as
    /// toggles so the album filter has exactly one invalidation rule — the
    /// picker edits a set, the rule is written for one album, and a second copy
    /// of it here would be a second thing to keep in sync.
    func setKeepAlbums(_ ids: Set<String>) {
        let current = settings.keepAlbumIDs
        guard ids != current else { return }
        for id in current.subtracting(ids) { toggleKeepAlbum(id) }
        for id in ids.subtracting(current) { toggleKeepAlbum(id) }
    }

    func toggleKeepAlbum(_ albumID: String) {
        if settings.keepAlbumIDs.contains(albumID) {
            settings.keepAlbumIDs.remove(albumID)
        } else {
            settings.keepAlbumIDs.insert(albumID)
        }
        candidates = []
        scannedCount = 0
        skippedNotOnServer = 0
        skippedInSharedAlbum = 0
        scanGeneration += 1
    }

    // MARK: - Scan

    func scan() async {
        // A second call while one is in flight would clear the list under the
        // first and drop `isScanning` early. The button is disabled meanwhile,
        // but a double tap lands inside one render pass.
        guard !isScanning, let cutoff = settings.cutoffDate else { return }
        let generation = scanGeneration
        isScanning = true
        errorMessage = nil
        candidates = []
        scannedCount = 0
        skippedNotOnServer = 0
        skippedInSharedAlbum = 0
        defer { isScanning = false }

        let entries = ledger.entriesForReconciliation()
        var backedUpIDs = Set<String>()
        do {
            var index = 0
            while index < entries.count {
                let chunk = Array(entries[index..<min(index + Self.serverCheckChunkSize, entries.count)])
                index += Self.serverCheckChunkSize
                let response = try await client.bulkUploadCheck(
                    AssetBulkUploadCheckRequest(assets: chunk.map {
                        AssetBulkUploadCheckRequest.Item(id: $0.id, checksum: $0.checksum)
                    })
                )
                // `reject` = the server already holds this exact checksum, so
                // the local original is a copy. `accept` = it does NOT have it
                // (deleted, purged, another account): the local file is then the
                // only one left and must never be handed to the deletion. A
                // trashed asset comes back as `reject`, so it stays eligible:
                // the server still holds the bytes.
                for result in response.results where result.action == "reject" {
                    backedUpIDs.insert(result.id)
                }
                guard generation == scanGeneration else { return }
            }
        } catch {
            errorMessage = error.userFacingMessage
            return
        }

        // The library walk is heavy (identifier resolution plus one metadata
        // read per asset) and runs off the main actor for the same reason
        // `BackupEngine.fetchCandidates` does — a whole-library scan on the main
        // thread freezes the UI for its whole duration.
        let keepFavorites = settings.keepFavorites
        let keepMediaType = settings.keepMediaType
        let keepAlbumIDs = settings.keepAlbumIDs
        let source = self.source
        let result = await Task.detached(priority: .utility) {
            source.cleanupCandidates(
                cutoff: cutoff,
                keepFavorites: keepFavorites,
                keepMediaType: keepMediaType,
                keepAlbumIDs: keepAlbumIDs,
                backedUpIDs: backedUpIDs
            )
        }.value

        guard generation == scanGeneration else { return }
        candidates = result.candidates
        scannedCount = result.scannedCount
        skippedInSharedAlbum = result.skippedInSharedAlbum
        // Tracked entries the server did not confirm. The source cannot know
        // this — it never sees the ledger.
        skippedNotOnServer = entries.count - backedUpIDs.count
    }

    // MARK: - Deletion

    /// Applies the reviewed deletion: the single call that removes originals
    /// from the photo library, and it is only reachable through an explicit
    /// confirmation on the review screen.
    ///
    /// The ledger is deliberately **not** purged. These assets are still on the
    /// server, and if the user restores one from the system "Recently Deleted"
    /// album (~30 days), a kept entry means the next backup skips it instead of
    /// re-uploading the whole file.
    @discardableResult
    func deleteConfirmed() async -> Int? {
        // Same double-submit guard as `scan()`: a second call would re-issue a
        // deletion for assets the first is already removing, and stack a second
        // system confirmation on top of the first.
        guard !isDeleting else { return nil }
        guard !candidates.isEmpty else { return nil }
        isDeleting = true
        defer { isDeleting = false }
        do {
            let deleted = try await source.deleteLocalAssets(ids: candidates.map(\.id))
            lastDeletedCount = deleted
            candidates = []
            scannedCount = 0
            skippedNotOnServer = 0
            skippedInSharedAlbum = 0
            scanGeneration += 1
            return deleted
        } catch {
            // The candidates stay: some batches may have gone through, and the
            // rest are still removable. Photos' own alert is what the user
            // answers; this is for when the library refuses the change.
            errorMessage = error.userFacingMessage
            return nil
        }
    }

    /// Clears the scan without touching the persisted filters — upstream's
    /// `CleanupNotifier.reset()`. Called once a deletion has consumed the
    /// review, so a spent candidate list can never be shown again.
    func resetScan() {
        candidates = []
        scannedCount = 0
        skippedNotOnServer = 0
        skippedInSharedAlbum = 0
        scanGeneration += 1
    }

    func acknowledgeDeletion() {
        lastDeletedCount = nil
    }
}
