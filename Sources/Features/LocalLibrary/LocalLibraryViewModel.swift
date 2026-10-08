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
///   `POST /api/assets/bulk-upload-check`, lives in memory for this visit and is
///   never written to the backup ledger — that ledger belongs to a backup run.
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

    /// `nonisolated`: reading the device and sending an asset happen off the
    /// main actor, and both are immutable `Sendable` values — the helpers below
    /// use them without hopping back through `self`.
    nonisolated let photoLibrary: any PhotoLibraryService
    let albumSource: any BackupAssetSource
    nonisolated let client: any ImmichClient

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

    init(photoLibrary: any PhotoLibraryService, albumSource: any BackupAssetSource, client: any ImmichClient) {
        self.photoLibrary = photoLibrary
        self.albumSource = albumSource
        self.client = client
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

    /// SHA1 of one original, computed off the main actor: hashing reads the whole
    /// file, and the check can run over hundreds of them.
    private nonisolated func checksum(of asset: PHAsset) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [photoLibrary] in
            try await photoLibrary.checksum(for: asset)
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
    /// The checksum is computed locally (`checksum(for:)`, the same SHA1 base64
    /// the engine sends), then one `bulk-upload-check` per `checkChunkSize`
    /// assets — the server has no cheaper way to answer, and this is the only
    /// question the screen asks that costs real bytes. `reject` = the server has
    /// it, `accept` = it does not; nothing is persisted, because the verdict
    /// describes the assets picked in this visit, not a backup run.
    func checkSelection() async {
        guard hasSelection, phase == .idle else { return }
        phase = .checking
        defer { phase = .idle }
        localOnlyIDs = []
        savedIDs = []
        hasVerdict = false
        let picked = assets.filter { selectedIDs.contains($0.localIdentifier) }
        var index = 0
        while index < picked.count {
            let chunk = Array(picked[index..<min(index + Self.checkChunkSize, picked.count)])
            index += Self.checkChunkSize
            do {
                var items: [AssetBulkUploadCheckRequest.Item] = []
                items.reserveCapacity(chunk.count)
                for asset in chunk {
                    let checksum = try await checksum(of: asset)
                    items.append(AssetBulkUploadCheckRequest.Item(id: asset.localIdentifier, checksum: checksum))
                }
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
        hasVerdict = true
    }

    // MARK: - Sending the selection

    /// Sends the assets the check found missing from the server.
    ///
    /// One asset at a time through the *existing* upload path: the bytes come
    /// from `loadData(for:)` into a temp file, and `uploadAsset` streams it from
    /// there — the screen owns no transport, no queue and no retry policy. An
    /// asset the server already has never leaves the device: that is exactly what
    /// the check bought.
    func uploadSelection() async {
        let pending = assets.filter { localOnlyIDs.contains($0.localIdentifier) }
        guard !pending.isEmpty, phase == .idle else { return }
        phase = .uploading
        uploadProgress = (done: 0, total: pending.count)
        defer {
            uploadProgress = nil
            phase = .idle
        }
        var sent: Set<String> = []
        for (index, asset) in pending.enumerated() {
            do {
                try await upload(asset)
                sent.insert(asset.localIdentifier)
            } catch {
                errorMessage = error.userFacingMessage
            }
            uploadProgress = (done: index + 1, total: pending.count)
        }
        if sent.count == pending.count {
            // Every asset made it: the whole local-only set is now on the
            // server.
            savedIDs.formUnion(localOnlyIDs)
            localOnlyIDs.removeAll()
        } else {
            // A partial run moves only what actually went up — an asset the
            // server never received must stay "not on the server", or the next
            // check would hide it.
            savedIDs.formUnion(sent)
            localOnlyIDs.subtract(sent)
        }
    }

    /// One asset through the shared upload path. `nonisolated` on purpose: the
    /// original is loaded, written to disk and hashed off the main actor — a
    /// multi-megabyte write must not stall the progress bar. The temp file is
    /// removed on every outcome, so a failed upload leaves no original behind.
    private nonisolated func upload(_ asset: PHAsset) async throws {
        let filename = Self.filename(for: asset)
        let data = try await photoLibrary.loadData(for: asset)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immich-local-upload", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(filename)
        try data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let timestamps = photoLibrary.isoTimestamps(for: asset)
        let checksum = try await checksum(of: asset)
        _ = try await client.uploadAsset(
            fileURL: fileURL,
            fileCreatedAt: timestamps.createdAt,
            fileModifiedAt: timestamps.modifiedAt,
            filename: filename,
            duration: asset.mediaType == .video ? Int(asset.duration.rounded()) : nil,
            isFavorite: asset.isFavorite,
            visibility: .timeline,
            livePhotoVideoId: nil,
            checksum: checksum,
            deviceAssetId: asset.localIdentifier,
            deviceId: DeviceIdentity.current
        )
    }

    /// The name the server stores the asset under: Photos' own filename when the
    /// resource still has one, otherwise a name derived from the identifier and
    /// the media type (the upload needs a name either way). `nonisolated`: the
    /// sending path runs off the main actor.
    private nonisolated static func filename(for asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        let original = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
        if let name = original?.originalFilename, !name.isEmpty { return name }
        let stem = asset.localIdentifier.replacingOccurrences(of: "/", with: "-")
        return "\(stem).\(asset.mediaType == .video ? "mov" : "jpg")"
    }

    // MARK: - Tiles

    /// Tile for one asset: the grid hands each cell this closure, so the cell
    /// never learns about the photo library.
    func loadThumbnail(for asset: PHAsset) async -> UIImage? {
        await photoLibrary.loadThumbnail(for: asset, targetSize: Self.tileSize, scale: UIScreen.main.scale)
    }
}
