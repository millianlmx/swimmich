import Foundation

/// In-memory mirror of the data two views need from the backup ledger: "which
/// server assets are proven to be on the server" and "which local assets are".
///
/// It exists because the ledger speaks Photos `localIdentifier`s while the
/// timeline renders server UUIDs, and because the ledger's read for
/// reconciliation is a walk over every entry — fine once per run, unusable per
/// thumbnail. This index is rebuilt only when the ledger is written
/// (`refresh(ledger:)`), so a tile lookup is a `Set.contains` and nothing else.
///
/// The mirror is fed by the ledger, never by a network call: proof of upload is
/// exactly what the ledger already stores, and a per-tile `bulk-upload-check`
/// would need each original's checksum, which the timeline does not deliver.
@MainActor
@Observable
final class CloudBackupStatusIndex {
    /// The "Show backup status on thumbnails" preference — the badge's only
    /// gate. While it is off every lookup answers `nil`, so the feature is
    /// silent without the sets having to be dropped (turning it back on must
    /// not require a ledger reload).
    private(set) var isEnabled = false

    /// Server UUIDs the ledger recorded as uploaded or as server-side
    /// duplicates.
    private(set) var uploadedServerIDs: Set<String> = []

    /// Library ids the ledger tracks — the local half of the same question.
    private(set) var uploadedLocalIDs: Set<String> = []

    func setEnabled(_ enabled: Bool) { isEnabled = enabled }

    /// Rebuilds both sets from the ledgers. Called once at composition, then on
    /// every persisted ledger write. The edited versions count on the server
    /// side — stacked or still waiting for their stack, the edit is on the
    /// server either way — so the stack's head carries the badge (its original
    /// is hidden behind it). The local side is the original ledger's alone: an
    /// edited asset whose edit is missing keeps the badge of its original.
    func refresh(ledger: any BackupLedgerStoring, editLedger: any BackupEditLedgerStoring) {
        uploadedServerIDs = ledger.uploadedServerAssetIDs()
            .union(editLedger.allRecords().values.map(\.serverAssetId))
        uploadedLocalIDs = ledger.uploadedLocalAssetIDs()
    }

    /// Status of an asset the server knows, looked up by its UUID — what a
    /// timeline tile asks.
    ///
    /// An unknown id answers `nil`, never `.localOnly`: the timeline only ever
    /// serves server ids, so "on this device only" is unprovable there — the
    /// asset may have been uploaded by another device, and a `icloud.slash`
    /// would assert the opposite. Absence of information draws nothing.
    func status(forServerAssetID id: String) -> CloudBackupStatus? {
        guard isEnabled else { return nil }
        return uploadedServerIDs.contains(id) ? .uploaded : nil
    }

    /// Status of an asset looked up by its library id. Here the ledger can
    /// answer both ways: it tracks the library, so "not in the ledger" means
    /// this device still holds the only copy.
    func status(forLocalAssetID id: String) -> CloudBackupStatus? {
        guard isEnabled else { return nil }
        return uploadedLocalIDs.contains(id) ? .uploaded : .localOnly
    }
}
