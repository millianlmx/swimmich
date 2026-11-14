import Foundation

/// Which category of media stays on device — the iOS mirror of upstream's
/// `AssetKeepType` (`cleanup_config.dart`). `none` keeps nothing, i.e. every
/// original past the cutoff is a candidate.
enum CleanupKeepMediaType: String, CaseIterable, Sendable {
    case none
    case photos
    case videos

    /// Localized at read time rather than through `Text`'s own lookup: the
    /// picker builds its rows from `allCases`, and `Text(String)` renders
    /// verbatim.
    var title: String {
        switch self {
        case .none: return String(localized: "All")
        case .photos: return String(localized: "Photos")
        case .videos: return String(localized: "Videos")
        }
    }
}

/// A local asset that only exists on the device as a second copy: it is in the
/// library, and the server is known to hold the same bytes.
///
/// `BackupCandidate`'s pendant, plus the one thing it lacks — `byteSize`, which
/// is what the "Reclaimable" figure is built from and cannot be derived from
/// the backup metadata.
struct CleanupCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let kind: BackupAssetKind
    let fileName: String
    let creationDate: Date
    let byteSize: Int64
    let isFavorite: Bool
}

/// Outcome of one cleanup scan. The three counters exist so the screen can show
/// *why* an asset the user expected to see isn't in the review list.
struct CleanupScanResult: Equatable, Sendable {
    let candidates: [CleanupCandidate]
    /// Ledger entries the server did not confirm. Always 0 out of a
    /// `LocalCleanupSource`: the ledger isn't visible from the library side, and
    /// only the caller holds both numbers. The view model fills the real value.
    let skippedNotOnServer: Int
    /// Assets left out because they live in an iCloud Shared Album, which iOS
    /// cannot remove items from.
    let skippedInSharedAlbum: Int
    /// Assets actually inspected: resolved on device and not in a shared album,
    /// before the cutoff and keep filters narrow the list down.
    let scannedCount: Int
    /// Assets left out because their edited version (`hasAdjustments`) is not
    /// confirmed on the server for the current modification date — only counted
    /// when the "Also back up edits" setting is on (`confirmedEdits != nil`).
    var skippedEditNotBackedUp: Int = 0

    var reclaimableBytes: Int64 {
        candidates.reduce(0) { $0 + $1.byteSize }
    }
}

/// Destructive half of the Photos surface: an asset source that can delete.
///
/// Kept beside `BackupAssetSource` rather than on it so that the backup path
/// never gains a delete capability it has no reason to hold, and so the scan
/// stays a pure function of (ledger ids confirmed by the server, cutoff,
/// keeps) — testable without a `PHAsset` in sight.
protocol LocalCleanupSource: Sendable {
    /// The assets that are both on this device and provably on the server, and
    /// that the cutoff/keep filters do not protect.
    ///
    /// `backedUpIDs` is the *server's* answer (`bulk-upload-check` rejects),
    /// never the ledger's: a stale ledger entry would let this delete the last
    /// remaining copy.
    /// `confirmedEdits` is `localIdentifier → signature` of the edited
    /// renderings the server confirmed; `nil` means the setting is off and an
    /// edited asset is judged by its original alone. When set, an edited asset
    /// whose current modification date is not confirmed is kept on the device.
    func cleanupCandidates(
        cutoff: Date,
        keepFavorites: Bool,
        keepMediaType: CleanupKeepMediaType,
        keepAlbumIDs: Set<String>,
        backedUpIDs: Set<String>,
        confirmedEdits: [String: String]?
    ) -> CleanupScanResult

    /// Deletes the given assets from the photo library, in batches, and returns
    /// how many were handed to Photos. Throws when a batch fails; batches that
    /// already succeeded stay deleted.
    func deleteLocalAssets(ids: [String]) async throws -> Int
}
