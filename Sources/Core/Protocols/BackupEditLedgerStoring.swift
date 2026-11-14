import Foundation

/// What the backup remembers about one asset's edited version: the rendering
/// already sent to the server and whether it sits on top of the original in a
/// stack. Keyed by the Photos `localIdentifier` in `BackupEditLedgerStoring`.
struct BackupEditRecord: Codable, Equatable, Sendable {
    /// The asset's `fileModifiedAt` when this rendering was processed. A later
    /// edit changes it, which is what makes the new rendering "pending".
    var signature: String
    /// SHA-1 (base64) of the rendering's main file — replayed against
    /// `bulk-upload-check` by the reconciliation and by Free Up Space.
    var checksum: String
    /// The edited version's UUID on the server.
    var serverAssetId: String
    /// The original's UUID on the server when the stack was built.
    var originalServerAssetId: String?
    /// The head of the stack before this rendering — the previous edit.
    var previousServerAssetId: String?
    /// False while the stack still has to be (re)built: the rendering is on the
    /// server, the `POST /api/stacks` failed or has not happened yet.
    var isStacked: Bool
    var fileName: String
}

/// Persistent record of the edited versions already backed up, beside the
/// original-asset ledger (`BackupLedgerStoring`), which it never touches. It lets
/// a run skip an edit it already handled without re-exporting (and so
/// re-downloading from iCloud) its rendering.
protocol BackupEditLedgerStoring: Sendable {
    func record(id: String) -> BackupEditRecord?
    func upsert(id: String, _ record: BackupEditRecord)
    /// Marks the stack of `id` as done. No-op for an unknown id.
    func markStacked(id: String)
    /// Ids whose rendering is on the server but not stacked yet.
    func pendingStackIDs() -> [String]
    func allRecords() -> [String: BackupEditRecord]
    /// Every record's `(id, checksum)` — the reconciliation payload.
    func entriesForReconciliation() -> [(id: String, checksum: String)]
    /// Drops records the server no longer has, so the edit is sent again.
    func forget(ids: [String])
    /// Flushes pending changes to disk (best-effort, may run asynchronously).
    func save()
    /// Forgets every record ("Reset backup tracking").
    func removeAll()
}
