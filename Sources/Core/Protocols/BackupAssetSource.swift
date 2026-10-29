import Foundation
import Photos

/// Kind of a backup candidate (PHAsset mediaType, mapped).
enum BackupAssetKind: String, Sendable {
    case image
    case video
}

/// A library asset reduced to its backup-relevant metadata — value type so the
/// whole engine is testable without constructing a real `PHAsset`.
struct BackupCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let kind: BackupAssetKind
    let fileName: String
    let fileCreatedAt: String
    let fileModifiedAt: String
    let duration: Int?
    let isFavorite: Bool
    /// True for a Live Photo (`mediaSubtypes` contains `.photoLive`): the
    /// asset has a paired video resource that must be uploaded alongside the
    /// still, or the server stores a dead image.
    var isLivePhoto: Bool = false
    /// Bytes the asset occupies on the wire — its original resource plus, for
    /// a Live Photo, the paired video. `nil` when the library can't report it,
    /// which the UI renders as "Unknown size" rather than 0 B. Defaulted, so
    /// every existing construction keeps compiling.
    var fileSize: Int64? = nil
}

/// An album the user can scope backups to — user album or smart album.
struct BackupAlbum: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let count: Int
    /// Smart album (Screenshots, Selfies, Bursts, Videos). Smart albums get
    /// stable synthetic ids (`SmartID`) instead of a Photos
    /// `localIdentifier`, so a persisted exclusion still means the same thing
    /// after a reinstall.
    var isSmart: Bool = false

    /// Stable identifiers for the smart albums offered to the exclusion UI.
    enum SmartID {
        static let screenshots = "smart:screenshots"
        static let selfPortraits = "smart:self-portraits"
        static let bursts = "smart:bursts"
        static let videos = "smart:videos"
    }
}

/// Per-asset export progress, surfaced to the UI so an iCloud download or an
/// automatic retry is visible instead of an opaque stall.
enum BackupExportState: Sendable {
    /// iCloud is streaming the original down; `fraction` is 0...1.
    case downloadingFromICloud(fraction: Double)
    /// The original was not local yet (transient iCloud 1005); retrying.
    /// `attempt` is 1-based.
    case retryingICloud(attempt: Int)
}

/// A Live Photo's video half, exported next to the still. The caller owns the
/// temp file and MUST delete it.
struct BackupPairedVideo: Sendable {
    let url: URL
    /// The video resource's original filename — the server stores it as-is.
    let fileName: String
    /// Seconds; the server needs it to classify the video asset.
    let duration: Int
}

/// A non-failure export outcome: the iCloud original isn't on device yet, so
/// this asset is skipped this run and retried on the next one. Kept distinct
/// from a real error so the UI can show "waiting for iCloud", not "failed".
enum BackupExportError: Error, Sendable {
    case cloudDownloadPending
}

/// Temp directories exports are written to. Two on purpose: every backup run
/// deletes `backup` entirely at its start (`purgeStaleExports()`), so an export
/// made outside the engine needs a directory that purge does not touch.
enum BackupExportDirectory {
    /// The backup engine's exports.
    static var backup: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("immich-backup", isDirectory: true)
    }
    /// The "On this device" Check's exports, purged by that screen alone.
    static var localCheck: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("immich-local-check", isDirectory: true)
    }
}

/// Asset source for the backup engine — PHPhotoLibrary behind value types.
/// Tests provide a pure mock; production uses `PhotoLibraryServiceImpl`.
protocol BackupAssetSource: Sendable {
    func fetchAlbums() -> [BackupAlbum]
    /// Candidates sorted by creation date DESC. Empty `albumIDs` = whole
    /// library. Assets belonging to any album in `excludedAlbumIDs` are left
    /// out — resolved here by subtracting identifier sets, so the engine never
    /// has to know an album name and no per-asset album lookup happens during
    /// the scan. IDs may be user-album `localIdentifier`s or
    /// `BackupAlbum.SmartID` values.
    func fetchCandidates(in albumIDs: Set<String>, excluding excludedAlbumIDs: Set<String>) -> [BackupCandidate]
    /// The same candidates, resolved from Photos `localIdentifier`s instead of
    /// enumerated. A retry names the assets it wants, and a point lookup is
    /// what keeps it from paying a whole-library scan. Ids the library no
    /// longer holds are simply absent from the result — no album scoping, no
    /// ordering guarantee beyond the request.
    func fetchCandidates(ids: [String]) -> [BackupCandidate]
    /// Streams the candidate's full-resolution original to a temporary file in
    /// `directory` and returns its URL — never materializes the whole asset in
    /// memory (mirrors the upstream Flutter client, which uploads straight from
    /// a file). The caller owns the returned file and MUST delete it after use.
    /// A caller that exports outside a backup run passes its own directory,
    /// because every run purges `BackupExportDirectory.backup` at its start.
    /// `onState` reports iCloud download progress / retries as they happen;
    /// it may be called from a background queue.
    func exportOriginal(
        for candidate: BackupCandidate,
        into directory: URL,
        onState: @escaping @Sendable (BackupExportState) -> Void
    ) async throws -> URL

    /// Streams a Live Photo's paired video to a temporary file. Returns nil
    /// when the asset has no paired resource (any non-Live-Photo). Throws the
    /// same errors as `exportOriginal` — on an optimized library the video is
    /// as likely to be iCloud-only as the still.
    func exportPairedVideo(
        for candidate: BackupCandidate,
        onState: @escaping @Sendable (BackupExportState) -> Void
    ) async throws -> BackupPairedVideo?

    /// Best-effort removal of leftover temp originals from a previous run that
    /// a jetsam OOM/expiration killed before it could delete them. Called once
    /// at the start of a run so orphaned exports don't accumulate on disk.
    /// Removes `BackupExportDirectory.backup` and nothing else: an export made
    /// `into` another directory (the "On this device" Check) survives it.
    func purgeStaleExports()

    /// Which of the given albums each library asset belongs to —
    /// `deviceAssetID → deviceAlbumIDs`. The inverse of `excludedAssetIDs(_:)`:
    /// one `PHAsset.fetchAssets` per album, so an album's whole membership
    /// costs one query instead of an album lookup per asset during the scan.
    /// `BackupCandidate` stays deliberately album-free for exactly this trade:
    /// carrying a name per asset meant an extra Photos round-trip per asset.
    /// Albums the library doesn't have are simply absent from the map.
    func albumMembership(deviceAlbumIDs: Set<String>) -> [String: [String]]
}

extension BackupAssetSource {
    /// The backup's own export: `BackupExportDirectory.backup`, the directory
    /// each run purges at its start.
    func exportOriginal(
        for candidate: BackupCandidate,
        onState: @escaping @Sendable (BackupExportState) -> Void
    ) async throws -> URL {
        try await exportOriginal(for: candidate, into: BackupExportDirectory.backup, onState: onState)
    }
}