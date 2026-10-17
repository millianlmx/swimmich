import Foundation

/// Delegate notified on global 401 (FM-4) so AuthViewModel can reset auth state
/// without the client holding a back-reference (avoids circular dependency).
protocol AuthSessionDelegate: AnyObject, Sendable {
    func didReceiveUnauthorized()
}

/// URLSession-backed ImmichClient implementation.
///
/// Notes:
/// - Holds the bearer token + base URL set by the AuthViewModel.
/// - On 401 anywhere → throws `.unauthorized` AND notifies `authDelegate` (FM-4).
/// - `requestCount` increments on every network dispatch (AC-009).
final class ImmichAPIClient: ImmichClient, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()

    private var _token: String?
    private var _baseURL: URL?
    private var _requestCount: Int = 0

    /// Session cookie returned by `POST /api/shared-links/login`
    /// (`immich_shared_link_token`), replayed verbatim on later visitor
    /// requests. Held in memory only: a link's password lives for the length of
    /// a visit, and a visitor cookie has no business surviving a relaunch.
    /// One slot is enough — the server validates the token against *its own*
    /// link id, so a stale token for a previously opened link is simply
    /// ignored and answered with `"Password required"`.
    private var _sharedLinkCookie: String?

    /// Where every dispatch line goes (gap G24). Defaulted to the sink that
    /// keeps nothing, so the transport stays usable — and silent — with no log
    /// attached: tests, previews, and any extension that builds a client.
    private let log: any AppLogSink

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requestCount }

    weak var authDelegate: AuthSessionDelegate?

    init(
        session: URLSession = .shared,
        trustStore: TrustedServerStore? = nil,
        log: any AppLogSink = NoopAppLogSink()
    ) {
        self.log = log
        if let trustStore {
            let delegate = TrustEvaluatingURLSessionDelegate(trustStore: trustStore)
            let config = URLSessionConfiguration.ephemeral
            self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        } else {
            self.session = session
        }
    }

    // MARK: - Configuration

    func configure(baseURL: URL?, token: String?) {
        lock.lock(); defer { lock.unlock() }
        _baseURL = baseURL
        _token = token
    }

    /// Drops every open connection, cache and credential of this client's own
    /// session, so the next request opens a fresh socket and a fresh TLS
    /// handshake — hence a fresh trust challenge. Used by the voluntary-logout
    /// purge: a previously trusted self-signed host must be asked about again.
    /// `URLSession.shared` belongs to the whole process and is never reset.
    func resetConnections() async {
        guard session !== URLSession.shared else { return }
        await session.reset()
    }

    var baseURL: URL? { lock.lock(); defer { lock.unlock() }; return _baseURL }
    var token: String? { lock.lock(); defer { lock.unlock() }; return _token }

    private func bumpRequestCount() {
        lock.lock(); _requestCount += 1; lock.unlock()
    }

    // MARK: - Server

    func ping() async throws -> ServerPingResponse {
        try await sendNoAuth(.GET, path: ImmichAPI.server.path("/ping"))
    }

    func serverVersion() async throws -> ServerVersionResponseDto {
        try await sendNoAuth(.GET, path: ImmichAPI.server.path("/version"))
    }

    func serverConfig() async throws -> ServerConfigDto {
        try await sendNoAuth(.GET, path: ImmichAPI.server.path("/config"))
    }

    // MARK: - Auth

    func login(email: String, password: String) async throws -> LoginResponseDto {
        try await sendNoAuth(.POST, path: ImmichAPI.auth.path("/login"), body: AnyEncodable(LoginCredentialDto(email: email, password: password)))
    }

    func logout() async throws -> LogoutResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.auth.path("/logout"))
    }

    /// `POST /api/auth/change-password` (gap G18). The body is the exact
    /// three-field `ChangePasswordDto`; the reply is the updated user, whose
    /// `shouldChangePassword` is the server's own confirmation.
    func changePassword(
        currentPassword: String,
        newPassword: String,
        invalidateSessions: Bool
    ) async throws -> UserAdminResponseDto {
        try await sendAuthed(
            .POST,
            path: ImmichAPI.auth.path("/change-password"),
            body: AnyEncodable(ChangePasswordDto(password: currentPassword, newPassword: newPassword, invalidateSessions: invalidateSessions))
        )
    }

    func validateToken() async throws -> ValidateAccessTokenResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.auth.path("/validateToken"))
    }

    // MARK: - Locked folder (gap G12)

    func getAuthStatus() async throws -> AuthStatusResponseDto {
        try await sendAuthed(.GET, path: ImmichAPI.auth.path("/status"))
    }

    func setupPinCode(_ pinCode: String) async throws {
        _ = try await sendAuthedRaw(
            .POST,
            path: ImmichAPI.auth.path("/pin-code"),
            body: AnyEncodable(PinCodeSetupDto(pinCode: pinCode))
        )
    }

    func changePinCode(dto: PinCodeChangeDto) async throws {
        _ = try await sendAuthedRaw(.PUT, path: ImmichAPI.auth.path("/pin-code"), body: AnyEncodable(dto))
    }

    /// POST (not PUT) on the session routes: the server creates an elevation
    /// for the current session rather than replacing a resource.
    func unlockAuthSession(pinCode: String) async throws {
        _ = try await sendAuthedRaw(
            .POST,
            path: ImmichAPI.auth.path("/session/unlock"),
            body: AnyEncodable(SessionUnlockDto(pinCode: pinCode))
        )
    }

    /// Bodyless on purpose: the route drops the elevation for the whole
    /// session, so there is nothing to name.
    func lockAuthSession() async throws {
        _ = try await sendAuthedRaw(.POST, path: ImmichAPI.auth.path("/session/lock"), body: nil)
    }

    // MARK: - OAuth (P5 oauth)

    func authorizeOAuth(redirectURI: String, state: String, codeChallenge: String) async throws -> OAuthAuthorizeResponseDto {
        try await sendNoAuth(
            .POST,
            path: ImmichAPI.oauthAuthorize.path(""),
            body: AnyEncodable(
                OAuthAuthorizeRequestDto(redirectUri: redirectURI, state: state, codeChallenge: codeChallenge)
            )
        )
    }

    func exchangeOAuthCode(url: String, state: String, codeVerifier: String) async throws -> LoginResponseDto {
        try await sendNoAuth(
            .POST,
            path: ImmichAPI.oauthCallback.path(""),
            body: AnyEncodable(OAuthCallbackRequestDto(url: url, state: state, codeVerifier: codeVerifier))
        )
    }

    // MARK: - Timeline

    func getTimeBuckets(
        isFavorite: Bool?,
        isTrashed: Bool?,
        personId: String?,
        withPartners: Bool?,
        visibility: String?,
        withStacked: Bool?,
        orderBy: AssetOrderBy?
    ) async throws -> [TimeBucketsResponseDto] {
        var query: [URLQueryItem] = []
        if let isFavorite { query.append(URLQueryItem(name: "isFavorite", value: String(isFavorite))) }
        if let isTrashed { query.append(URLQueryItem(name: "isTrashed", value: String(isTrashed))) }
        if let personId { query.append(URLQueryItem(name: "personId", value: personId)) }
        if let withPartners { query.append(URLQueryItem(name: "withPartners", value: String(withPartners))) }
        if let visibility { query.append(URLQueryItem(name: "visibility", value: visibility)) }
        if let withStacked { query.append(URLQueryItem(name: "withStacked", value: String(withStacked))) }
        if let orderBy { query.append(URLQueryItem(name: "orderBy", value: orderBy.rawValue)) }
        return try await sendAuthed(.GET, path: ImmichAPI.timeline.path("/buckets"), query: query)
    }

    func getTimeBucket(
        timeBucket: String,
        personId: String?,
        withPartners: Bool?,
        visibility: String?,
        withStacked: Bool?
    ) async throws -> TimeBucketAssetResponseDto {
        var query: [URLQueryItem] = [URLQueryItem(name: "timeBucket", value: timeBucket)]
        if let personId { query.append(URLQueryItem(name: "personId", value: personId)) }
        if let withPartners { query.append(URLQueryItem(name: "withPartners", value: String(withPartners))) }
        if let visibility { query.append(URLQueryItem(name: "visibility", value: visibility)) }
        if let withStacked { query.append(URLQueryItem(name: "withStacked", value: String(withStacked))) }
        return try await sendAuthed(.GET, path: ImmichAPI.timeline.path("/bucket"), query: query)
    }

    // MARK: - Asset actions

    func getAsset(id: String) async throws -> AssetResponseDto {
        try await sendAuthed(.GET, path: ImmichAPI.assets.path("/\(id)"))
    }

    func updateAsset(id: String, dto: UpdateAssetDto) async throws -> AssetResponseDto {
        try await sendAuthed(.PATCH, path: ImmichAPI.assets.path("/\(id)"), body: AnyEncodable(dto))
    }

    /// Same verb/path as `updateAsset`, but with a body whose `rating` key is
    /// always present — `null` clears the rating, which `UpdateAssetDto`
    /// (synthesized encoder, `Int?` nil omitted) cannot express.
    func setAssetRating(id: String, rating: Int?) async throws -> AssetResponseDto {
        try await sendAuthed(.PATCH, path: ImmichAPI.assets.path("/\(id)"), body: AnyEncodable(RatingUpdateDto(rating: rating)))
    }

    func deleteAssets(ids: [String], force: Bool?) async throws {
        let body = AnyEncodable(AssetBulkDeleteDto(ids: ids, force: force))
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.assets.path(""), body: body)
    }

    // MARK: - Trash (AC-307..AC-309)

    func restoreTrashAssets(ids: [String]) async throws -> TrashResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.trash.path("/restore/assets"), body: AnyEncodable(BulkIdsDto(ids: ids)))
    }

    func restoreAllTrash() async throws -> TrashResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.trash.path("/restore"), body: nil)
    }

    func emptyTrash() async throws -> TrashResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.trash.path("/empty"), body: nil)
    }

    // MARK: - Search (AC-400..AC-406)

    func searchMetadata(dto: MetadataSearchDto) async throws -> SearchResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.search.path("/metadata"), body: AnyEncodable(dto))
    }

    func searchSmart(dto: SmartSearchDto) async throws -> SearchResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.search.path("/smart"), body: AnyEncodable(dto))
    }

    func getExploreData() async throws -> [SearchExploreResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.search.path("/explore"))
    }

    func getAssetsByCity() async throws -> [AssetResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.search.path("/cities"))
    }

    // MARK: - Folder view (gap G11)

    func getFolderAssets(path: String) async throws -> [AssetResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.view.path("/folder"), query: [URLQueryItem(name: "path", value: path)])
    }

    func getUniqueFolderPaths() async throws -> [String] {
        try await sendAuthed(.GET, path: ImmichAPI.view.path("/folder/unique-paths"))
    }

    func searchStatistics(dto: SearchStatisticsDto) async throws -> SearchStatisticsResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.search.path("/statistics"), body: AnyEncodable(dto))
    }

    // MARK: - Map (AC-710)

    func getMapMarkers(filter: MapMarkerFilter) async throws -> [MapMarkerResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.map.path("/markers"), query: filter.queryItems())
    }

    // MARK: - Albums (AC-500..AC-518)

    func getAlbums() async throws -> [AlbumResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.albums.path(""))
    }

    func createAlbum(dto: CreateAlbumDto) async throws -> AlbumResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.albums.path(""), body: AnyEncodable(dto))
    }

    func getAlbum(id: String) async throws -> AlbumResponseDto {
        try await sendAuthed(.GET, path: ImmichAPI.albums.path("/\(id)"))
    }

    func updateAlbum(id: String, dto: UpdateAlbumDto) async throws -> AlbumResponseDto {
        try await sendAuthed(.PATCH, path: ImmichAPI.albums.path("/\(id)"), body: AnyEncodable(dto))
    }

    func deleteAlbum(id: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.albums.path("/\(id)"), body: nil)
    }

    func addAssetsToAlbum(albumId: String, dto: BulkIdsDto) async throws -> [BulkIdResponseDto] {
        try await sendAuthed(.PUT, path: ImmichAPI.albums.path("/\(albumId)/assets"), body: AnyEncodable(dto))
    }

    func removeAssetsFromAlbum(albumId: String, dto: BulkIdsDto) async throws -> [BulkIdResponseDto] {
        try await sendAuthed(.DELETE, path: ImmichAPI.albums.path("/\(albumId)/assets"), body: AnyEncodable(dto))
    }

    // MARK: - Album users (share to instance users)

    func addUsersToAlbum(albumId: String, dto: AddUsersDto) async throws -> AlbumResponseDto {
        try await sendAuthed(.PUT, path: ImmichAPI.albums.path("/\(albumId)/users"), body: AnyEncodable(dto))
    }

    func updateAlbumUserRole(albumId: String, userId: String, dto: UpdateAlbumUserDto) async throws {
        _ = try await sendAuthedRaw(.PUT, path: ImmichAPI.albums.path("/\(albumId)/user/\(userId)"), body: AnyEncodable(dto))
    }

    func removeUserFromAlbum(albumId: String, userId: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.albums.path("/\(albumId)/user/\(userId)"), body: nil)
    }

    // MARK: - Shared Links (AC-500..AC-518)

    func getSharedLinks(albumId: String?) async throws -> [SharedLinkResponseDto] {
        var query: [URLQueryItem] = []
        if let albumId {
            query.append(URLQueryItem(name: "albumId", value: albumId))
        }
        return try await sendAuthed(.GET, path: ImmichAPI.sharedLinks.path(""), query: query)
    }

    func createSharedLink(dto: SharedLinkCreateDto) async throws -> SharedLinkResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.sharedLinks.path(""), body: AnyEncodable(dto))
    }

    func deleteSharedLink(id: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.sharedLinks.path("/\(id)"), body: nil)
    }

    /// `PATCH /api/shared-links/{id}` — the server exposes PATCH for edits (the
    /// PUT this client used to send answered 404 at runtime).
    func updateSharedLink(id: String, dto: SharedLinkEditDto) async throws -> SharedLinkResponseDto {
        try await sendAuthed(.PATCH, path: ImmichAPI.sharedLinks.path("/\(id)"), body: AnyEncodable(dto))
    }

    /// `PUT /api/shared-links/{id}/assets` — owner-side add of assets to an
    /// INDIVIDUAL link; the response reports per-asset success.
    @discardableResult
    func addAssetsToSharedLink(id: String, assetIds: [String]) async throws -> [AssetIdsResponseDto] {
        try await sendAuthed(
            .PUT,
            path: ImmichAPI.sharedLinks.path("/\(id)/assets"),
            body: AnyEncodable(AssetIdsDto(assetIds: assetIds))
        )
    }

    // MARK: - Opening a shared link (issue #22 — visitor side)

    func getSharedLinkMine(_ credential: SharedLinkCredential) async throws -> SharedLinkResponseDto {
        let response = try await sendSharedLinkRaw(
            .GET,
            path: ImmichAPI.sharedLinks.path("/me"),
            credential: credential
        )
        return try Self.decode(SharedLinkResponseDto.self, from: response.data)
    }

    func loginToSharedLink(_ credential: SharedLinkCredential, password: String) async throws -> SharedLinkResponseDto {
        let response = try await sendSharedLinkRaw(
            .POST,
            path: ImmichAPI.sharedLinks.path("/login"),
            credential: credential,
            body: AnyEncodable(SharedLinkLoginDto(password: password)),
            capturesCookie: true
        )
        return try Self.decode(SharedLinkResponseDto.self, from: response.data)
    }

    func getSharedLinkAlbumAssets(
        _ credential: SharedLinkCredential,
        albumId: String,
        page: Int,
        size: Int
    ) async throws -> SearchResponseDto {
        let dto = MetadataSearchDto(albumIds: [albumId], page: page, size: size)
        let response = try await sendSharedLinkRaw(
            .POST,
            path: ImmichAPI.search.path("/metadata"),
            credential: credential,
            body: AnyEncodable(dto)
        )
        return try Self.decode(SearchResponseDto.self, from: response.data)
    }

    func uploadAssetToSharedLink(
        fileURL: URL,
        filename: String,
        fileCreatedAt: String,
        fileModifiedAt: String,
        checksum: String,
        deviceAssetId: String,
        deviceId: String,
        credential: SharedLinkCredential
    ) async throws -> AssetMediaResponseDto {
        // Same field set the server requires of the owner upload
        // (`AssetMediaCreateDto`: fileCreatedAt / fileModifiedAt / deviceAssetId
        // / deviceId); the visitor has no say over favorite, visibility or a
        // Live Photo pair, so those are left out.
        let multipart = try makeUploadBody(
            fieldName: "assetData",
            contentType: "application/octet-stream",
            fileURL: fileURL,
            filename: filename,
            fields: [
                ("fileCreatedAt", fileCreatedAt),
                ("fileModifiedAt", fileModifiedAt),
                ("deviceAssetId", deviceAssetId),
                ("deviceId", deviceId)
            ]
        )
        defer { try? FileManager.default.removeItem(at: multipart.file) }

        var request = try sharedLinkURLRequest(.POST, path: ImmichAPI.assets.path(""), credential: credential)
        request.setValue(multipart.contentType, forHTTPHeaderField: ImmichHeader.contentType)
        request.setValue(checksum, forHTTPHeaderField: ImmichHeader.checksum)

        let (data, response) = try await dispatchUpload(request, fromFile: multipart.file)
        try Self.validateSharedLinkResponse(response: response, data: data)
        return try Self.decode(AssetMediaResponseDto.self, from: data)
    }

    // MARK: - Tags (gap #2)

    func getAllTags() async throws -> [TagResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.tags.path(""))
    }

    func createTag(name: String, color: String?) async throws -> TagResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.tags.path(""), body: AnyEncodable(TagCreateDto(name: name, color: color)))
    }

    func updateTag(id: String, color: String?) async throws -> TagResponseDto {
        try await sendAuthed(.PUT, path: ImmichAPI.tags.path("/\(id)"), body: AnyEncodable(TagUpdateDto(color: color)))
    }

    func deleteTag(id: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.tags.path("/\(id)"), body: nil)
    }

    func tagAssets(tagId: String, assetIds: [String]) async throws {
        _ = try await sendAuthedRaw(.PUT, path: ImmichAPI.tags.path("/\(tagId)/assets"), body: AnyEncodable(BulkIdsDto(ids: assetIds)))
    }

    func untagAssets(tagId: String, assetIds: [String]) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.tags.path("/\(tagId)/assets"), body: AnyEncodable(BulkIdsDto(ids: assetIds)))
    }

    // MARK: - People (P0 api-surface-expansion)

    func getPeople(page: Int?, withHidden: Bool?) async throws -> PeopleResponseDto {
        var query: [URLQueryItem] = []
        if let page { query.append(URLQueryItem(name: "page", value: String(page))) }
        if let withHidden { query.append(URLQueryItem(name: "withHidden", value: String(withHidden))) }
        return try await sendAuthed(.GET, path: ImmichAPI.people.path(""), query: query)
    }

    func updatePerson(id: String, dto: PersonUpdateDto) async throws -> PersonResponseDto {
        try await sendAuthed(.PUT, path: ImmichAPI.people.path("/\(id)"), body: AnyEncodable(dto))
    }

    /// Same route as `updatePerson` — only the body differs, so no other field
    /// of the person can be touched by a birthday clear.
    func clearPersonBirthday(id: String) async throws -> PersonResponseDto {
        try await sendAuthed(.PUT, path: ImmichAPI.people.path("/\(id)"), body: AnyEncodable(PersonBirthdayClearDto()))
    }

    func createPerson(name: String) async throws -> PersonResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.people.path(""), body: AnyEncodable(PersonCreateDto(name: name)))
    }

    /// `POST /api/people/{id}/merge` — note: merge is POST, not PUT.
    func mergePeople(ids: [String], into id: String) async throws -> [BulkIdResponseDto] {
        try await sendAuthed(.POST, path: ImmichAPI.people.path("/\(id)/merge"), body: AnyEncodable(MergePersonDto(ids: ids)))
    }

    func getPersonStatistics(id: String) async throws -> PersonStatisticsResponseDto {
        try await sendAuthed(.GET, path: ImmichAPI.people.path("/\(id)/statistics"))
    }

    func reassignFace(faceId: String, toPersonId: String) async throws -> PersonResponseDto {
        try await sendAuthed(.PUT, path: ImmichAPI.faces.path("/\(toPersonId)"), body: AnyEncodable(FaceDto(id: faceId)))
    }

    func getFaces(assetId: String) async throws -> [AssetFaceResponseDto] {
        let query = [URLQueryItem(name: "id", value: assetId)]
        return try await sendAuthed(.GET, path: ImmichAPI.faces.path(""), query: query)
    }

    /// `GET /api/assets/{id}/ocr` — path param only, like `getAsset`.
    func getAssetOcr(id: String) async throws -> [AssetOcrResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.assets.path("/\(id)/ocr"))
    }

    // MARK: - Partners (P0 api-surface-expansion; direction corrected 2026-09-13)

    func getPartners(direction: PartnerDirection) async throws -> [PartnerResponseDto] {
        // `direction` is required — an empty query is a 400, not "all partners".
        let query = [URLQueryItem(name: "direction", value: direction.rawValue)]
        return try await sendAuthed(.GET, path: ImmichAPI.partners.path(""), query: query)
    }

    func createPartner(sharedWithId: String) async throws -> PartnerResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.partners.path(""), body: AnyEncodable(PartnerCreateDto(sharedWithId: sharedWithId)))
    }

    func updatePartner(id: String, isInTimeline: Bool) async throws -> PartnerResponseDto {
        try await sendAuthed(.PUT, path: ImmichAPI.partners.path("/\(id)"), body: AnyEncodable(PartnerUpdateDto(inTimeline: isInTimeline)))
    }

    func removePartner(id: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.partners.path("/\(id)"), body: nil)
    }

    // MARK: - Activity (P0 api-surface-expansion)

    func getActivities(albumId: String, assetId: String?) async throws -> [ActivityResponseDto] {
        var query: [URLQueryItem] = [URLQueryItem(name: "albumId", value: albumId)]
        if let assetId { query.append(URLQueryItem(name: "assetId", value: assetId)) }
        return try await sendAuthed(.GET, path: ImmichAPI.activity.path(""), query: query)
    }

    func createActivity(dto: ActivityCreateDto) async throws -> ActivityResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.activity.path(""), body: AnyEncodable(dto))
    }

    func deleteActivity(id: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.activity.path("/\(id)"), body: nil)
    }

    // MARK: - Memories (P0 api-surface-expansion; CRUD added 2026-09-13)

    func getMemories() async throws -> [MemoryResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.memories.path(""))
    }

    func getMemory(id: String) async throws -> MemoryResponseDto {
        try await sendAuthed(.GET, path: ImmichAPI.memories.path("/\(id)"))
    }

    /// `PUT` — the route is `get|put|delete` in the published OpenAPI; a PATCH
    /// is not exposed and would 404.
    func updateMemory(id: String, dto: MemoryUpdateDto) async throws -> MemoryResponseDto {
        try await sendAuthed(.PUT, path: ImmichAPI.memories.path("/\(id)"), body: AnyEncodable(dto))
    }

    func deleteMemory(id: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.memories.path("/\(id)"), body: nil)
    }

    func createMemory(dto: MemoryCreateDto) async throws -> MemoryResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.memories.path(""), body: AnyEncodable(dto))
    }

    @discardableResult
    func addAssetsToMemory(id: String, assetIds: [String]) async throws -> [BulkIdResponseDto] {
        try await sendAuthed(
            .PUT,
            path: ImmichAPI.memories.path("/\(id)/assets"),
            body: AnyEncodable(BulkIdsDto(ids: assetIds))
        )
    }

    @discardableResult
    func removeAssetsFromMemory(id: String, assetIds: [String]) async throws -> [BulkIdResponseDto] {
        try await sendAuthed(
            .DELETE,
            path: ImmichAPI.memories.path("/\(id)/assets"),
            body: AnyEncodable(BulkIdsDto(ids: assetIds))
        )
    }

    func getMemoriesStatistics() async throws -> MemoryStatisticsResponseDto {
        try await sendAuthed(.GET, path: ImmichAPI.memories.path("/statistics"))
    }

    // MARK: - Duplicates (P0 api-surface-expansion)

    func getDuplicates() async throws -> [DuplicateResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.duplicates.path(""))
    }

    // MARK: - Stacks (gap #1)

    func searchStacks(primaryAssetId: String?) async throws -> [StackResponseDto] {
        var query: [URLQueryItem] = []
        if let primaryAssetId { query.append(URLQueryItem(name: "primaryAssetId", value: primaryAssetId)) }
        return try await sendAuthed(.GET, path: ImmichAPI.stacks.path(""), query: query)
    }

    func createStack(assetIds: [String]) async throws -> StackResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.stacks.path(""), body: AnyEncodable(StackCreateDto(assetIds: assetIds)))
    }

    func getStack(id: String) async throws -> StackResponseDto {
        try await sendAuthed(.GET, path: ImmichAPI.stacks.path("/\(id)"))
    }

    func updateStack(id: String, primaryAssetId: String?) async throws -> StackResponseDto {
        try await sendAuthed(.PUT, path: ImmichAPI.stacks.path("/\(id)"), body: AnyEncodable(StackUpdateDto(primaryAssetId: primaryAssetId)))
    }

    func deleteStack(id: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.stacks.path("/\(id)"), body: nil)
    }

    func removeAssetFromStack(stackId: String, assetId: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.stacks.path("/\(stackId)/assets/\(assetId)"), body: nil)
    }

    // MARK: - Admin (gap #12)

    func getAdminUsers() async throws -> [UserAdminResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.admin.path("/users"))
    }

    func createAdminUser(dto: UserAdminCreateDto) async throws -> UserAdminResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.admin.path("/users"), body: AnyEncodable(dto))
    }

    func updateAdminUser(id: String, dto: UserAdminUpdateDto) async throws -> UserAdminResponseDto {
        try await sendAuthed(.PUT, path: ImmichAPI.admin.path("/users/\(id)"), body: AnyEncodable(dto))
    }

    func deleteAdminUser(id: String, force: Bool) async throws -> UserAdminResponseDto {
        let query = [URLQueryItem(name: "force", value: String(force))]
        return try await sendAuthed(.DELETE, path: ImmichAPI.admin.path("/users/\(id)"), query: query)
    }

    func restoreAdminUser(id: String) async throws -> UserAdminResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.admin.path("/users/\(id)/restore"), body: nil)
    }

    func getJobsStatus() async throws -> [String: QueueResponseLegacyDto] {
        try await sendAuthed(.GET, path: ImmichAPI.jobs.path(""))
    }

    func sendJobCommand(name: String, command: String, force: Bool?) async throws -> QueueResponseLegacyDto {
        try await sendAuthed(.PUT, path: ImmichAPI.jobs.path("/\(name)"), body: AnyEncodable(QueueCommandDto(command: command, force: force)))
    }

    func getLibraries() async throws -> [LibraryResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.libraries.path(""))
    }

    func scanLibrary(id: String) async throws {
        _ = try await sendAuthedRaw(.POST, path: ImmichAPI.libraries.path("/\(id)/scan"), body: nil)
    }

    func deleteLibrary(id: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.libraries.path("/\(id)"), body: nil)
    }

    func getAPIKeys() async throws -> [ApiKeyResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.apiKeys.path(""))
    }

    func getMyAPIKey() async throws -> ApiKeyResponseDto {
        try await sendAuthed(.GET, path: ImmichAPI.apiKeys.path("/me"))
    }

    func createAPIKey(name: String, permissions: [String]) async throws -> ApiKeyCreateResponseDto {
        // One value at a time: a dictionary literal mixing a `String` with an
        // array is not `Encodable` — only `[String: Any]` would type-check, and
        // `Any` does not conform — so each side is erased before the body.
        let body: [String: AnyEncodable] = ["name": AnyEncodable(name), "permissions": AnyEncodable(permissions)]
        return try await sendAuthed(.POST, path: ImmichAPI.apiKeys.path(""), body: AnyEncodable(body))
    }

    func rotateAPIKey(id: String) async throws -> ApiKeyCreateResponseDto {
        try await sendAuthed(.POST, path: ImmichAPI.apiKeys.path("/\(id)/rotate"))
    }

    func deleteAPIKey(id: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.apiKeys.path("/\(id)"), body: nil)
    }

    // MARK: - Sessions (gap G19)

    func getSessions() async throws -> [SessionResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.sessions.path(""))
    }

    /// 204 only: there is no body to decode and nothing to return.
    func deleteSession(id: String) async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.sessions.path("/\(id)"), body: nil)
    }

    /// 204 as well — the server drops every session but the calling one, so
    /// there is no count to read back.
    func deleteAllSessions() async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.sessions.path(""), body: nil)
    }

    // MARK: - Server statistics (P0 api-surface-expansion)

    func getServerStatistics() async throws -> ServerStatsResponseDto {
        try await sendAuthed(.GET, path: ImmichAPI.server.path("/statistics"))
    }

    // MARK: - Bulk asset update (P0: archive via visibility)

    func bulkUpdateAssets(dto: AssetBulkUpdateDto) async throws {
        _ = try await sendAuthedRaw(.PUT, path: ImmichAPI.assets.path(""), body: AnyEncodable(dto))
    }

    // MARK: - Users (photo share — shared-album user picker)

    /// `GET /api/users` — instance users. On Immich builds where this is
    /// admin-gated, the caller surfaces a friendly empty/error state.
    func getUsers() async throws -> [UserResponseDto] {
        try await sendAuthed(.GET, path: ImmichAPI.users.path(""))
    }

    // MARK: - Profile picture (gap G16)

    /// `GET /api/users/me` — the signed-in user's own row, re-read from the
    /// server so `profileImagePath`/`profileChangedAt` are never a stale copy.
    func getMyUser() async throws -> UserAdminResponseDto {
        try await sendAuthed(.GET, path: ImmichAPI.users.path("/me"))
    }

    /// `GET /api/users/me` read as the auth seam — the same route `getMyUser()`
    /// serves the profile screen, kept as its own method so `AuthViewModel`
    /// re-reads the server's `shouldChangePassword` flag without borrowing the
    /// profile screen's call.
    func currentUser() async throws -> UserAdminResponseDto {
        try await getMyUser()
    }

    /// `POST /api/users/profile-image` (`CreateProfileImageDto`: one binary
    /// `file` field). Same streamed multipart body as an asset upload — the
    /// field name and content type are passed in — and deliberately **no**
    /// `x-immich-checksum`: that header drives the asset dedup table and means
    /// nothing on this route.
    func uploadProfileImage(
        fileURL: URL,
        filename: String,
        contentType: String
    ) async throws -> CreateProfileImageResponseDto {
        let multipart = try makeUploadBody(
            fieldName: "file",
            contentType: contentType,
            fileURL: fileURL,
            filename: filename,
            fields: []
        )
        defer { try? FileManager.default.removeItem(at: multipart.file) }

        var request = try baseRequest(HTTPMethod.POST, path: ImmichAPI.users.path("/profile-image"), query: [], auth: false)
        request.setValue(multipart.contentType, forHTTPHeaderField: ImmichHeader.contentType)
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: ImmichHeader.authorization)
        }

        let (responseData, response) = try await dispatchUpload(request, fromFile: multipart.file)
        try validate(response: response, data: responseData)
        return try Self.decode(CreateProfileImageResponseDto.self, from: responseData)
    }

    /// `DELETE /api/users/profile-image` — `204` with no body (same shape as
    /// `deleteAPIKey`). No `{id}` parameter exists: only your own photo.
    func deleteProfileImage() async throws {
        _ = try await sendAuthedRaw(.DELETE, path: ImmichAPI.users.path("/profile-image"), body: nil)
    }

    // MARK: - Upload

    /// Assembles a multipart/form-data body on disk (file bytes streamed from
    /// the file, never held in memory) and returns the temp file plus the
    /// `Content-Type` boundary that goes with it — shared by the owner upload,
    /// the guest upload from a shared link and the profile-picture upload. The
    /// field name and content type belong to the caller: an asset goes under
    /// `assetData`/`application/octet-stream`, a profile picture under
    /// `file`/`image/jpeg` (`CreateProfileImageDto`). The caller removes the file.
    private func makeUploadBody(
        fieldName: String,
        contentType: String,
        fileURL: URL,
        filename: String,
        fields: [(name: String, value: String)]
    ) throws -> (file: URL, contentType: String) {
        var multipart = MultipartBody()
        let bodyURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immich-upload-\(UUID().uuidString).multipart")
        try multipart.writeStreamed(
            fileField: (fieldName, filename, contentType, fileURL),
            fields: fields,
            to: bodyURL
        )
        return (bodyURL, multipart.contentType)
    }

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
    ) async throws -> AssetMediaResponseDto {
        var fields: [(name: String, value: String)] = [
            ("fileCreatedAt", fileCreatedAt),
            ("fileModifiedAt", fileModifiedAt),
            ("deviceAssetId", deviceAssetId),
            ("deviceId", deviceId),
        ]
        if let duration {
            fields.append(("duration", String(duration)))
        }
        fields.append(("isFavorite", isFavorite ? "true" : "false"))
        fields.append(("visibility", visibility.rawValue))
        if let livePhotoVideoId {
            fields.append(("livePhotoVideoId", livePhotoVideoId))
        }

        let multipart = try makeUploadBody(
            fieldName: "assetData",
            contentType: "application/octet-stream",
            fileURL: fileURL,
            filename: filename,
            fields: fields
        )
        defer { try? FileManager.default.removeItem(at: multipart.file) }

        var request = try baseRequest(HTTPMethod.POST, path: ImmichAPI.assets.path(""), query: [], auth: false)
        request.setValue(multipart.contentType, forHTTPHeaderField: ImmichHeader.contentType)
        request.setValue(checksum, forHTTPHeaderField: ImmichHeader.checksum)
        if let token = token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: ImmichHeader.authorization)
        }

        let (responseData, response) = try await dispatchUpload(request, fromFile: multipart.file)
        try validate(response: response, data: responseData)
        return try Self.decode(AssetMediaResponseDto.self, from: responseData)
    }

    func bulkUploadCheck(_ request: AssetBulkUploadCheckRequest) async throws -> AssetBulkUploadCheckResponse {
        try await sendAuthed(.POST, path: ImmichAPI.assets.path("/bulk-upload-check"), body: AnyEncodable(request))
    }

    // MARK: - Download queue (gap G10)

    func downloadInfo(assetIds: [String], albumId: String?) async throws -> DownloadInfoResponse {
        let dto: DownloadResponseDto = try await sendAuthed(
            .POST,
            path: apiRooted("download/info"),
            body: AnyEncodable(DownloadInfoBody(assetIds: assetIds, albumId: albumId))
        )
        return DownloadInfoResponse(
            totalSize: dto.totalSize,
            archives: dto.archives.map { DownloadInfoResponse.Archive(assetIds: $0.assetIds, size: $0.size) }
        )
    }

    func originalRequest(assetId: String) throws -> URLRequest {
        try authenticatedRequest(.GET, path: ImmichAPI.assets.path("/\(assetId)/original"))
    }

    func downloadArchiveRequest(archiveName: String, assetIds: [String], edited: Bool) throws -> URLRequest {
        struct Body: Encodable {
            let archiveName: String
            let assetIds: [String]
            let edited: Bool
        }
        var request = try authenticatedRequest(.POST, path: apiRooted("download/archive"))
        request.setValue("application/json", forHTTPHeaderField: ImmichHeader.contentType)
        request.httpBody = try JSONEncoder.immich.encode(
            Body(archiveName: archiveName, assetIds: assetIds, edited: edited)
        )
        return request
    }

    /// `DownloadResponseDto` — the chunks the server decided to make.
    private struct DownloadResponseDto: Decodable {
        struct Archive: Decodable {
            let assetIds: [String]
            let size: Int64
        }

        let archives: [Archive]
        let totalSize: Int64
    }

    /// `DownloadInfoDto`. `albumId` is omitted rather than sent as `null`: the
    /// server reads an absent field as "no album".
    private struct DownloadInfoBody: Encodable {
        let assetIds: [String]
        let albumId: String?

        enum CodingKeys: String, CodingKey {
            case assetIds
            case albumId
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(assetIds, forKey: .assetIds)
            try container.encodeIfPresent(albumId, forKey: .albumId)
        }
    }

    /// Method + URL + Bearer for the download routes, which the transport
    /// fetches: the client stops at the request. A missing token throws rather
    /// than returning a request that would answer 401 — whose error body the
    /// transport would otherwise stream to disk as a file.
    private func authenticatedRequest(_ method: HTTPMethod, path: String) throws -> URLRequest {
        guard let token else { throw APIError.unauthorized }
        return try baseRequest(method, path: path, query: [], auth: true, token: token)
    }

    /// Roots a suffix the server publishes directly under the API root rather
    /// than under a `SubPath` group (`/api/download/{info,archive}`).
    private func apiRooted(_ suffix: String) -> String {
        ImmichAPI.apiPath + "/" + suffix
    }

    // MARK: - Core dispatch

    private func sendNoAuth<T: Decodable>(_ method: HTTPMethod, path: String, query: [URLQueryItem] = [], body: AnyEncodable? = nil) async throws -> T {
        let data = try await sendRaw(method, path: path, query: query, auth: false, body: body)
        return try Self.decode(T.self, from: data)
    }

    private func sendAuthed<T: Decodable>(_ method: HTTPMethod, path: String, query: [URLQueryItem] = [], body: AnyEncodable? = nil) async throws -> T {
        let data = try await sendAuthedRaw(method, path: path, query: query, body: body)
        return try Self.decode(T.self, from: data)
    }

    private func sendAuthedRaw(_ method: HTTPMethod, path: String, query: [URLQueryItem] = [], body: AnyEncodable?) async throws -> Data {
        guard let token = token else { throw APIError.unauthorized }
        return try await sendRaw(method, path: path, query: query, auth: true, token: token, body: body)
    }

    private func sendRaw(_ method: HTTPMethod, path: String, query: [URLQueryItem] = [], auth: Bool, token: String? = nil, body: AnyEncodable?) async throws -> Data {
        var request = try baseRequest(method, path: path, query: query, auth: auth, token: token)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: ImmichHeader.contentType)
            request.httpBody = try JSONEncoder.immich.encode(body)
        }
        let (responseData, response) = try await dispatch(request)
        try validate(response: response, data: responseData)
        return responseData
    }

    // MARK: - Shared-link transport (issue #22)

    /// Sends a visitor request: **no bearer**, the credential in the query, and
    /// the cookie a previous login established.
    ///
    /// Deliberately separate from `sendNoAuth` (the pre-login path: ping /
    /// version / config / login) and from `sendAuthedRaw` (which hard-requires
    /// a token and would sign the user out here): a 401 on this path says
    /// something about the *link* — a password is required, the password is
    /// wrong, the link is revoked or expired — and must never reach
    /// `authDelegate`, which resets the whole app session (FM-4). Failures
    /// therefore surface as `.serverError(status, message)` so the caller can
    /// read the server's own wording (`"Password required"` is the discriminator
    /// the web client keys off too).
    @discardableResult
    private func sendSharedLinkRaw(
        _ method: HTTPMethod,
        path: String,
        credential: SharedLinkCredential,
        query: [URLQueryItem] = [],
        body: AnyEncodable? = nil,
        capturesCookie: Bool = false
    ) async throws -> (data: Data, response: HTTPURLResponse?) {
        let request = try sharedLinkURLRequest(method, path: path, credential: credential, query: query, body: body)
        let (data, response) = try await dispatch(request)
        try Self.validateSharedLinkResponse(response: response, data: data)
        if capturesCookie, let http = response as? HTTPURLResponse {
            storeSharedLinkCookie(from: http)
        }
        return (data, response as? HTTPURLResponse)
    }

    /// Builds the request for a public shared link: credential in the query, no
    /// `Authorization`, and the login cookie replayed explicitly (rather than
    /// relying on `URLSession`'s cookie store, whose accept policy is not ours
    /// to set on the shared session).
    private func sharedLinkURLRequest(
        _ method: HTTPMethod,
        path: String,
        credential: SharedLinkCredential,
        query: [URLQueryItem] = [],
        body: AnyEncodable? = nil
    ) throws -> URLRequest {
        var request = try baseRequest(
            method,
            path: path,
            query: query + [credential.queryItem],
            auth: false
        )
        if let body {
            request.setValue("application/json", forHTTPHeaderField: ImmichHeader.contentType)
            request.httpBody = try JSONEncoder.immich.encode(body)
        }
        if let cookie = sharedLinkCookie {
            request.setValue(cookie, forHTTPHeaderField: ImmichHeader.cookie)
        }
        return request
    }

    private var sharedLinkCookie: String? {
        lock.lock(); defer { lock.unlock() }; return _sharedLinkCookie
    }

    /// Keeps the `immich_shared_link_token` cookie out of the `Set-Cookie`
    /// header. The server accumulates tokens (`SharedLinkController.merge`) and
    /// answers with one comma-joined cookie, so the whole `name=value` pair is
    /// kept as-is and replayed verbatim.
    private func storeSharedLinkCookie(from response: HTTPURLResponse) {
        let header = response.value(forHTTPHeaderField: "Set-Cookie") ?? ""
        guard let pair = header.split(separator: ";").first, pair.contains("=") else { return }
        let trimmed = pair.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(ImmichCookie.sharedLinkToken)=") else { return }
        lock.lock(); _sharedLinkCookie = trimmed; lock.unlock()
    }

    /// Status handling for the visitor path — see `sendSharedLinkRaw`.
    private static func validateSharedLinkResponse(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.serverError(http.statusCode, String(data: data, encoding: .utf8))
        }
    }

    /// Method + URL + `Accept` (+ `Bearer` when `auth`), with no body: the JSON
    /// callers and the multipart upload both start from here.
    private func baseRequest(_ method: HTTPMethod, path: String, query: [URLQueryItem], auth: Bool, token: String? = nil) throws -> URLRequest {
        guard let url = resolvedURL(path: path, query: query) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue(ImmichAPI.acceptJSON, forHTTPHeaderField: ImmichHeader.accept)
        if auth, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: ImmichHeader.authorization)
        }
        return request
    }

    private func dispatch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let start = Date()
        bumpRequestCount()
        do {
            let result = try await session.data(for: request)
            log.record(entry(for: request, category: "HTTP", status: (result.1 as? HTTPURLResponse)?.statusCode, since: start))
            return result
        } catch let urlError as URLError {
            log.record(entry(for: request, category: "HTTP", since: start, error: urlError))
            throw APIError.network(urlError)
        } catch {
            log.record(entry(for: request, category: "HTTP", since: start, error: error))
            throw APIError.from(error)
        }
    }

    /// Like `dispatch`, but streams the request body from a file on disk
    /// (`URLSession.upload(fromFile:)`) so large asset uploads never load the
    /// body into memory.
    private func dispatchUpload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        let start = Date()
        bumpRequestCount()
        do {
            let result = try await session.upload(for: request, fromFile: fileURL)
            log.record(entry(for: request, category: "Upload", status: (result.1 as? HTTPURLResponse)?.statusCode, since: start))
            return result
        } catch let urlError as URLError {
            log.record(entry(for: request, category: "Upload", since: start, error: urlError))
            throw APIError.network(urlError)
        } catch {
            log.record(entry(for: request, category: "Upload", since: start, error: error))
            throw APIError.from(error)
        }
    }

    /// Builds the one line a dispatch leaves behind.
    ///
    /// Only what the operator needs: the method, the **path**, the status and
    /// how long it took. The level follows the outcome — `info` below 400,
    /// `warning` for a 4xx (a 401 included: the entry records that the server
    /// refused, and `authDelegate` remains the only thing that decides what a
    /// refusal means), `severe` for a 5xx or for anything thrown.
    private func entry(for request: URLRequest, category: String, status: Int? = nil, since start: Date, error: Error? = nil) -> AppLogEntry {
        let method = request.httpMethod ?? "GET"
        let level: AppLogLevel
        if error != nil || (status ?? 0) >= 500 {
            level = .severe
        } else if (status ?? 0) >= 400 {
            level = .warning
        } else {
            level = .info
        }
        let outcome = error?.localizedDescription ?? status.map(String.init) ?? "no response"
        return AppLogEntry(
            level: level,
            method: method,
            path: request.url?.path ?? "",
            status: status,
            durationMS: Int(Date().timeIntervalSince(start) * 1000),
            category: category,
            message: "\(method) \(request.url?.path ?? "") → \(outcome)",
            details: error?.localizedDescription,
            // Only a thrown failure pays for symbols; a status code is a fact,
            // not an incident.
            stack: error == nil ? nil : Thread.callStackSymbols.joined(separator: "\n")
        )
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 {
            authDelegate?.didReceiveUnauthorized()
            throw APIError.unauthorized
        }
        if http.statusCode == 204 { return }
        if !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8)
            throw APIError.serverError(http.statusCode, message)
        }
    }

    private func resolvedURL(path: String, query: [URLQueryItem] = []) -> URL? {
        guard let base = baseURL else { return nil }
        let url = base.appendingPathComponent(path)
        guard !query.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = query
        return components?.url
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder.immich.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

enum HTTPMethod: String {
    case GET, POST, PUT, PATCH, DELETE
}
