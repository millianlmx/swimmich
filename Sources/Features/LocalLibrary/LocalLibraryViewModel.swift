import Foundation
import Observation
import Photos
import UIKit

/// "On this device" — what the *device* holds, next to what the *server* holds.
///
/// Three deliberate contracts, each of which keeps this screen from drifting
/// into the other library surfaces:
///
/// * the library is read through the injected `PhotoLibraryService` (the same
///   instance the backup engine uses) — no second PhotoKit abstraction, and no
///   `fetchAssets()` from a view;
/// * the remote aggregate is the symbol the Profile storage section already
///   reads (`getServerStatistics()`), so `/assets/statistics` is decoded once in
///   the app, not twice;
/// * the "already on the server?" verdict is *ephemeral*: it comes from
///   `POST /api/assets/bulk-upload-check` on the checksum of the *original* —
///   the one the backup sends — lives in memory for this visit and is never
///   written to the backup ledger. Only Upload writes it, and it does so by
///   being a backup run (`UploadViewModel.runBackup(manual:only:)`), through the
///   backup's own engine and ledger.
@MainActor
@Observable
final class LocalLibraryViewModel {

    /// What the screen is busy with. `idle` = nothing running; the two busy
    /// phases drive the spinner *on the button* that started them.
    enum Phase: Equatable {
        case idle
        case enumerating
        case checking
        case uploading
    }

    /// Photo/video/byte totals of one library. Values, so the two columns of the
    /// summary are compared — and tested — as numbers rather than through two
    /// view helpers.
    struct MediaSummary: Equatable {
        var photos: Int
        var videos: Int
        var bytes: Int64

        static let zero = MediaSummary(photos: 0, videos: 0, bytes: 0)

        var total: Int { photos + videos }
    }

    /// Batch the server-side check runs in — the size `BackupEngine` already
    /// proved safe for `bulk-upload-check`.
    static let checkChunkSize = 100

    /// Nominal tile size in points; the display scale turns it into the pixel
    /// size Photos wants. A tile is a third of the grid, so this covers every
    /// screen the app runs on without measuring one.
    private static let tileSize = CGSize(width: 128, height: 128)

    /// `nonisolated`: reading the device and exporting an original happen off the
    /// main actor, and these are immutable `Sendable` values — the helpers below
    /// use them without hopping back through `self`.
    nonisolated let photoLibrary: any PhotoLibraryService
    nonisolated let albumSource: any BackupAssetSource
    nonisolated let client: any ImmichClient
    /// The backup's own view model: Upload is a restricted run of its engine.
    let backup: UploadViewModel
    /// Where the Check exports the originals it hashes — not the backup's
    /// directory, which every run empties.
    nonisolated let checkDirectory: URL

    var phase: Phase = .idle
    var albums: [BackupAlbum] = []
    var assets: [PHAsset] = []
    var selectedIDs: Set<String> = []
    /// Assets the server does *not* have yet (`bulk-upload-check` → `accept`).
    var localOnlyIDs: Set<String> = []
    /// Assets the server already holds (`bulk-upload-check` → `reject`).
    var savedIDs: Set<String> = []
    /// True once a check ran: before that, "no verdict" and "saved" are two
    /// different things and the screen must not show the second for the first.
    private(set) var hasVerdict = false
    var localSummary = MediaSummary.zero
    var remoteSummary: MediaSummary?
    var errorMessage: String?
    var uploadProgress: (done: Int, total: Int)?
    /// Photos access as Photos reports it, refreshed on every request.
    var authorization: PHAuthorizationStatus
    /// The album the grid is scoped to; nil = the whole library.
    private(set) var selectedAlbumID: String?
    /// True once the first enumeration finished — lets the view tell "still
    /// loading" from "the device holds nothing" without a third phase.
    private(set) var didLoad = false

    init(
        photoLibrary: any PhotoLibraryService,
        albumSource: any BackupAssetSource,
        client: any ImmichClient,
        backup: UploadViewModel,
        checkDirectory: URL = BackupExportDirectory.localCheck
    ) {
        self.photoLibrary = photoLibrary
        self.albumSource = albumSource
        self.client = client
        self.backup = backup
        self.checkDirectory = checkDirectory
        self.authorization = photoLibrary.authorizationStatus()
    }

    // MARK: - Derived state

    var canReadLibrary: Bool { authorization == .authorized || authorization == .limited }
    /// Nothing to show anywhere. Only meaningful once `didLoad` — before that the
    /// screen is loading, not empty.
    var isEmpty: Bool { albums.isEmpty && assets.isEmpty && phase == .idle }
    var selectionCount: Int { selectedIDs.count }
    var hasSelection: Bool { !selectedIDs.isEmpty }
    var localOnlyCount: Int { localOnlyIDs.count }
    var savedCount: Int { savedIDs.count }
    /// The name of the album the grid shows, or nil for the whole library —
    /// gives the tile count a subject.
    var selectedAlbumName: String? {
        guard let selectedAlbumID else { return nil }
        return albums.first { $0.id == selectedAlbumID }?.name
    }

    // MARK: - Reading the device

    /// Albums of the device: the user's albums plus the non-empty smart ones,
    /// in the order `fetchAlbums()` fixed (localized title), so the list does
    /// not re-sort itself between visits.
    func loadAlbums() {
        albums = albumSource.fetchAlbums()
    }

    /// Loads the whole library, or the assets of one album.
    ///
    /// Enumeration belongs to the ViewModel, not to a cell: `fetchAssets()`
    /// returns the complete library in one shot (no cursor), and a grid asking
    /// for it per tile would re-enumerate the library per tile. Switching album
    /// drops the selection and the verdict — a verdict describes the assets it
    /// was asked about.
    func loadAssets(albumID: String?) async {
        phase = .enumerating
        let fetched = await readLibrary(albumID: albumID)
        assets = fetched
        selectedAlbumID = albumID
        selectedIDs = []
        localOnlyIDs = []
        savedIDs = []
        hasVerdict = false
        uploadProgress = nil
        localSummary = summary(for: fetched)
        didLoad = true
        phase = .idle
    }

    /// The library itself, read off the main actor: enumerating a whole device
    /// is real work, and the screen must keep drawing its skeleton while it
    /// runs instead of freezing and then painting the result.
    private nonisolated func readLibrary(albumID: String?) async -> [PHAsset] {
        await Task.detached(priority: .userInitiated) { [photoLibrary] in
            guard let albumID else { return photoLibrary.fetchAssets() }
            return photoLibrary.fetchAssets(inAlbumID: albumID)
        }.value
    }

    /// Counts of a set of local assets.
    ///
    /// Only `mediaType` is read: the byte volume would mean reading every
    /// resource of every asset, so the device column never claims one — the
    /// server column's `usage` is the only real byte count on this screen.
    func summary(for assets: [PHAsset]) -> MediaSummary {
        var photos = 0
        var videos = 0
        for asset in assets {
            switch asset.mediaType {
            case .video: videos += 1
            case .image: photos += 1
            default: break
            }
        }
        return MediaSummary(photos: photos, videos: videos, bytes: 0)
    }

    /// The server's own aggregate, through the symbol the Profile storage
    /// section already uses. A failure leaves `remoteSummary` nil so the screen
    /// shows the device column alone: an unreachable server is not an empty one.
    func loadRemoteSummary() async {
        do {
            let stats = try await client.getServerStatistics()
            remoteSummary = MediaSummary(
                photos: stats.photos,
                videos: stats.videos,
                bytes: Int64(stats.usage)
            )
            errorMessage = nil
        } catch {
            remoteSummary = nil
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Photos access

    /// Asks Photos for read access, then re-enumerates when it is granted. The
    /// prompt sequence is the one the auto-backup toggle already uses; a refusal
    /// is not resolved here (iOS will not ask twice) — the view offers Settings.
    func requestAccess() async {
        if authorization == .notDetermined {
            let status: PHAuthorizationStatus = await withCheckedContinuation { continuation in
                let handler: (PHAuthorizationStatus) -> Void = { continuation.resume(returning: $0) }
                photoLibrary.requestAuthorization(handler)
            }
            authorization = status
        } else {
            authorization = photoLibrary.authorizationStatus()
        }
        guard canReadLibrary else { return }
        loadAlbums()
        await loadAssets(albumID: selectedAlbumID)
        await loadRemoteSummary()
    }

    // MARK: - Selection

    func toggle(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func clearSelection() { selectedIDs = [] }

    // MARK: - The verdict

    /// Asks the server which of the selected assets it already has.
    ///
    /// The checksum is the one the backup sends: the original resource is
    /// exported to a file (`exportOriginal`) and hashed from it in 64 KB reads
    /// (`BackupEngine.streamingSHA1Base64`) — never the retouched rendering, and
    /// never a whole video in memory. Then one `bulk-upload-check` per
    /// `checkChunkSize` assets. `reject` = the server has it, `accept` = it does
    /// not. Nothing is persisted and the ledger is neither read nor written: the
    /// verdict describes the assets picked in this visit, not a backup run.
    ///
    /// An asset that cannot be read (iCloud original not on the device, resource
    /// gone, asset deleted) gets no verdict and the Check goes on; the first such
    /// reason, in grid order, is the message. An error of `bulk-upload-check`
    /// itself ends the Check without a verdict.
    ///
    /// Exports go to `checkDirectory`, which every backup run leaves alone; it is
    /// emptied here before anything is exported, which also reclaims the files of
    /// a Check the system killed.
    func checkSelection() async {
        guard hasSelection, phase == .idle else { return }
        phase = .checking
        defer { phase = .idle }
        localOnlyIDs = []
        savedIDs = []
        hasVerdict = false
        errorMessage = nil
        let ids = assets.map(\.localIdentifier).filter { selectedIDs.contains($0) }
        await purgeCheckDirectory()
        let candidates = await readCandidates(ids: ids)
        var problems: [String: String] = [:]
        var index = 0
        while index < ids.count {
            let chunk = ids[index..<min(index + Self.checkChunkSize, ids.count)]
            index += Self.checkChunkSize
            var items: [AssetBulkUploadCheckRequest.Item] = []
            items.reserveCapacity(chunk.count)
            for id in chunk {
                guard let candidate = candidates[id] else {
                    problems[id] = UserFacingError.genericMessage
                    continue
                }
                do {
                    let checksum = try await originalChecksum(of: candidate)
                    items.append(AssetBulkUploadCheckRequest.Item(id: id, checksum: checksum))
                } catch is BackupExportError {
                    problems[id] = String(localized: "Waiting for iCloud")
                } catch {
                    if UserFacingError.isCancellation(error) { return }
                    problems[id] = error.userFacingMessage ?? UserFacingError.genericMessage
                }
            }
            guard !items.isEmpty else { continue }
            do {
                let response = try await client.bulkUploadCheck(AssetBulkUploadCheckRequest(assets: items))
                for result in response.results {
                    if result.action == "reject" {
                        // The server already holds this exact file.
                        savedIDs.insert(result.id)
                    } else if result.action == "accept" {
                        // It does not — the only assets worth sending.
                        localOnlyIDs.insert(result.id)
                    }
                }
            } catch {
                errorMessage = error.userFacingMessage
                return
            }
        }
        errorMessage = ids.lazy.compactMap { problems[$0] }.first
        hasVerdict = true
    }

    /// SHA1 (base64) of one asset's original, the way the backup computes it:
    /// export to a file in `checkDirectory`, hash it from disk off the main
    /// actor, delete it whatever happens.
    private nonisolated func originalChecksum(of candidate: BackupCandidate) async throws -> String {
        let url = try await albumSource.exportOriginal(for: candidate, into: checkDirectory, onState: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }
        return try await Task.detached(priority: .userInitiated) {
            try BackupEngine.streamingSHA1Base64(url)
        }.value
    }

    /// Empties `checkDirectory`, off the main actor.
    private nonisolated func purgeCheckDirectory() async {
        await Task.detached(priority: .userInitiated) { [checkDirectory] in
            _ = try? FileManager.default.removeItem(at: checkDirectory)
        }.value
    }

    /// The selected assets as backup candidates, by id. An id Photos no longer
    /// holds is absent.
    private nonisolated func readCandidates(ids: [String]) async -> [String: BackupCandidate] {
        await Task.detached(priority: .userInitiated) { [albumSource] in
            Dictionary(
                albumSource.fetchCandidates(ids: ids).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }.value
    }

    // MARK: - Sending the selection

    /// Sends the assets the check found missing from the server, as a backup
    /// run restricted to them — the same call as a retry
    /// (`UploadViewModel.runBackup(manual: true, only:)`). Export, hash,
    /// server-side dedup, upload, Live Photo video, ledger, album mirror, Live
    /// Activity, notification and history entry are the backup's; the screen owns
    /// no transport and writes no ledger of its own.
    ///
    /// An asset moves to "on the server" only if the run says it put it in the
    /// ledger (`BackupRunOutcome.backedUpIDs`): sent, or found already there with
    /// its Live Photo video linked. Deferred, failed and stopped assets stay "not
    /// on the server", with the reason of the first one as the message. A refusal
    /// (read-only mode, engine busy) sends nothing and says why.
    func uploadSelection() async {
        let pending = assets.map(\.localIdentifier).filter { localOnlyIDs.contains($0) }
        guard !pending.isEmpty, phase == .idle else { return }
        phase = .uploading
        errorMessage = nil
        let total = pending.count
        uploadProgress = (done: 0, total: total)
        defer {
            uploadProgress = nil
            phase = .idle
        }
        let result = await backup.runBackup(manual: true, only: pending) { [weak self] processed, _ in
            self?.uploadProgress = (done: min(processed, total), total: total)
        }
        switch result {
        case .refused(let message):
            errorMessage = message
        case .completed(let outcome):
            let sent = Set(pending).intersection(outcome.backedUpIDs)
            savedIDs.formUnion(sent)
            localOnlyIDs.subtract(sent)
            errorMessage = pending.first { !sent.contains($0) }.map { problem(for: $0, in: outcome) }
        }
    }

    /// Why an asset the run was asked to send is not on the server: its own
    /// failure line, else iCloud, else it never got its turn (stopped, or no
    /// longer in Photos).
    private func problem(for id: String, in outcome: BackupRunOutcome) -> String {
        if let failure = outcome.failures.first(where: { $0.assetID == id }) { return failure.reason }
        if outcome.deferrals.contains(where: { $0.id == id }) { return String(localized: "Waiting for iCloud") }
        return String(localized: "Upload stopped before this item was sent.")
    }

    // MARK: - Tiles

    /// Tile for one asset: the grid hands each cell this closure, so the cell
    /// never learns about the photo library.
    func loadThumbnail(for asset: PHAsset) async -> UIImage? {
        await photoLibrary.loadThumbnail(for: asset, targetSize: Self.tileSize, scale: UIScreen.main.scale)
    }
}
