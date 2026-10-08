import Foundation
import Observation

/// Asset Troubleshoot (gap G24): everything the app knows about one asset in
/// one place — what the server holds, what the device cached, whether the
/// backup ledger considers it saved, and whether the server already has this
/// checksum.
///
/// No new source of truth. The remote half is `GET /api/assets/{id}` plus
/// `POST /api/assets/bulk-upload-check` — the very dedup call the backup engine
/// makes before uploading, so the answer a backup would get is the answer shown
/// here. The local half is the offline mirror and the ledger.
@MainActor
@Observable
final class AssetTroubleshootViewModel {
    /// Where this asset stands with the backup ledger.
    enum BackupState: Equatable {
        /// Nothing has been read yet.
        case unknown
        /// The ledger tracks this asset as uploaded.
        case backedUp
        /// The ledger has never seen it.
        case notTracked
    }

    private let client: any ImmichClient
    private let ledger: any BackupLedgerStoring
    private let offlineIndex: OfflineAssetIndex

    private(set) var detail: AssetResponseDto?
    private(set) var cached: CachedAssetInfo?
    private(set) var backupState: BackupState = .unknown
    /// The server's own copy of an asset carrying this checksum — the answer to
    /// "who else holds this file" (`reject` + `duplicate` + an id). Nil when the
    /// server accepted the checksum, i.e. has nothing with it.
    private(set) var duplicateRemoteAssetID: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(client: any ImmichClient, ledger: any BackupLedgerStoring, offlineIndex: OfflineAssetIndex) {
        self.client = client
        self.ledger = ledger
        self.offlineIndex = offlineIndex
    }

    /// Reads the asset. The local facts are settled **first**, before anything
    /// can fail: a network error must not hide what the device already knows.
    func load(assetID: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        cached = offlineIndex.info(assetID)
        do {
            let detail = try await client.getAsset(id: assetID)
            self.detail = detail
            duplicateRemoteAssetID = await duplicate(of: detail, assetID: assetID)
            backupState = isTracked(detail) ? .backedUp : .notTracked
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// Whether the ledger has this asset: either under its own id with the
    /// modification signature the backup engine stores (`fileModifiedAt`), or —
    /// the case that matters for a server-side asset, since the ledger is keyed
    /// by the library's local identifier — under the server UUID it recorded.
    private func isTracked(_ detail: AssetResponseDto) -> Bool {
        ledger.isBackedUp(id: detail.id, signature: detail.fileModifiedAt)
            || ledger.uploadedServerAssetIDs().contains(detail.id)
    }

    /// Asks the server whether it already holds this checksum.
    private func duplicate(of detail: AssetResponseDto, assetID: String) async -> String? {
        let request = AssetBulkUploadCheckRequest(assets: [.init(id: assetID, checksum: detail.checksum)])
        guard let response = try? await client.bulkUploadCheck(request),
              let result = response.results.first,
              result.action == "reject",
              result.reason == "duplicate"
        else { return nil }
        return result.assetId
    }

    /// The local cache's timestamp, formatted here so the view formats no date.
    func formattedCachedAt() -> String {
        cached?.cachedAt.formatted(date: .abbreviated, time: .standard) ?? ""
    }

    /// The cached file's weight, through the repo's existing byte formatter —
    /// never a second one.
    func formattedCachedSize() -> String {
        cached.map { StorageStatsViewModel.format($0.size) } ?? ""
    }
}
