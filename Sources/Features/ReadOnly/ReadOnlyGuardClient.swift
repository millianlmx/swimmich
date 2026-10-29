import Foundation

/// The one write gate of the app (gap G17).
///
/// Every view model and every view of the library receives this decorator — not
/// the transport — from `DependencyContainer`, so **one** check, here, covers
/// every write path: the view models, the eight call sites that drive the
/// client from a view (`PhotoViewer`, `StackSheet`), the `swipeActions` and the
/// `contextMenu` closures. With read-only mode on, a write throws
/// `APIError.readOnlyMode` instead of reaching the server; reads go straight
/// through and pay nothing.
///
/// **Any write added to `ImmichClient` MUST be classified here.** The compiler
/// forces this file to be revisited (a protocol requirement that is not
/// implemented does not compile) — it cannot force the classification itself,
/// so a new mutating method lands on the read side silently unless the author
/// looks. That is the only review this file needs.
///
/// Classification rule: **library writes are refused; account and session
/// mechanics are not.** Delete / restore / empty, upload, album and stack
/// membership, tags, memories, activities, partners, people, admin mutations
/// and asset edits all answer to the mode. Signing in or out, configuring the
/// transport, the locked folder's PIN and a user's own profile picture are
/// account plumbing: the mode guards the library, not the account, and a
/// read-only session must still be able to lock or unlock itself.
///
/// Reference type because `ImmichClient` is class-bound (`AnyObject`), like
/// every other protocol in `Core/Protocols`: the decorator is a drop-in for the
/// client, identity comparisons included.
final class ReadOnlyGuardClient: ImmichClient {
    let inner: any ImmichClient

    /// Read at call time, never captured: the mode is flipped at runtime and
    /// the very next write must see the flip.
    let isEnabled: @Sendable () -> Bool

    init(inner: any ImmichClient, isEnabled: @escaping @Sendable () -> Bool) {
        self.inner = inner
        self.isEnabled = isEnabled
    }

    private func assertWritable() throws {
        if isEnabled() { throw APIError.readOnlyMode }
    }

    // MARK: - Transport / session (never refused)

    func configure(baseURL: URL?, token: String?) {
        inner.configure(baseURL: baseURL, token: token)
    }

    var authDelegate: (any AuthSessionDelegate)? {
        get { inner.authDelegate }
        set { inner.authDelegate = newValue }
    }

    func ping() async throws -> ServerPingResponse {
        try await inner.ping()
    }

    func serverVersion() async throws -> ServerVersionResponseDto {
        try await inner.serverVersion()
    }

    func serverConfig() async throws -> ServerConfigDto {
        try await inner.serverConfig()
    }

    /// Account mechanics, not library writes: the mode guards the library, so a
    /// read-only session can still change its own password (the server's own
    /// `shouldChangePassword` request must remain answerable) and read who it is.
    func changePassword(currentPassword: String, newPassword: String, invalidateSessions: Bool) async throws -> UserAdminResponseDto {
        try await inner.changePassword(
            currentPassword: currentPassword,
            newPassword: newPassword,
            invalidateSessions: invalidateSessions
        )
    }

    func currentUser() async throws -> UserAdminResponseDto {
        try await inner.currentUser()
    }

    // MARK: - Sessions (account mechanics: never refused)

    func getSessions() async throws -> [SessionResponseDto] {
        try await inner.getSessions()
    }

    func deleteSession(id: String) async throws {
        try await inner.deleteSession(id: id)
    }

    func deleteAllSessions() async throws {
        try await inner.deleteAllSessions()
    }

    func login(email: String, password: String) async throws -> LoginResponseDto {
        try await inner.login(email: email, password: password)
    }

    func logout() async throws -> LogoutResponseDto {
        try await inner.logout()
    }

    func validateToken() async throws -> ValidateAccessTokenResponseDto {
        try await inner.validateToken()
    }

    func authorizeOAuth(redirectURI: String, state: String, codeChallenge: String) async throws -> OAuthAuthorizeResponseDto {
        try await inner.authorizeOAuth(redirectURI: redirectURI, state: state, codeChallenge: codeChallenge)
    }

    func exchangeOAuthCode(url: String, state: String, codeVerifier: String) async throws -> LoginResponseDto {
        try await inner.exchangeOAuthCode(url: url, state: state, codeVerifier: codeVerifier)
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
        try await inner.getTimeBuckets(
            isFavorite: isFavorite,
            isTrashed: isTrashed,
            personId: personId,
            withPartners: withPartners,
            visibility: visibility,
            withStacked: withStacked,
            orderBy: orderBy
        )
    }

    func getTimeBucket(
        timeBucket: String,
        isFavorite: Bool?,
        isTrashed: Bool?,
        personId: String?,
        withPartners: Bool?,
        visibility: String?,
        withStacked: Bool?,
        orderBy: AssetOrderBy?
    ) async throws -> TimeBucketAssetResponseDto {
        try await inner.getTimeBucket(
            timeBucket: timeBucket,
            isFavorite: isFavorite,
            isTrashed: isTrashed,
            personId: personId,
            withPartners: withPartners,
            visibility: visibility,
            withStacked: withStacked,
            orderBy: orderBy
        )
    }

    func getAsset(id: String) async throws -> AssetResponseDto {
        try await inner.getAsset(id: id)
    }

    func updateAsset(id: String, dto: UpdateAssetDto) async throws -> AssetResponseDto {
        try assertWritable()
        return try await inner.updateAsset(id: id, dto: dto)
    }

    func setAssetRating(id: String, rating: Int?) async throws -> AssetResponseDto {
        try assertWritable()
        return try await inner.setAssetRating(id: id, rating: rating)
    }

    func deleteAssets(ids: [String], force: Bool?) async throws {
        try assertWritable()
        try await inner.deleteAssets(ids: ids, force: force)
    }

    // MARK: - Trash

    func restoreTrashAssets(ids: [String]) async throws -> TrashResponseDto {
        try assertWritable()
        return try await inner.restoreTrashAssets(ids: ids)
    }

    func restoreAllTrash() async throws -> TrashResponseDto {
        try assertWritable()
        return try await inner.restoreAllTrash()
    }

    func emptyTrash() async throws -> TrashResponseDto {
        try assertWritable()
        return try await inner.emptyTrash()
    }

    // MARK: - Search (reads)

    func searchMetadata(dto: MetadataSearchDto) async throws -> SearchResponseDto {
        try await inner.searchMetadata(dto: dto)
    }

    func searchSmart(dto: SmartSearchDto) async throws -> SearchResponseDto {
        try await inner.searchSmart(dto: dto)
    }

    func getExploreData() async throws -> [SearchExploreResponseDto] {
        try await inner.getExploreData()
    }

    func getAssetsByCity() async throws -> [AssetResponseDto] {
        try await inner.getAssetsByCity()
    }

    func getFolderAssets(path: String) async throws -> [AssetResponseDto] {
        try await inner.getFolderAssets(path: path)
    }

    func getUniqueFolderPaths() async throws -> [String] {
        try await inner.getUniqueFolderPaths()
    }

    func searchStatistics(dto: SearchStatisticsDto) async throws -> SearchStatisticsResponseDto {
        try await inner.searchStatistics(dto: dto)
    }

    func getMapMarkers(filter: MapMarkerFilter) async throws -> [MapMarkerResponseDto] {
        try await inner.getMapMarkers(filter: filter)
    }

    // MARK: - Albums

    func getAlbums() async throws -> [AlbumResponseDto] {
        try await inner.getAlbums()
    }

    func createAlbum(dto: CreateAlbumDto) async throws -> AlbumResponseDto {
        try assertWritable()
        return try await inner.createAlbum(dto: dto)
    }

    func getAlbum(id: String) async throws -> AlbumResponseDto {
        try await inner.getAlbum(id: id)
    }

    func updateAlbum(id: String, dto: UpdateAlbumDto) async throws -> AlbumResponseDto {
        try assertWritable()
        return try await inner.updateAlbum(id: id, dto: dto)
    }

    func deleteAlbum(id: String) async throws {
        try assertWritable()
        try await inner.deleteAlbum(id: id)
    }

    func addAssetsToAlbum(albumId: String, dto: BulkIdsDto) async throws -> [BulkIdResponseDto] {
        try assertWritable()
        return try await inner.addAssetsToAlbum(albumId: albumId, dto: dto)
    }

    func removeAssetsFromAlbum(albumId: String, dto: BulkIdsDto) async throws -> [BulkIdResponseDto] {
        try assertWritable()
        return try await inner.removeAssetsFromAlbum(albumId: albumId, dto: dto)
    }

    func addUsersToAlbum(albumId: String, dto: AddUsersDto) async throws -> AlbumResponseDto {
        try assertWritable()
        return try await inner.addUsersToAlbum(albumId: albumId, dto: dto)
    }

    func updateAlbumUserRole(albumId: String, userId: String, dto: UpdateAlbumUserDto) async throws {
        try assertWritable()
        try await inner.updateAlbumUserRole(albumId: albumId, userId: userId, dto: dto)
    }

    func removeUserFromAlbum(albumId: String, userId: String) async throws {
        try assertWritable()
        try await inner.removeUserFromAlbum(albumId: albumId, userId: userId)
    }

    // MARK: - Shared links

    func getSharedLinks(albumId: String?) async throws -> [SharedLinkResponseDto] {
        try await inner.getSharedLinks(albumId: albumId)
    }

    func createSharedLink(dto: SharedLinkCreateDto) async throws -> SharedLinkResponseDto {
        try assertWritable()
        return try await inner.createSharedLink(dto: dto)
    }

    func updateSharedLink(id: String, dto: SharedLinkEditDto) async throws -> SharedLinkResponseDto {
        try assertWritable()
        return try await inner.updateSharedLink(id: id, dto: dto)
    }

    @discardableResult
    func addAssetsToSharedLink(id: String, assetIds: [String]) async throws -> [AssetIdsResponseDto] {
        try assertWritable()
        return try await inner.addAssetsToSharedLink(id: id, assetIds: assetIds)
    }

    func deleteSharedLink(id: String) async throws {
        try assertWritable()
        try await inner.deleteSharedLink(id: id)
    }

    // MARK: - Opening a shared link (visitor side)

    func getSharedLinkMine(_ credential: SharedLinkCredential) async throws -> SharedLinkResponseDto {
        try await inner.getSharedLinkMine(credential)
    }

    func loginToSharedLink(_ credential: SharedLinkCredential, password: String) async throws -> SharedLinkResponseDto {
        try await inner.loginToSharedLink(credential, password: password)
    }

    func getSharedLinkAlbumAssets(
        _ credential: SharedLinkCredential,
        albumId: String,
        page: Int,
        size: Int
    ) async throws -> SearchResponseDto {
        try await inner.getSharedLinkAlbumAssets(credential, albumId: albumId, page: page, size: size)
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
        try assertWritable()
        return try await inner.uploadAssetToSharedLink(
            fileURL: fileURL,
            filename: filename,
            fileCreatedAt: fileCreatedAt,
            fileModifiedAt: fileModifiedAt,
            checksum: checksum,
            deviceAssetId: deviceAssetId,
            deviceId: deviceId,
            credential: credential
        )
    }

    // MARK: - Tags

    func getAllTags() async throws -> [TagResponseDto] {
        try await inner.getAllTags()
    }

    func createTag(name: String, color: String?) async throws -> TagResponseDto {
        try assertWritable()
        return try await inner.createTag(name: name, color: color)
    }

    func updateTag(id: String, color: String?) async throws -> TagResponseDto {
        try assertWritable()
        return try await inner.updateTag(id: id, color: color)
    }

    func deleteTag(id: String) async throws {
        try assertWritable()
        try await inner.deleteTag(id: id)
    }

    func tagAssets(tagId: String, assetIds: [String]) async throws {
        try assertWritable()
        try await inner.tagAssets(tagId: tagId, assetIds: assetIds)
    }

    func untagAssets(tagId: String, assetIds: [String]) async throws {
        try assertWritable()
        try await inner.untagAssets(tagId: tagId, assetIds: assetIds)
    }

    // MARK: - People

    func getPeople(page: Int?, withHidden: Bool?) async throws -> PeopleResponseDto {
        try await inner.getPeople(page: page, withHidden: withHidden)
    }

    func createPerson(name: String) async throws -> PersonResponseDto {
        try assertWritable()
        return try await inner.createPerson(name: name)
    }

    func updatePerson(id: String, dto: PersonUpdateDto) async throws -> PersonResponseDto {
        try assertWritable()
        return try await inner.updatePerson(id: id, dto: dto)
    }

    func clearPersonBirthday(id: String) async throws -> PersonResponseDto {
        try assertWritable()
        return try await inner.clearPersonBirthday(id: id)
    }

    func mergePeople(ids: [String], into id: String) async throws -> [BulkIdResponseDto] {
        try assertWritable()
        return try await inner.mergePeople(ids: ids, into: id)
    }

    func getPersonStatistics(id: String) async throws -> PersonStatisticsResponseDto {
        try await inner.getPersonStatistics(id: id)
    }

    func reassignFace(faceId: String, toPersonId: String) async throws -> PersonResponseDto {
        try assertWritable()
        return try await inner.reassignFace(faceId: faceId, toPersonId: toPersonId)
    }

    func getFaces(assetId: String) async throws -> [AssetFaceResponseDto] {
        try await inner.getFaces(assetId: assetId)
    }

    func getAssetOcr(id: String) async throws -> [AssetOcrResponseDto] {
        try await inner.getAssetOcr(id: id)
    }

    // MARK: - Partners

    func getPartners(direction: PartnerDirection) async throws -> [PartnerResponseDto] {
        try await inner.getPartners(direction: direction)
    }

    func createPartner(sharedWithId: String) async throws -> PartnerResponseDto {
        try assertWritable()
        return try await inner.createPartner(sharedWithId: sharedWithId)
    }

    func updatePartner(id: String, isInTimeline: Bool) async throws -> PartnerResponseDto {
        try assertWritable()
        return try await inner.updatePartner(id: id, isInTimeline: isInTimeline)
    }

    func removePartner(id: String) async throws {
        try assertWritable()
        try await inner.removePartner(id: id)
    }

    // MARK: - Activity

    func getActivities(albumId: String, assetId: String?) async throws -> [ActivityResponseDto] {
        try await inner.getActivities(albumId: albumId, assetId: assetId)
    }

    func createActivity(dto: ActivityCreateDto) async throws -> ActivityResponseDto {
        try assertWritable()
        return try await inner.createActivity(dto: dto)
    }

    func deleteActivity(id: String) async throws {
        try assertWritable()
        try await inner.deleteActivity(id: id)
    }

    // MARK: - Memories

    func getMemories() async throws -> [MemoryResponseDto] {
        try await inner.getMemories()
    }

    func getMemory(id: String) async throws -> MemoryResponseDto {
        try await inner.getMemory(id: id)
    }

    func updateMemory(id: String, dto: MemoryUpdateDto) async throws -> MemoryResponseDto {
        try assertWritable()
        return try await inner.updateMemory(id: id, dto: dto)
    }

    func deleteMemory(id: String) async throws {
        try assertWritable()
        try await inner.deleteMemory(id: id)
    }

    func createMemory(dto: MemoryCreateDto) async throws -> MemoryResponseDto {
        try assertWritable()
        return try await inner.createMemory(dto: dto)
    }

    @discardableResult
    func addAssetsToMemory(id: String, assetIds: [String]) async throws -> [BulkIdResponseDto] {
        try assertWritable()
        return try await inner.addAssetsToMemory(id: id, assetIds: assetIds)
    }

    @discardableResult
    func removeAssetsFromMemory(id: String, assetIds: [String]) async throws -> [BulkIdResponseDto] {
        try assertWritable()
        return try await inner.removeAssetsFromMemory(id: id, assetIds: assetIds)
    }

    func getMemoriesStatistics() async throws -> MemoryStatisticsResponseDto {
        try await inner.getMemoriesStatistics()
    }

    // MARK: - Duplicates (read)

    func getDuplicates() async throws -> [DuplicateResponseDto] {
        try await inner.getDuplicates()
    }

    // MARK: - Stacks

    func searchStacks(primaryAssetId: String?) async throws -> [StackResponseDto] {
        try await inner.searchStacks(primaryAssetId: primaryAssetId)
    }

    func createStack(assetIds: [String]) async throws -> StackResponseDto {
        try assertWritable()
        return try await inner.createStack(assetIds: assetIds)
    }

    func getStack(id: String) async throws -> StackResponseDto {
        try await inner.getStack(id: id)
    }

    func updateStack(id: String, primaryAssetId: String?) async throws -> StackResponseDto {
        try assertWritable()
        return try await inner.updateStack(id: id, primaryAssetId: primaryAssetId)
    }

    func deleteStack(id: String) async throws {
        try assertWritable()
        try await inner.deleteStack(id: id)
    }

    func removeAssetFromStack(stackId: String, assetId: String) async throws {
        try assertWritable()
        try await inner.removeAssetFromStack(stackId: stackId, assetId: assetId)
    }

    // MARK: - Admin

    func getAdminUsers() async throws -> [UserAdminResponseDto] {
        try await inner.getAdminUsers()
    }

    func createAdminUser(dto: UserAdminCreateDto) async throws -> UserAdminResponseDto {
        try assertWritable()
        return try await inner.createAdminUser(dto: dto)
    }

    func updateAdminUser(id: String, dto: UserAdminUpdateDto) async throws -> UserAdminResponseDto {
        try assertWritable()
        return try await inner.updateAdminUser(id: id, dto: dto)
    }

    func deleteAdminUser(id: String, force: Bool) async throws -> UserAdminResponseDto {
        try assertWritable()
        return try await inner.deleteAdminUser(id: id, force: force)
    }

    func restoreAdminUser(id: String) async throws -> UserAdminResponseDto {
        try assertWritable()
        return try await inner.restoreAdminUser(id: id)
    }

    func getJobsStatus() async throws -> [String: QueueResponseLegacyDto] {
        try await inner.getJobsStatus()
    }

    func sendJobCommand(name: String, command: String, force: Bool?) async throws -> QueueResponseLegacyDto {
        try assertWritable()
        return try await inner.sendJobCommand(name: name, command: command, force: force)
    }

    func getLibraries() async throws -> [LibraryResponseDto] {
        try await inner.getLibraries()
    }

    func scanLibrary(id: String) async throws {
        try assertWritable()
        try await inner.scanLibrary(id: id)
    }

    func deleteLibrary(id: String) async throws {
        try assertWritable()
        try await inner.deleteLibrary(id: id)
    }

    func getAPIKeys() async throws -> [ApiKeyResponseDto] {
        try await inner.getAPIKeys()
    }

    /// The key that carries this very request — a read.
    func getMyAPIKey() async throws -> ApiKeyResponseDto {
        try await inner.getMyAPIKey()
    }

    // API keys are access credentials, so their whole family answers to the
    // mode: a read-only session must not mint or revoke a way into the server.
    func createAPIKey(name: String, permissions: [String]) async throws -> ApiKeyCreateResponseDto {
        try assertWritable()
        return try await inner.createAPIKey(name: name, permissions: permissions)
    }

    func rotateAPIKey(id: String) async throws -> ApiKeyCreateResponseDto {
        try assertWritable()
        return try await inner.rotateAPIKey(id: id)
    }

    func deleteAPIKey(id: String) async throws {
        try assertWritable()
        try await inner.deleteAPIKey(id: id)
    }

    // MARK: - Server statistics (read)

    func getServerStatistics() async throws -> ServerStatsResponseDto {
        try await inner.getServerStatistics()
    }

    // MARK: - Locked folder (session mechanics: never refused)

    func getAuthStatus() async throws -> AuthStatusResponseDto {
        try await inner.getAuthStatus()
    }

    func setupPinCode(_ pinCode: String) async throws {
        try await inner.setupPinCode(pinCode)
    }

    func changePinCode(dto: PinCodeChangeDto) async throws {
        try await inner.changePinCode(dto: dto)
    }

    func unlockAuthSession(pinCode: String) async throws {
        try await inner.unlockAuthSession(pinCode: pinCode)
    }

    func lockAuthSession() async throws {
        try await inner.lockAuthSession()
    }

    // MARK: - Bulk asset update

    func bulkUpdateAssets(dto: AssetBulkUpdateDto) async throws {
        try assertWritable()
        try await inner.bulkUpdateAssets(dto: dto)
    }

    // MARK: - Users (read)

    func getUsers() async throws -> [UserResponseDto] {
        try await inner.getUsers()
    }

    // MARK: - Profile picture (account, not library: never refused)

    func getMyUser() async throws -> UserAdminResponseDto {
        try await inner.getMyUser()
    }

    func uploadProfileImage(fileURL: URL, filename: String, contentType: String) async throws -> CreateProfileImageResponseDto {
        try await inner.uploadProfileImage(fileURL: fileURL, filename: filename, contentType: contentType)
    }

    func deleteProfileImage() async throws {
        try await inner.deleteProfileImage()
    }

    // MARK: - Upload

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
        try assertWritable()
        return try await inner.uploadAsset(
            fileURL: fileURL,
            fileCreatedAt: fileCreatedAt,
            fileModifiedAt: fileModifiedAt,
            filename: filename,
            duration: duration,
            isFavorite: isFavorite,
            visibility: visibility,
            livePhotoVideoId: livePhotoVideoId,
            checksum: checksum,
            deviceAssetId: deviceAssetId,
            deviceId: deviceId
        )
    }

    /// `POST /api/assets/bulk-upload-check` asks; it writes nothing, so the
    /// dedup pass of a backup still answers truthfully (and the run itself is
    /// refused before it starts — `UploadViewModel.runBackup`).
    func bulkUploadCheck(_ request: AssetBulkUploadCheckRequest) async throws -> AssetBulkUploadCheckResponse {
        try await inner.bulkUploadCheck(request)
    }

    // MARK: - Download queue (reads: the requests carry no mutation)

    func downloadInfo(assetIds: [String], albumId: String?) async throws -> DownloadInfoResponse {
        try await inner.downloadInfo(assetIds: assetIds, albumId: albumId)
    }

    func originalRequest(assetId: String) throws -> URLRequest {
        try inner.originalRequest(assetId: assetId)
    }

    func downloadArchiveRequest(archiveName: String, assetIds: [String], edited: Bool) throws -> URLRequest {
        try inner.downloadArchiveRequest(archiveName: archiveName, assetIds: assetIds, edited: edited)
    }

    var requestCount: Int { inner.requestCount }
}
