import Foundation

/// Abstraction over the Immich HTTP API.
///
/// All methods are async throws and return decoded DTOs. The client is
/// responsible for: attaching the bearer token, URL construction, decoding,
/// and surfacing `.unauthorized` on 401 (FM-4).
///
/// A single `requestCount` is exposed to aid MVVM testing (AC-009).
protocol ImmichClient: AnyObject, Sendable {
    /// Configures the server base URL + bearer token. Called by AuthViewModel.
    func configure(baseURL: URL?, token: String?)

    /// Delegate notified on global 401 (FM-4).
    var authDelegate: (any AuthSessionDelegate)? { get set }

    func ping() async throws -> ServerPingResponse
    func serverVersion() async throws -> ServerVersionResponseDto
    func serverConfig() async throws -> ServerConfigDto

    func login(email: String, password: String) async throws -> LoginResponseDto
    func logout() async throws -> LogoutResponseDto
    /// `POST /api/auth/change-password` — replaces the current password.
    ///
    /// The return type is the server's `UserAdminResponseDto` for the updated
    /// user, not `Void`: it is the only server-side proof that
    /// `shouldChangePassword` fell back to `false` (`auth.service.ts:140`).
    /// A wrong current password is a **400** (`BadRequestException('Wrong
    /// password')`), so the global 401 handler must not run for a typo.
    func changePassword(
        currentPassword: String,
        newPassword: String,
        invalidateSessions: Bool
    ) async throws -> UserAdminResponseDto
    /// `GET /api/users/me` read as the auth seam: `AuthViewModel` re-reads the
    /// server's `shouldChangePassword` flag with it, after a login or during a
    /// session. `getMyUser()` serves the same route for the profile screen.
    func currentUser() async throws -> UserAdminResponseDto
    func validateToken() async throws -> ValidateAccessTokenResponseDto
    func authorizeOAuth(redirectURI: String, state: String, codeChallenge: String) async throws -> OAuthAuthorizeResponseDto
    /// Returns the same payload as `login` — the server replies with `LoginResponseDto`.
    func exchangeOAuthCode(url: String, state: String, codeVerifier: String) async throws -> LoginResponseDto

    // MARK: - Timeline (P0: person/partner/visibility filters)
    /// `GET /api/timeline/buckets` — optional filters; all extra params default nil.
    ///
    /// `orderBy` is the sort axis of the buckets themselves: `orderBy: .createdAt`
    /// asks `GET /api/timeline/buckets?orderBy=createdAt`, so each `timeBucket`
    /// is a day of **upload** and the grid reads "recently added". `nil` leaves
    /// the server default (`takenAt`). This is the only route that can sort by
    /// upload date — `POST /api/search/metadata` has no such order field.
    func getTimeBuckets(
        isFavorite: Bool?,
        isTrashed: Bool?,
        personId: String?,
        withPartners: Bool?,
        visibility: String?,
        withStacked: Bool?,
        orderBy: AssetOrderBy?
    ) async throws -> [TimeBucketsResponseDto]
    /// `GET /api/timeline/bucket` — every filter must be the value sent to
    /// `getTimeBuckets` for the same list of months, otherwise the server
    /// applies its defaults (no `orderBy=createdAt` → the month is filled by
    /// date taken; no `isTrashed` → only non-trashed; no `isFavorite` → all).
    func getTimeBucket(
        timeBucket: String,
        isFavorite: Bool?,
        isTrashed: Bool?,
        personId: String?,
        withPartners: Bool?,
        visibility: String?,
        withStacked: Bool?,
        orderBy: AssetOrderBy?
    ) async throws -> TimeBucketAssetResponseDto

    func getAsset(id: String) async throws -> AssetResponseDto
    func updateAsset(id: String, dto: UpdateAssetDto) async throws -> AssetResponseDto
    /// `PATCH /api/assets/:id` with an explicit `rating` — `nil` must reach the
    /// wire as JSON `null` (the synthesized encoder of `UpdateAssetDto` would
    /// drop the key), and the response is the updated asset, so the caller
    /// never needs a follow-up `getAsset`.
    func setAssetRating(id: String, rating: Int?) async throws -> AssetResponseDto
    func deleteAssets(ids: [String], force: Bool?) async throws

    // MARK: - Trash (AC-300..AC-309)
    func restoreTrashAssets(ids: [String]) async throws -> TrashResponseDto
    func restoreAllTrash() async throws -> TrashResponseDto
    func emptyTrash() async throws -> TrashResponseDto

    // MARK: - Search (AC-400..AC-406)
    func searchMetadata(dto: MetadataSearchDto) async throws -> SearchResponseDto
    func searchSmart(dto: SmartSearchDto) async throws -> SearchResponseDto
    func getExploreData() async throws -> [SearchExploreResponseDto]
    /// `GET /api/search/cities` — one representative asset per distinct city
    /// (no 12-cap, no ≥5-photo floor). Powers the Explore Places list.
    func getAssetsByCity() async throws -> [AssetResponseDto]
    /// `GET /api/view/folder?path=` — the assets laid **directly** in that folder:
    /// the server filters `originalPath LIKE '%<path>/%' AND NOT LIKE '%<path>/%/%'`,
    /// so there is no recursion and no pagination. The path may carry or omit its
    /// leading slash (the pattern is wrapped in `%`); trailing slashes are stripped
    /// server-side, and `""` or `"/"` both mean "files sitting at the filesystem
    /// root". Archived and locked assets never come back: the server filters on
    /// `visibility = timeline` and no parameter opens that.
    func getFolderAssets(path: String) async throws -> [AssetResponseDto]
    /// `GET /api/view/folder/unique-paths` — every distinct directory holding a
    /// timeline asset: absolute, without a trailing slash, and `""` for assets
    /// sitting at the filesystem root. No parameter, no pagination: the whole
    /// directory comes back in one response (the tree is built client-side).
    func getUniqueFolderPaths() async throws -> [String]
    /// `POST /api/search/statistics` — total asset count for a metadata filter.
    func searchStatistics(dto: SearchStatisticsDto) async throws -> SearchStatisticsResponseDto

    // MARK: - Map (AC-710)
    /// `GET /api/map/markers` — every geolocated asset, narrowed by `filter`
    /// (it carries the whole `GET` surface of the route, including the
    /// `fileCreatedAfter`/`fileCreatedBefore` time window).
    func getMapMarkers(filter: MapMarkerFilter) async throws -> [MapMarkerResponseDto]

    // MARK: - Albums (AC-500..AC-518)
    func getAlbums() async throws -> [AlbumResponseDto]
    func createAlbum(dto: CreateAlbumDto) async throws -> AlbumResponseDto
    func getAlbum(id: String) async throws -> AlbumResponseDto
    func updateAlbum(id: String, dto: UpdateAlbumDto) async throws -> AlbumResponseDto
    func deleteAlbum(id: String) async throws
    func addAssetsToAlbum(albumId: String, dto: BulkIdsDto) async throws -> [BulkIdResponseDto]
    func removeAssetsFromAlbum(albumId: String, dto: BulkIdsDto) async throws -> [BulkIdResponseDto]

    // MARK: - Album users (share to instance users)
    func addUsersToAlbum(albumId: String, dto: AddUsersDto) async throws -> AlbumResponseDto
    func updateAlbumUserRole(albumId: String, userId: String, dto: UpdateAlbumUserDto) async throws
    func removeUserFromAlbum(albumId: String, userId: String) async throws

    // MARK: - Shared Links (AC-500..AC-518)
    func getSharedLinks(albumId: String?) async throws -> [SharedLinkResponseDto]
    func createSharedLink(dto: SharedLinkCreateDto) async throws -> SharedLinkResponseDto
    /// `PATCH /api/shared-links/{id}` — edit slug, expiry, upload/download
    /// toggles, metadata visibility. The server exposes **PATCH**, not PUT.
    ///
    /// `dto.slug` is always applied: an omitted slug clears the link's slug
    /// server-side, so callers must echo the current value when they are not
    /// changing it.
    func updateSharedLink(id: String, dto: SharedLinkEditDto) async throws -> SharedLinkResponseDto
    /// `PUT /api/shared-links/{id}/assets` body `AssetIdsDto` — the OWNER adds
    /// assets to an `INDIVIDUAL` link (an `ALBUM` link answers 400). A visitor
    /// cannot call this: it needs the `SharedLinkUpdate` permission.
    @discardableResult
    func addAssetsToSharedLink(id: String, assetIds: [String]) async throws -> [AssetIdsResponseDto]
    func deleteSharedLink(id: String) async throws

    // MARK: - Opening a shared link (issue #22 — visitor side)
    //
    // These four calls carry no bearer token: the credential goes in the query
    // (`?key=` / `?slug=`) and the server authenticates the request with
    // `AuthService.validateSharedLinkKey` / `…Slug`. Their failures are
    // therefore about the *link* (a password is required, the password is
    // wrong, the link is revoked or expired, uploads are not allowed) and never
    // about the signed-in session — see `ImmichAPIClient.sendSharedLinkRaw`.

    /// `GET /api/shared-links/me?key=|slug=` — the link as its owner's browser
    /// would see it. 401 `"Password required"` means the caller must call
    /// `loginToSharedLink` first; any other 401 means the link is dead.
    func getSharedLinkMine(_ credential: SharedLinkCredential) async throws -> SharedLinkResponseDto

    /// `POST /api/shared-links/login?key=|slug=` body `{password}` — exchanges
    /// the password for the DTO **and** for the session cookie the server sets
    /// (`immich_shared_link_token`). The client replays that cookie on every
    /// later visitor request; nothing else makes `getSharedLinkMine` succeed on
    /// a protected link (the web client navigates again after login and relies
    /// on exactly this cookie).
    func loginToSharedLink(_ credential: SharedLinkCredential, password: String) async throws -> SharedLinkResponseDto

    /// `POST /api/search/metadata?key=|slug=` with `albumIds: [albumId]` — how
    /// an **album** link's assets are listed. `SharedLinkResponseDto.album` has
    /// no `assets` array (`AlbumResponseDto` never carries one), and the server
    /// refuses an unfiltered metadata search under shared-link auth
    /// (`"Shared link access is only allowed in combination with an albumIds
    /// filter"`). An INDIVIDUAL link needs no call at all: its assets come
    /// inlined in `getSharedLinkMine`.
    func getSharedLinkAlbumAssets(
        _ credential: SharedLinkCredential,
        albumId: String,
        page: Int,
        size: Int
    ) async throws -> SearchResponseDto

    /// `POST /api/assets?key=|slug=` — a guest upload. The server gates it with
    /// `requireUploadAccess`: a bare **401** means this link does not allow
    /// uploads (`allowUpload == false`). The asset lands in the link's album
    /// (`AssetMediaService.addToSharedLink`).
    func uploadAssetToSharedLink(
        fileURL: URL,
        filename: String,
        fileCreatedAt: String,
        fileModifiedAt: String,
        checksum: String,
        deviceAssetId: String,
        deviceId: String,
        credential: SharedLinkCredential
    ) async throws -> AssetMediaResponseDto

    // MARK: - Tags (gap #2)
    func getAllTags() async throws -> [TagResponseDto]
    func createTag(name: String, color: String?) async throws -> TagResponseDto
    func updateTag(id: String, color: String?) async throws -> TagResponseDto
    func deleteTag(id: String) async throws
    /// `PUT /api/tags/{id}/assets` — add assets to a tag.
    func tagAssets(tagId: String, assetIds: [String]) async throws
    /// `DELETE /api/tags/{id}/assets` — remove assets from a tag.
    func untagAssets(tagId: String, assetIds: [String]) async throws

    // MARK: - People (P0 api-surface-expansion)
    func getPeople(page: Int?, withHidden: Bool?) async throws -> PeopleResponseDto
    func createPerson(name: String) async throws -> PersonResponseDto
    func updatePerson(id: String, dto: PersonUpdateDto) async throws -> PersonResponseDto
    /// Same route as `updatePerson` (`PUT /api/people/{id}`), with the
    /// `PersonBirthdayClearDto` body that sends the explicit `null` an erase
    /// needs — `PersonUpdateDto(birthDate: nil)` omits the key entirely.
    func clearPersonBirthday(id: String) async throws -> PersonResponseDto
    /// `POST /api/people/{id}/merge` — merge persons; returns bulk results.
    func mergePeople(ids: [String], into id: String) async throws -> [BulkIdResponseDto]
    func getPersonStatistics(id: String) async throws -> PersonStatisticsResponseDto
    /// `PUT /api/faces/{personId}` body `{ id: faceId }` — re-assign one face (gap #5).
    func reassignFace(faceId: String, toPersonId: String) async throws -> PersonResponseDto
    /// `GET /api/faces?id={assetId}` — all faces detected on an asset (gap #5).
    func getFaces(assetId: String) async throws -> [AssetFaceResponseDto]
    /// `GET /api/assets/{id}/ocr` — the text boxes the server detected on an
    /// asset (gap #8, ocr-text). Readable under the normal read permission; the
    /// array is empty when nothing was detected — an empty answer is NOT an
    /// error.
    func getAssetOcr(id: String) async throws -> [AssetOcrResponseDto]

    // MARK: - Partners (P0 api-surface-expansion; direction corrected 2026-09-13)
    /// `GET /api/partners?direction=` — `direction` is **required**; without it
    /// the server answers 400. The response always carries the *other* user of
    /// the pair (see `PartnerDirection`).
    func getPartners(direction: PartnerDirection) async throws -> [PartnerResponseDto]
    /// `POST /api/partners` body `{ sharedWithId }` — the server takes a user
    /// id, never an email.
    func createPartner(sharedWithId: String) async throws -> PartnerResponseDto
    /// `PUT /api/partners/{id}` — valid **only** for a row from
    /// `getPartners(direction: .sharedWith)`: the server pairs `{sharedById: id,
    /// sharedWithId: me}`.
    func updatePartner(id: String, isInTimeline: Bool) async throws -> PartnerResponseDto
    /// `DELETE /api/partners/{id}` — valid **only** for a row from
    /// `getPartners(direction: .sharedBy)`: the server pairs `{sharedById: me,
    /// sharedWithId: id}`.
    func removePartner(id: String) async throws

    // MARK: - Activity (P0 api-surface-expansion)
    func getActivities(albumId: String, assetId: String?) async throws -> [ActivityResponseDto]
    func createActivity(dto: ActivityCreateDto) async throws -> ActivityResponseDto
    func deleteActivity(id: String) async throws

    // MARK: - Memories (P0 api-surface-expansion; CRUD added 2026-09-13)
    func getMemories() async throws -> [MemoryResponseDto]
    /// `GET /api/memories/{id}` — one memory. Used to re-read a memory after a
    /// mutation that answers with per-asset results rather than the memory.
    func getMemory(id: String) async throws -> MemoryResponseDto
    /// `PUT /api/memories/{id}` — **PUT**, not PATCH: the published OpenAPI
    /// exposes `get|put|delete` on this route and no PATCH (a PATCH 404s, the
    /// same trap the shared-links edit had).
    func updateMemory(id: String, dto: MemoryUpdateDto) async throws -> MemoryResponseDto
    func deleteMemory(id: String) async throws
    /// `POST /api/memories` body `MemoryCreateDto` — `data`, `memoryAt` and
    /// `type` are required; there is no name field anywhere in the memory API.
    func createMemory(dto: MemoryCreateDto) async throws -> MemoryResponseDto
    /// `PUT /api/memories/{id}/assets` body `BulkIdsDto` — **PUT** (the route is
    /// `put|delete`, so a POST 404s), answers one `BulkIdResponseDto` per id.
    @discardableResult
    func addAssetsToMemory(id: String, assetIds: [String]) async throws -> [BulkIdResponseDto]
    /// `DELETE /api/memories/{id}/assets` body `BulkIdsDto` — answers one
    /// `BulkIdResponseDto` per id (200, not 204).
    @discardableResult
    func removeAssetsFromMemory(id: String, assetIds: [String]) async throws -> [BulkIdResponseDto]
    /// `GET /api/memories/statistics` — the server's memory count. Part of the
    /// api-surface expansion: it is what the server's own paging answers to
    /// (`size`/`page` on `GET /api/memories` only take effect when the caller
    /// passes `size`), and no screen consumes it yet.
    func getMemoriesStatistics() async throws -> MemoryStatisticsResponseDto

    // MARK: - Duplicates (P0 api-surface-expansion)
    func getDuplicates() async throws -> [DuplicateResponseDto]

    // MARK: - Stacks (gap #1)
    func searchStacks(primaryAssetId: String?) async throws -> [StackResponseDto]
    func createStack(assetIds: [String]) async throws -> StackResponseDto
    func getStack(id: String) async throws -> StackResponseDto
    func updateStack(id: String, primaryAssetId: String?) async throws -> StackResponseDto
    func deleteStack(id: String) async throws
    func removeAssetFromStack(stackId: String, assetId: String) async throws

    // MARK: - Admin (gap #12)
    func getAdminUsers() async throws -> [UserAdminResponseDto]
    func createAdminUser(dto: UserAdminCreateDto) async throws -> UserAdminResponseDto
    func updateAdminUser(id: String, dto: UserAdminUpdateDto) async throws -> UserAdminResponseDto
    func deleteAdminUser(id: String, force: Bool) async throws -> UserAdminResponseDto
    func restoreAdminUser(id: String) async throws -> UserAdminResponseDto
    func getJobsStatus() async throws -> [String: QueueResponseLegacyDto]
    func sendJobCommand(name: String, command: String, force: Bool?) async throws -> QueueResponseLegacyDto
    func getLibraries() async throws -> [LibraryResponseDto]
    func scanLibrary(id: String) async throws
    func deleteLibrary(id: String) async throws
    /// `GET /api/api-keys` — the keys of the current user (`apiKey.read`, not an
    /// admin permission: the bearer of the token owns them).
    func getAPIKeys() async throws -> [ApiKeyResponseDto]
    /// `GET /api/api-keys/me` — the key that carries this very request, in the
    /// singular. Never the list, and a session-authenticated caller may have no
    /// such key at all.
    func getMyAPIKey() async throws -> ApiKeyResponseDto
    /// `POST /api/api-keys` — `permissions` is the full scope list (`["all"]`
    /// for a wildcard key). The answer carries the secret, readable once.
    func createAPIKey(name: String, permissions: [String]) async throws -> ApiKeyCreateResponseDto
    /// `POST /api/api-keys/{id}/rotate` — **POST**, not PUT: the route exposes no
    /// other verb. Answers the same body as a creation: the new secret.
    func rotateAPIKey(id: String) async throws -> ApiKeyCreateResponseDto
    func deleteAPIKey(id: String) async throws

    // MARK: - Sessions (gap G19)

    /// `GET /api/sessions` — every session of the account, the one in use
    /// flagged by `current`. No query, no parameters.
    func getSessions() async throws -> [SessionResponseDto]

    /// `DELETE /api/sessions/{id}` — 204. The server leaves the **current**
    /// session alone even when its own id is named, so a client can never sign
    /// itself out through this route.
    func deleteSession(id: String) async throws

    /// `DELETE /api/sessions` — 204, and deliberately not the current session:
    /// the server excludes it. "Log out other devices", never "log out
    /// everywhere".
    func deleteAllSessions() async throws

    // MARK: - Server statistics (P0 api-surface-expansion)
    func getServerStatistics() async throws -> ServerStatsResponseDto

    // MARK: - Locked folder (gap G12)

    /// `GET /api/auth/status` — whether the session is elevated (locked assets
    /// readable) and whether a PIN exists yet.
    func getAuthStatus() async throws -> AuthStatusResponseDto

    /// `POST /api/auth/pin-code` — creates the 6-digit PIN that guards the
    /// locked folder. A PIN already set is answered 400 (use `changePinCode`).
    func setupPinCode(_ pinCode: String) async throws

    /// `PUT /api/auth/pin-code` — replaces the PIN; `dto` carries the new PIN
    /// plus the old PIN or the account password.
    func changePinCode(dto: PinCodeChangeDto) async throws

    /// `POST /api/auth/session/unlock` — temporarily elevates the session
    /// ("Temporarily grant the session elevated access to locked assets").
    /// Both session routes require a **session token**: an account
    /// authenticated with an API key is answered 400.
    func unlockAuthSession(pinCode: String) async throws

    /// `POST /api/auth/session/lock` — drops the elevation, bodyless.
    func lockAuthSession() async throws

    // MARK: - Bulk asset update (P0: archive via visibility)
    func bulkUpdateAssets(dto: AssetBulkUpdateDto) async throws

    // MARK: - Users (photo share — shared-album user picker)
    func getUsers() async throws -> [UserResponseDto]

    // MARK: - Profile picture (gap G16)

    /// `GET /api/users/me` — the signed-in user's own row. It is the only
    /// source of `profileImagePath` / `profileChangedAt`, so it is what the
    /// Profile Picture screen reads instead of trusting a cached copy.
    func getMyUser() async throws -> UserAdminResponseDto

    /// `POST /api/users/profile-image` — `multipart/form-data` with the single
    /// binary field `file` (`CreateProfileImageDto`); answers `201` with the
    /// new path + timestamp.
    func uploadProfileImage(fileURL: URL, filename: String, contentType: String) async throws -> CreateProfileImageResponseDto

    /// `DELETE /api/users/profile-image` — `204`, no body. The route takes no
    /// `{id}`: a user can only remove their own photo.
    func deleteProfileImage() async throws

    /// Uploads an asset via streamed multipart/form-data — the body is
    /// assembled from `fileURL` on disk, never held in memory.
    /// `checksum` is base64-encoded SHA1 (also sent as `x-immich-checksum` header).
    /// `deviceAssetId` is the source Photos identifier and `deviceId` this
    /// installation's stable id: together they let the server attribute the
    /// asset to a device, which is what the web UI's device filter and any
    /// per-device server-side query rely on.
    func uploadAsset(
        fileURL: URL,
        fileCreatedAt: String,
        fileModifiedAt: String,
        filename: String,
        duration: Int?,
        isFavorite: Bool,
        visibility: AssetVisibility,
        livePhotoVideoId: String?,
        checksum: String,
        deviceAssetId: String,
        deviceId: String
    ) async throws -> AssetMediaResponseDto

    func bulkUploadCheck(_ request: AssetBulkUploadCheckRequest) async throws -> AssetBulkUploadCheckResponse

    // MARK: - Download queue (gap G10)

    /// `POST /api/download/info` — announces a batch before its bytes are
    /// asked for.
    ///
    /// The server splits the request into archives itself (size/time caps) and
    /// answers one `Archive` per chunk with the total volume; the route that
    /// returns the bytes refuses a batch it was never told about ("assets must
    /// have been previously requested via the getDownloadInfo endpoint"), so
    /// this call is mandatory for anything but a single asset.
    func downloadInfo(assetIds: [String], albumId: String?) async throws -> DownloadInfoResponse

    /// `GET /api/assets/{id}/original` as a `URLRequest`, bearer included.
    ///
    /// The client stops at the request on purpose: the body is streamed to
    /// disk by `FileDownloadTransport`, and a `Data`-returning method here
    /// would hold a multi-gigabyte original in memory.
    func originalRequest(assetId: String) throws -> URLRequest

    /// `POST /api/download/archive` as a `URLRequest` — the ZIP of one archive
    /// `downloadInfo` returned. Same split: request here, streaming there.
    func downloadArchiveRequest(archiveName: String, assetIds: [String], edited: Bool) throws -> URLRequest

    /// Number of requests dispatched since creation (test aid).
    var requestCount: Int { get }
}

extension ImmichClient {
    /// Timeline buckets in the server's default order (`takenAt`).
    ///
    /// Swift forbids a default argument on a protocol requirement, and
    /// `orderBy` arrived with the "recently added" view (G13) after every other
    /// caller already existed: an overload is how this repository has always
    /// widened a requirement without breaking its call sites.
    func getTimeBuckets(
        isFavorite: Bool?,
        isTrashed: Bool?,
        personId: String?,
        withPartners: Bool?,
        visibility: String?,
        withStacked: Bool?
    ) async throws -> [TimeBucketsResponseDto] {
        try await getTimeBuckets(
            isFavorite: isFavorite,
            isTrashed: isTrashed,
            personId: personId,
            withPartners: withPartners,
            visibility: visibility,
            withStacked: withStacked,
            orderBy: nil
        )
    }

    /// One timeline bucket without `isFavorite`, `isTrashed` or `orderBy`.
    ///
    /// Swift forbids a default argument on a protocol requirement: same
    /// overload pattern as `getTimeBuckets` above, so callers that never
    /// filtered on those three keep compiling.
    func getTimeBucket(
        timeBucket: String,
        personId: String?,
        withPartners: Bool?,
        visibility: String?,
        withStacked: Bool?
    ) async throws -> TimeBucketAssetResponseDto {
        try await getTimeBucket(
            timeBucket: timeBucket,
            isFavorite: nil,
            isTrashed: nil,
            personId: personId,
            withPartners: withPartners,
            visibility: visibility,
            withStacked: withStacked,
            orderBy: nil
        )
    }
}

/// What `POST /api/download/info` answers for a batch download: the archives
/// the server decided to make, and the volume they add up to.
struct DownloadInfoResponse: Sendable, Equatable {
    /// One archive the server will build — its member assets and its size.
    struct Archive: Sendable, Equatable {
        let assetIds: [String]
        let size: Int64
    }

    /// Total bytes across every archive.
    let totalSize: Int64
    let archives: [Archive]
}
