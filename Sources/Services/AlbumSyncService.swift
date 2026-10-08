import Foundation

/// What one mirror window did. The counters are per flush: `flush` (and
/// `reorganize`, which ends in one) closes the window and hands them over, so a
/// summary can never mix two runs.
struct AlbumSyncOutcome: Sendable, Equatable {
    /// Assets the server put in the album.
    var added = 0
    /// The asset was already in the album (`DUPLICATE`) — a re-run, not an
    /// error. A second run over the same photos must report this, not a
    /// failure, or every run after the first looks broken.
    var alreadyInAlbum = 0
    /// `NO_PERMISSION` / `NOT_FOUND` / `UNKNOWN`, plus the album calls that
    /// threw outright.
    var failed = 0
    /// First failure message of the window, so the settings screen can say what
    /// went wrong without keeping a per-album log.
    var lastError: String?

    /// Nothing happened and nothing was reported. The engine keeps its previous
    /// summary instead of publishing a line of zeros to a user who never turned
    /// the mirror on.
    var isEmpty: Bool { added == 0 && alreadyInAlbum == 0 && failed == 0 && lastError == nil }
}

/// One-way device → server album mirror, driven by `BackupEngine`.
///
/// The state is deliberately small: the resolved `deviceAlbumID →
/// serverAlbumID` map, the inverse `deviceAssetID → deviceAlbumIDs` index the
/// asset source built, one buffer of server asset ids per server album, and
/// the running outcome. Which assets exist and which are already backed up is
/// the engine's and the ledger's business, not the mirror's.
actor AlbumSyncService: AlbumSyncServicing {
    private let mapping: any AlbumSyncMappingStoring
    private let batchSize: Int
    /// Resolved this process: device album id → server album id.
    private var deviceToServer: [String: String] = [:]
    /// Inverse index of `albumMembership`, remembered so `stage` never has to
    /// ask Photos where an asset lives.
    private var deviceAlbumIDsByAsset: [String: [String]] = [:]
    /// server album id → server asset ids waiting for the next flush.
    private var buffered: [String: Set<String>] = [:]
    /// The account `deviceToServer` was resolved for. The service lives as long
    /// as the process, so a mapping resolved for account A must never receive
    /// writes under account B's token — the server would answer `NOT_FOUND` per
    /// asset, and worse, a shared album id could match.
    private var resolvedForUserID: String?
    private var outcome = AlbumSyncOutcome()

    /// `batchSize` is injected, never hard-coded: the engine passes its own
    /// `checkChunkSize`, so dedup, reconciliation and album writes batch alike
    /// — one number to tune, and no second copy of it to drift.
    init(mapping: any AlbumSyncMappingStoring, batchSize: Int) {
        self.mapping = mapping
        self.batchSize = max(1, batchSize)
    }

    // MARK: - Resolution

    func resolveAlbums(
        deviceAlbums: [BackupAlbum],
        syncedDeviceAlbumIDs: Set<String>,
        albumMembership: [String: [String]],
        userID: String,
        client: any ImmichClient
    ) async throws -> [String: String] {
        // Rebuilt from scratch every run: a stale index would keep routing
        // assets of an album the user just unpicked.
        deviceAlbumIDsByAsset = albumMembership
        deviceToServer = [:]
        resolvedForUserID = nil

        let wanted = deviceAlbums.filter { !$0.isSmart && syncedDeviceAlbumIDs.contains($0.id) }
        guard !wanted.isEmpty else {
            resolvedForUserID = userID
            return [:]
        }

        // A persisted mapping is the whole point of the store: recycle it and
        // the run costs no `GET /albums` at all.
        var resolved: [String: String] = [:]
        var unresolved: [BackupAlbum] = []
        for album in wanted {
            if let mapped = mapping.serverAlbumID(userID: userID, deviceAlbumID: album.id) {
                resolved[album.id] = mapped
            } else {
                unresolved.append(album)
            }
        }
        let serverAlbums = unresolved.isEmpty ? [] : try await client.getAlbums()

        for album in unresolved {
            if let match = Self.nameMatch(of: album.name, in: serverAlbums, userID: userID) {
                resolved[album.id] = match
                mapping.record(userID: userID, deviceAlbumID: album.id, serverAlbumID: match)
                continue
            }
            do {
                // Name only: the mirror never invites users into the album, and
                // it never uploads through the creation call.
                let created = try await client.createAlbum(
                    dto: CreateAlbumDto(albumName: album.name, description: nil, assetIds: nil)
                )
                resolved[album.id] = created.id
                mapping.record(userID: userID, deviceAlbumID: album.id, serverAlbumID: created.id)
            } catch {
                // One album the server refuses must not cost the other ones
                // their mirror. Recorded, not thrown: the run continues.
                recordFailure(error)
            }
        }
        deviceToServer = resolved
        resolvedForUserID = userID
        return resolved
    }

    /// The album `name` already belongs to `userID`, or nil. Ownership comes
    /// first (`albumUsers.first` is always the owner server-side) because that
    /// is the album this mirror created; then an album merely shared with the
    /// user. An album owned by somebody else and not shared is not a match —
    /// merging into it would write into a stranger's album and come back
    /// `NO_PERMISSION` per asset.
    private static func nameMatch(of name: String, in albums: [AlbumResponseDto], userID: String) -> String? {
        let sameName = albums.filter { $0.albumName == name }
        if let owned = sameName.first(where: { $0.albumUsers.first?.user.id == userID }) {
            return owned.id
        }
        return sameName.first { $0.albumUsers.contains { $0.user.id == userID } }?.id
    }

    // MARK: - Buffering

    func stage(assetID: String, deviceAssetID: String) async {
        guard !deviceToServer.isEmpty else { return }
        for deviceAlbumID in deviceAlbumIDsByAsset[deviceAssetID] ?? [] {
            guard let serverAlbumID = deviceToServer[deviceAlbumID] else { continue }
            buffered[serverAlbumID, default: []].insert(assetID)
        }
    }

    func flush(client: any ImmichClient) async -> AlbumSyncOutcome {
        let pending = buffered
        buffered = [:]
        // Sorted so one run always sends the same bytes in the same order —
        // dictionaries have no order of their own.
        for albumID in pending.keys.sorted() {
            let ids = (pending[albumID] ?? []).sorted()
            var index = 0
            while index < ids.count {
                let chunk = Array(ids[index..<min(index + batchSize, ids.count)])
                index += batchSize
                do {
                    let results = try await client.addAssetsToAlbum(
                        albumId: albumID,
                        dto: BulkIdsDto(ids: chunk)
                    )
                    for result in results { record(result) }
                } catch {
                    // An album that fails must not drop the other albums'
                    // batches: everything not yet sent stays counted as failed
                    // and the flush goes on.
                    outcome.failed += chunk.count
                    if outcome.lastError == nil { outcome.lastError = error.userFacingMessage }
                }
            }
        }
        let window = outcome
        outcome = AlbumSyncOutcome()
        return window
    }

    /// `success` is an add; `DUPLICATE` means the asset was already there (a
    /// re-run, not a failure); anything else is a failure and keeps the first
    /// message, which is what the settings screen shows.
    private func record(_ result: BulkIdResponseDto) {
        if result.success {
            outcome.added += 1
            return
        }
        if result.error == .duplicate {
            outcome.alreadyInAlbum += 1
            return
        }
        outcome.failed += 1
        if outcome.lastError == nil {
            outcome.lastError = result.errorMessage ?? result.error?.rawValue
        }
    }

    private func recordFailure(_ error: Error) {
        outcome.failed += 1
        if outcome.lastError == nil { outcome.lastError = error.userFacingMessage }
    }

    // MARK: - Catch-up

    func reorganize(
        entries: [(id: String, checksum: String)],
        albumMembership: [String: [String]],
        userID: String,
        client: any ImmichClient
    ) async -> AlbumSyncOutcome {
        // The map belongs to the account that resolved it: another account's
        // albums are not writable with this token, so a mismatch means there is
        // nothing to reorganize into.
        guard resolvedForUserID == userID else {
            deviceToServer = [:]
            return await flush(client: client)
        }
        deviceAlbumIDsByAsset = albumMembership
        // Only entries whose device album has a server album can go anywhere,
        // and only those are worth a server round-trip.
        let candidates = entries.filter { entry in
            (albumMembership[entry.id] ?? []).contains { deviceToServer[$0] != nil }
        }
        guard !candidates.isEmpty else { return await flush(client: client) }

        var index = 0
        while index < candidates.count {
            let chunk = Array(candidates[index..<min(index + batchSize, candidates.count)])
            index += batchSize
            do {
                // `POST /api/assets/bulk-upload-check` (`checkBulkUpload`): the
                // ledger stores no server id, so this is the only way back to an
                // asset that was uploaded before the mirror existed.
                let response = try await client.bulkUploadCheck(
                    AssetBulkUploadCheckRequest(assets: chunk.map {
                        AssetBulkUploadCheckRequest.Item(id: $0.id, checksum: $0.checksum)
                    })
                )
                for result in response.results {
                    // No `assetId` = the server answered "accept" (it does not
                    // have it — an upload is missing, not a mirror job), and a
                    // trashed asset is on its way out. Neither belongs in an
                    // album.
                    guard let remoteID = result.assetId, result.isTrashed != true else { continue }
                    await stage(assetID: remoteID, deviceAssetID: result.id)
                }
            } catch {
                recordFailure(error)
            }
        }
        return await flush(client: client)
    }
}
