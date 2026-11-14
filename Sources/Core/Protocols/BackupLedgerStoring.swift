import Foundation

/// What the ledger knows about one tracked asset (a copy: the stored entry is
/// private to the ledger).
struct BackupLedgerEntry: Equatable, Sendable {
    let signature: String
    let checksum: String?
    let serverAssetId: String?
}

/// Persistent record of assets already backed up to the server, keyed by the
/// Photos `localIdentifier`. It lets a run skip assets it has already handled
/// — uploaded, or confirmed by the server as duplicates — *before* exporting
/// them, so an iCloud-optimized library is never re-downloaded run after run
/// just to be re-hashed and re-rejected.
///
/// The stored value is the asset's `modificationDate` signature: a later edit
/// changes it, so the asset drops out of the ledger match and is reconsidered
/// (and re-uploaded) on the next run.
protocol BackupLedgerStoring: Sendable {
    /// True when this exact asset+signature was already backed up.
    func isBackedUp(id: String, signature: String) -> Bool

    /// Records an asset as backed up, with the checksum it was uploaded (or
    /// rejected) under. The checksum is what makes the ledger reconcilable:
    /// it is replayed against `bulk-upload-check` to detect assets the server
    /// no longer has, at no media-byte cost. In-memory and cheap; durability is
    /// flushed by `save()`.
    ///
    /// `serverAssetId` is the asset's UUID on the server — the ledger's key is
    /// the Photos `localIdentifier`, so this is the only bridge between what
    /// the timeline renders (server ids) and what the ledger knows (library
    /// ids). Both paths that hold it already have it in hand: a `reject` from
    /// `bulk-upload-check` carries the existing asset's UUID, and an upload
    /// returns the new one. It stays optional — entries written before v3, and
    /// a `reject` the server answered without an id, have none.
    func markBackedUp(id: String, signature: String, checksum: String, serverAssetId: String?)

    /// Every tracked asset's **server** UUID. A set rather than a walk over
    /// the entries: a thumbnail asks one question per cell, and an O(n) sweep
    /// per cell would put the whole ledger on the render path.
    func uploadedServerAssetIDs() -> Set<String>

    /// Every tracked asset's library id, whatever the entry's shape. Unlike
    /// `entriesForReconciliation()` this keeps v1 entries, which are backed up
    /// even though their checksum was never stored.
    func uploadedLocalAssetIDs() -> Set<String>

    /// Whether a single library id is tracked. Same predicate as
    /// `uploadedLocalAssetIDs()`, for callers holding one id and no set.
    func hasUploaded(id: String) -> Bool

    /// Every tracked entry that has a checksum — the reconciliation payload.
    /// Entries migrated from the v1 file have none and are skipped: replaying
    /// them is impossible without re-hashing the asset, which is precisely the
    /// download the ledger exists to avoid.
    func entriesForReconciliation() -> [(id: String, checksum: String)]

    /// Drops entries the server no longer has, so the next scan re-uploads them.
    func forget(ids: [String])

    /// When the ledger was last confronted with the server (nil = never).
    var lastReconciliation: Date? { get }

    /// Stamps a successful reconciliation pass.
    func recordReconciliation(at date: Date)

    /// Flushes pending changes to disk (best-effort, may run asynchronously).
    func save()

    /// Number of tracked assets — surfaced in the backup settings UI.
    func trackedCount() -> Int

    /// Forgets every tracked asset, forcing a full re-backup on the next run.
    /// Used when the server library was wiped and the local ledger is stale.
    func removeAll()

    /// Read-only view of one tracked entry — signature, checksum and server
    /// UUID — or nil when the id is not tracked. The engine's edit logic needs
    /// the original's server id and checksum by local id.
    func trackedEntry(id: String) -> BackupLedgerEntry?
}

extension BackupLedgerStoring {
    /// Records an asset whose server UUID isn't known to the caller. Not a
    /// protocol requirement: a default argument is not allowed on one, and
    /// callers that hold only the checksum would otherwise have to spell out
    /// `serverAssetId: nil` — a value they do not know, not one they chose.
    func markBackedUp(id: String, signature: String, checksum: String) {
        markBackedUp(id: id, signature: signature, checksum: checksum, serverAssetId: nil)
    }
}
