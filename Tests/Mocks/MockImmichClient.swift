import Foundation
@testable import ImmichSwiftUI

/// The filters of one timeline request, comparable between `getTimeBuckets`
/// and `getTimeBucket` (the server expects the same ones on both routes).
struct TimelineFilterCapture: Equatable {
    let isFavorite: Bool?
    let isTrashed: Bool?
    let personId: String?
    let withPartners: Bool?
    let visibility: String?
    let withStacked: Bool?
    let orderBy: AssetOrderBy?
}

/// One `getPeople` request, comparable in tests.
struct PeopleCall: Equatable {
    let page: Int?
    let withHidden: Bool?
}

/// Test double for ImmichClient. Records the last call per endpoint + lets
/// tests inject canned responses / errors.
final class MockImmichClient: ImmichClient, @unchecked Sendable {
    // Captured request state (AC-003 / AC-008 / AC-010)
    private(set) var requestCount = 0
    private let lock = NSLock()

    // ImmichClient lifecycle surface (no-op storage; tests inspect directly).
    var configuredBaseURL: URL?
    var configuredToken: String?
    func configure(baseURL: URL?, token: String?) {
        configuredBaseURL = baseURL
        configuredToken = token
    }
    var authDelegate: (any AuthSessionDelegate)?

    /// Overrides `GET /api/server/config` (its `externalDomain` decides the base
    /// of a public shared-link URL).
    var serverConfigResponse: ServerConfigDto?

    var lastLoginBody: LoginCredentialDto?
    var loginResponse: LoginResponseDto?
    var loginError: Error?

    // OAuth (P5)
    var oauthAuthorizeResponse: OAuthAuthorizeResponseDto?
    var oauthCallbackResponse: LoginResponseDto?
    var oauthError: Error?
    var lastOAuthRedirectURI: String?
    var lastOAuthState: String?
    var lastOAuthCodeChallenge: String?
    var lastOAuthCallbackURL: String?
    var lastOAuthCallbackState: String?
    var lastOAuthCodeVerifier: String?

    var pingResponse: ServerPingResponse?
    var pingError: Error?
    var pingResSequences: [ServerPingResponse] = []
    private var pingCallIndex = 0

    /// Version `serverVersion()` reports; `nil` keeps the default **1.120.0**,
    /// i.e. the flat search route. A case that asserts the v3.2.0 shape sets a
    /// `3.2.0` (or later) version here.
    var serverVersionResponse: ServerVersionResponseDto?
    var serverVersionError: Error?

    var logoutResponse: LogoutResponseDto?
    var validateResponse: ValidateAccessTokenResponseDto?
    var validateError: Error?
    var validateTokenCallCount = 0
    /// Awaited in `validateToken` after `bump()` and the recording, before the error check.
    var validateTokenGate: (() async throws -> Void)?

    // Locked folder (gap G12)
    /// `GET /api/auth/status` answer; defaults to a PIN-protected, unelevated
    /// session (the door the folder shows after the first setup).
    var authStatus: AuthStatusResponseDto?
    var authStatusError: Error?
    /// How many times `GET /api/auth/status` was asked, in order — the proof a
    /// screen re-reads the elevation instead of assuming it.
    private(set) var authStatusCallCount = 0
    /// Every PIN the elevation route was called with, in order — the folder's
    /// tests assert on what actually reached the server.
    var unlockedPINs: [String] = []
    var unlockAuthSessionError: Error?
    var createdPINs: [String] = []
    var setupPinCodeError: Error?
    var changedPINCodeDtos: [PinCodeChangeDto] = []
    var changePinCodeError: Error?
    var lockSessionCallCount = 0
    var lockAuthSessionError: Error?

    func getAuthStatus() async throws -> AuthStatusResponseDto {
        bump()
        authStatusCallCount += 1
        if let e = globalError ?? authStatusError { throw e }
        return authStatus ?? AuthStatusResponseDto(
            expiresAt: nil, isElevated: false, password: true, pinCode: true, pinExpiresAt: nil
        )
    }

    func setupPinCode(_ pinCode: String) async throws {
        bump()
        createdPINs.append(pinCode)
        if let e = globalError ?? setupPinCodeError { throw e }
    }

    func changePinCode(dto: PinCodeChangeDto) async throws {
        bump()
        changedPINCodeDtos.append(dto)
        if let e = globalError ?? changePinCodeError { throw e }
    }

    func unlockAuthSession(pinCode: String) async throws {
        bump()
        unlockedPINs.append(pinCode)
        if let e = globalError ?? unlockAuthSessionError { throw e }
    }

    func lockAuthSession() async throws {
        bump()
        lockSessionCallCount += 1
        if let e = globalError ?? lockAuthSessionError { throw e }
    }

    func authorizeOAuth(redirectURI: String, state: String, codeChallenge: String) async throws -> OAuthAuthorizeResponseDto {
        bump()
        lastOAuthRedirectURI = redirectURI
        lastOAuthState = state
        lastOAuthCodeChallenge = codeChallenge
        if let e = globalError ?? oauthError { throw e }
        return oauthAuthorizeResponse ?? OAuthAuthorizeResponseDto(url: "https://sso.example.com/authorize")
    }

    func exchangeOAuthCode(url: String, state: String, codeVerifier: String) async throws -> LoginResponseDto {
        bump()
        lastOAuthCallbackURL = url
        lastOAuthCallbackState = state
        lastOAuthCodeVerifier = codeVerifier
        if let e = globalError ?? oauthError { throw e }
        return oauthCallbackResponse ?? LoginResponseDto(
            accessToken: "oauth-token", userId: "oauth-user", userEmail: "oauth@example.com",
            name: "OAuth User", profileImagePath: "", isAdmin: false,
            shouldChangePassword: false, isOnboarded: true
        )
    }

    var bucketsResponse: [TimeBucketsResponseDto] = []
    var bucketResponses: [String: TimeBucketAssetResponseDto] = [:]

    var getAssetResponse: [String: AssetResponseDto] = [:]
    /// Ids passed to `getAsset`, recorded before the gate.
    var getAssetCalls: [String] = []
    /// Awaited in `getAsset` after `bump()` and the recording, before the error check.
    var getAssetGate: ((String) async throws -> Void)?
    var lastUpdateAssetId: String?
    var lastUpdateAssetBody: UpdateAssetDto?
    var updateAssetResponse: AssetResponseDto?
    var lastDeleteBody: AssetBulkDeleteDto?
    var deleteError: Error?

    // Trash capture (AC-300, AC-307..AC-309)
    var lastTimeBucketsIsTrashed: Bool?
    var lastTimeBucketsIsFavorite: Bool?
    var lastTimeBucketsVisibility: String?
    var lastTimeBucketsWithPartners: Bool?
    var lastTimeBucketsWithStacked: Bool?
    /// Sort axis asked of `GET /api/timeline/buckets` — the only witness of the
    /// `orderBy` wire parameter without a server.
    var lastTimeBucketsOrderBy: AssetOrderBy?
    var lastTimeBucketIsFavorite: Bool?
    var lastTimeBucketIsTrashed: Bool?
    var lastTimeBucketWithPartners: Bool?
    var lastTimeBucketVisibility: String?
    var lastTimeBucketWithStacked: Bool?
    var lastTimeBucketOrderBy: AssetOrderBy?
    /// Filters of the last `getTimeBuckets` call, as one comparable value.
    var lastTimeBucketsFilters: TimelineFilterCapture?
    /// Every `getTimeBucket` call in order: the month and the filters sent.
    var timeBucketCalls: [(timeBucket: String, filters: TimelineFilterCapture)] = []
    var lastRestoreTrashAssetsIds: [String]?
    var restoreTrashAssetsResponse: TrashResponseDto?
    var restoreTrashAssetsError: Error?
    var restoreAllTrashCallCount = 0
    var restoreAllTrashResponse: TrashResponseDto?
    var restoreAllTrashError: Error?
    var emptyTrashCallCount = 0
    var emptyTrashResponse: TrashResponseDto?
    var emptyTrashError: Error?

    // Search capture (AC-400..AC-406)
    var lastMetadataSearchDto: MetadataSearchDto?
    var searchMetadataResponse: SearchResponseDto?
    var searchMetadataError: Error?
    /// Every `searchMetadata` call, recorded before any gate or error.
    var searchMetadataCalls: [MetadataSearchDto] = []
    /// Awaited after recording and before the error check.
    var searchMetadataGate: ((MetadataSearchDto) async throws -> Void)?
    /// When set, supplies the response (after the gate and error check): a fake offset server.
    var searchMetadataHandler: ((MetadataSearchDto) async throws -> SearchResponseDto)?
    /// Responses keyed by `dto.page ?? 1`, consulted after the handler.
    var searchMetadataResponsesByPage: [Int: SearchResponseDto] = [:]
    /// Awaited in `removeAssetsFromAlbum` after `lastRemoveAssetsIds` is recorded, before the error check.
    var removeAssetsFromAlbumGate: ((BulkIdsDto) async throws -> Void)?
    var lastSmartSearchDto: SmartSearchDto?
    var smartSearchResponse: SearchResponseDto?
    var smartSearchError: Error?
    var exploreResponse: [SearchExploreResponseDto]?
    var exploreError: Error?
    var citiesResponse: [AssetResponseDto]?
    var citiesError: Error?
    // Folder view capture (gap G11)
    var folderPathsResponse: [String]?
    var folderPathsError: Error?
    var folderAssetsResponse: [AssetResponseDto]?
    var folderAssetsError: Error?
    /// Every `path` handed to `getFolderAssets`, in order — the only way a test
    /// can pin the wire contract (the server only returns direct children).
    private(set) var requestedFolderPaths: [String] = []
    var lastStatisticsDto: SearchStatisticsDto?
    var statisticsResponse: SearchStatisticsResponseDto?
    /// Per-city count overrides (keyed by city name). If set, the mock returns
    /// a custom total for that city; otherwise `statisticsResponse`.
    var statisticsByCity: [String: Int] = [:]
    var statisticsError: Error?

    // Map capture (AC-710)
    var mapMarkersResponse: [MapMarkerResponseDto]?
    var mapMarkersError: Error?
    var lastMapMarkersFilter: MapMarkerFilter?

    // Albums capture (AC-500..AC-518)
    var albumsResponse: [AlbumResponseDto]?
    var albumsError: Error?
    var lastCreateAlbumDto: CreateAlbumDto?
    /// Every album name passed to `createAlbum`, in order — the album mirror
    /// asserts *what* it created, not just how many times.
    var createdAlbumNames: [String] = []
    var createAlbumResponse: AlbumResponseDto?
    var createAlbumError: Error?
    var getAlbumResponse: [String: AlbumResponseDto] = [:]
    var getAlbumError: Error?
    var lastUpdateAlbumId: String?
    var lastUpdateAlbumDto: UpdateAlbumDto?
    var updateAlbumResponse: AlbumResponseDto?
    var updateAlbumError: Error?
    var deleteAlbumCallCount = 0
    var lastDeletedAlbumId: String?
    var deleteAlbumError: Error?
    var lastAddAssetsAlbumId: String?
    var lastAddAssetsIds: [String]?
    /// Every add-assets call in order — the mirror's batching is asserted on
    /// the chunk boundaries, which the "last call" fields cannot show.
    var addAssetsToAlbumCalls: [(albumId: String, ids: [String])] = []
    /// Suspension point right after the call is recorded — lets a test hold an
    /// album flush in flight.
    var addAssetsToAlbumGate: (() async throws -> Void)?
    var addAssetsResponse: [BulkIdResponseDto]?
    var addAssetsError: Error?
    var lastRemoveAssetsAlbumId: String?
    var lastRemoveAssetsIds: [String]?
    var removeAssetsResponse: [BulkIdResponseDto]?
    var removeAssetsError: Error?

    // Shared links capture (AC-500..AC-518)
    var lastSharedLinksAlbumId: String?
    var sharedLinksResponse: [SharedLinkResponseDto]?
    var sharedLinksError: Error?
    var lastCreateSharedLinkDto: SharedLinkCreateDto?
    var createSharedLinkResponse: SharedLinkResponseDto?
    var createSharedLinkError: Error?
    var lastDeleteSharedLinkId: String?
    var deleteSharedLinkCallCount = 0
    var deleteSharedLinkError: Error?

    // Users capture (photo share user picker)
    var getUsersResponse: [UserResponseDto]?
    var getUsersError: Error?

    // Profile picture capture (gap G16)
    var getMyUserResponse: UserAdminResponseDto?
    var getMyUserError: Error?
    var uploadProfileImageResponse: CreateProfileImageResponseDto?
    var uploadProfileImageError: Error?
    var deleteProfileImageError: Error?
    var deleteProfileImageCallCount = 0
    /// What the upload actually received: the test asserts on the bytes and the
    /// part's filename/content type, not on the fact that a method ran.
    var lastProfileImageUpload: (filename: String, contentType: String, data: Data)?

    // P0 api-surface-expansion capture
    var peopleResponse: PeopleResponseDto?
    var peopleError: Error?
    var lastPeoplePage: Int?
    var lastPeopleWithHidden: Bool?
    var lastUpdatePersonId: String?
    var lastUpdatePersonDto: PersonUpdateDto?
    /// Set by `clearPersonBirthday` — a test proves the erase took the
    /// dedicated route instead of `PersonUpdateDto(birthDate: nil)`, which
    /// would leave `lastUpdatePersonDto` non-nil.
    var lastClearedPersonBirthdayId: String?
    var lastMergePersonIds: [String]?
    var lastMergeTargetId: String?
    var mergePeopleResponse: [BulkIdResponseDto]?
    var personStatisticsResponse: [String: PersonStatisticsResponseDto] = [:]
    /// Every `getPeople` call, recorded under `lock` before the gate and the error check.
    private(set) var getPeopleCalls: [PeopleCall] = []
    /// Awaited after recording and before the error check; may throw to fail one page.
    var peopleGate: ((PeopleCall) async throws -> Void)?
    /// Responses keyed by `page ?? 1`, consulted after the error and before `peopleResponse`.
    var peopleResponsesByPage: [Int: PeopleResponseDto] = [:]
    /// Every statistics id requested, under `lock` (the VM calls it concurrently).
    private(set) var personStatisticsCalls: [String] = []
    var partnersSharedWithResponse: [PartnerResponseDto]?
    var partnersSharedByResponse: [PartnerResponseDto]?
    var partnersError: Error?
    /// Every direction requested, in order — the query param is **required**
    /// server-side, so a test must be able to assert it was sent.
    var lastPartnersDirections: [PartnerDirection] = []
    var lastPartnersDirection: PartnerDirection? { lastPartnersDirections.last }
    var lastCreatePartnerSharedWithId: String?
    var createPartnerResponse: PartnerResponseDto?
    var lastUpdatePartnerId: String?
    var lastUpdatePartnerInTimeline: Bool?
    var updatePartnerResponse: PartnerResponseDto?
    var lastRemovePartnerId: String?
    var lastActivitiesAlbumId: String?
    var lastActivitiesAssetId: String?
    var activitiesResponse: [ActivityResponseDto]?
    var activitiesError: Error?
    var lastCreateActivityDto: ActivityCreateDto?
    var createActivityResponse: ActivityResponseDto?
    var lastDeleteActivityId: String?
    var memoriesResponse: [MemoryResponseDto]?
    var memoriesError: Error?
    /// Per-id answers for `getMemory` — the CRUD paths re-read a memory after a
    /// mutation that answers with per-asset results.
    var memoryDetailResponses: [String: MemoryResponseDto] = [:]
    var lastGetMemoryId: String?
    var lastUpdateMemoryId: String?
    var lastUpdateMemoryDto: MemoryUpdateDto?
    var updateMemoryResponse: MemoryResponseDto?
    var lastDeleteMemoryId: String?
    var deleteMemoryCallCount = 0
    var lastCreateMemoryDto: MemoryCreateDto?
    var createMemoryResponse: MemoryResponseDto?
    var lastAddAssetsMemoryId: String?
    var lastAddAssetsMemoryIds: [String]?
    var addAssetsMemoryResponse: [BulkIdResponseDto]?
    var lastRemoveAssetsMemoryId: String?
    var lastRemoveAssetsMemoryIds: [String]?
    var removeAssetsMemoryResponse: [BulkIdResponseDto]?
    var memoriesStatisticsResponse: MemoryStatisticsResponseDto?
    var duplicatesResponse: [DuplicateResponseDto]?
    var duplicatesError: Error?
    var serverStatisticsResponse: ServerStatsResponseDto?
    var lastUpdateSharedLinkId: String?
    var lastUpdateSharedLinkDto: SharedLinkEditDto?
    var updateSharedLinkResponse: SharedLinkResponseDto?
    var lastAddAssetsSharedLinkId: String?
    var lastAddAssetsSharedLinkIds: [String]?
    var addAssetsSharedLinkResponse: [AssetIdsResponseDto]?
    var addAssetsSharedLinkError: Error?
    var lastBulkUpdateDto: AssetBulkUpdateDto?

    // Album users capture (album share)
    var lastAddUsersAlbumId: String?
    var lastAddUsersDto: AddUsersDto?
    var addUsersResponse: AlbumResponseDto?
    var addUsersError: Error?
    var lastRoleUpdateAlbumId: String?
    var lastRoleUpdateUserId: String?
    var lastRoleUpdateDto: UpdateAlbumUserDto?
    var updateRoleError: Error?
    var lastRemovedUserAlbumId: String?
    var lastRemovedUserId: String?
    var removeUserError: Error?

    // Upload capture (AC-008)
    var lastUploadData: Data?
    var lastUploadFileCreatedAt: String?
    var lastUploadFileModifiedAt: String?
    var lastUploadFilename: String?
    var lastUploadDuration: Int?
    var lastUploadIsFavorite: Bool?
    var lastUploadVisibility: AssetVisibility?
    var lastUploadChecksum: String?
    var lastUploadLivePhotoVideoId: String?
    var lastUploadDeviceAssetId: String?
    var lastUploadDeviceId: String?
    /// Every upload in order — the Live Photo paths are about *order* (hidden
    /// video first, then the still) as much as about content.
    var uploads: [(filename: String, visibility: AssetVisibility, livePhotoVideoId: String?, deviceAssetId: String?)] = []
    var uploadResponse: AssetMediaResponseDto?
    var uploadError: Error?
    /// Per-filename answers, so a batch can mix a successful video upload with
    /// a failing still (or the reverse). Falls back to `uploadResponse`.
    var uploadResponsesByFilename: [String: AssetMediaResponseDto] = [:]
    /// Applied per filename; falls back to `uploadError`.
    var uploadErrorsByFilename: [String: Error] = [:]
    /// Captured `updateAsset` (id, dto) calls — the Live Photo repair path.
    var updateAssetCalls: [(id: String, dto: UpdateAssetDto)] = []
    /// Captured bulk-check payloads, per call (chunking assertions).
    var bulkUploadCheckChunks: [[AssetBulkUploadCheckRequest.Item]] = []

    var bulkUploadCheckResponse: AssetBulkUploadCheckResponse?

    // Mutable global error that, if set, is thrown from any call.
    var globalError: Error?
    /// Fails `updateAsset` once `updateAssetErrorAfterSuccesses` writes have
    /// succeeded (0 = every call fails). Failed calls are not recorded in
    /// `updateAssetCalls`.
    var updateAssetError: Error?
    var updateAssetErrorAfterSuccesses = 0

    func bump() { lock.lock(); requestCount += 1; lock.unlock() }

    func ping() async throws -> ServerPingResponse {
        bump()
        if let e = globalError ?? pingError { throw e }
        if !pingResSequences.isEmpty {
            let r = pingResSequences[min(pingCallIndex, pingResSequences.count - 1)]
            pingCallIndex += 1
            return r
        }
        return pingResponse ?? ServerPingResponse(res: "pong")
    }

    func serverVersion() async throws -> ServerVersionResponseDto {
        bump()
        if let e = globalError ?? serverVersionError { throw e }
        return serverVersionResponse ?? ServerVersionResponseDto(major: 1, minor: 120, patch: 0, prerelease: nil)
    }

    func serverConfig() async throws -> ServerConfigDto {
        bump()
        if let e = globalError { throw e }
        if let r = serverConfigResponse { return r }
        return ServerConfigDto(
            oauthButtonText: "", loginPageMessage: "", trashDays: 30, userDeleteDelay: 7,
            isInitialized: true, isOnboarded: true, externalDomain: "", publicUsers: false,
            mapDarkStyleUrl: "", mapLightStyleUrl: "", maintenanceMode: false, minFaces: 3
        )
    }

    func login(email: String, password: String) async throws -> LoginResponseDto {
        bump()
        lastLoginBody = LoginCredentialDto(email: email, password: password)
        if let e = globalError ?? loginError { throw e }
        return loginResponse ?? LoginResponseDto(
            accessToken: "test-jwt", userId: "user-uuid", userEmail: email, name: "Test",
            profileImagePath: "", isAdmin: false, shouldChangePassword: false, isOnboarded: true
        )
    }

    func logout() async throws -> LogoutResponseDto {
        bump()
        if let e = globalError { throw e }
        return logoutResponse ?? LogoutResponseDto(successful: true, redirectUri: "")
    }

    private func recordValidateToken() { lock.lock(); validateTokenCallCount += 1; lock.unlock() }
    private func recordGetAsset(_ id: String) { lock.lock(); getAssetCalls.append(id); lock.unlock() }

    func validateToken() async throws -> ValidateAccessTokenResponseDto {
        bump()
        recordValidateToken()
        if let gate = validateTokenGate { try await gate() }
        if let e = globalError ?? validateError { throw e }
        return validateResponse ?? ValidateAccessTokenResponseDto(authStatus: true)
    }

    func getTimeBuckets(
        isFavorite: Bool?,
        isTrashed: Bool?,
        personId: String?,
        withPartners: Bool?,
        visibility: String?,
        withStacked: Bool?,
        orderBy: AssetOrderBy?
    ) async throws -> [TimeBucketsResponseDto] {
        bump()
        lastTimeBucketsIsTrashed = isTrashed
        lastTimeBucketsIsFavorite = isFavorite
        lastTimeBucketsVisibility = visibility
        lastTimeBucketsWithPartners = withPartners
        lastTimeBucketsWithStacked = withStacked
        lastTimeBucketsOrderBy = orderBy
        lastTimeBucketsFilters = TimelineFilterCapture(
            isFavorite: isFavorite, isTrashed: isTrashed, personId: personId,
            withPartners: withPartners, visibility: visibility,
            withStacked: withStacked, orderBy: orderBy
        )
        if let e = globalError { throw e }
        return bucketsResponse
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
        bump()
        lastTimeBucketIsFavorite = isFavorite
        lastTimeBucketIsTrashed = isTrashed
        lastTimeBucketVisibility = visibility
        lastTimeBucketWithPartners = withPartners
        lastTimeBucketWithStacked = withStacked
        lastTimeBucketOrderBy = orderBy
        timeBucketCalls.append((timeBucket: timeBucket, filters: TimelineFilterCapture(
            isFavorite: isFavorite, isTrashed: isTrashed, personId: personId,
            withPartners: withPartners, visibility: visibility,
            withStacked: withStacked, orderBy: orderBy
        )))
        if let e = globalError { throw e }
        return bucketResponses[timeBucket] ?? TimeBucketAssetResponseDto(
            id: [], ownerId: [], ratio: [], isFavorite: [], visibility: [], isTrashed: [],
            isImage: [], thumbhash: [], createdAt: [], fileCreatedAt: [], localOffsetHours: [],
            duration: [], livePhotoVideoId: [], projectionType: [],
            stack: nil, city: nil, country: nil, latitude: nil, longitude: nil
        )
    }

    func getAsset(id: String) async throws -> AssetResponseDto {
        bump()
        recordGetAsset(id)
        if let gate = getAssetGate { try await gate(id) }
        if let e = globalError { throw e }
        return getAssetResponse[id] ?? AssetResponseDto(
            id: id, type: "IMAGE", thumbhash: nil, localDateTime: "2024-07-01T00:00:00.000Z",
            duration: nil, hasMetadata: true, width: 100, height: 100, createdAt: "2024-07-01T00:00:00.000Z",
            ownerId: "owner", originalPath: "/x.jpg", originalFileName: "x.jpg",
            fileCreatedAt: "2024-07-01T00:00:00.000Z", fileModifiedAt: "2024-07-01T00:00:00.000Z",
            updatedAt: "2024-07-01T00:00:00.000Z", isFavorite: false, isArchived: false,
            isTrashed: false, isOffline: false, visibility: "timeline", checksum: "abc", isEdited: false
        )
    }

    /// Per-id refusal of `updateAsset` (e.g. a partner's asset the server will
    /// not let me modify). Checked before any capture: a refused call is not
    /// recorded in `updateAssetCalls`.
    var updateAssetErrorsById: [String: Error] = [:]

    func updateAsset(id: String, dto: UpdateAssetDto) async throws -> AssetResponseDto {
        bump()
        if let e = globalError { throw e }
        if let e = updateAssetError, updateAssetCalls.count >= updateAssetErrorAfterSuccesses { throw e }
        if let e = updateAssetErrorsById[id] { throw e }
        lastUpdateAssetId = id
        lastUpdateAssetBody = dto
        updateAssetCalls.append((id: id, dto: dto))
        if let r = updateAssetResponse { return r }
        // Echo back with isFavorite toggled.
        var base = try await getAsset(id: id)
        if let fav = dto.isFavorite { base.isFavorite = fav }
        return base
    }

    /// Star-rating writes (star-ratings): every `(id, rating)` call in order,
    /// plus per-call canned answers when a test needs a specific response.
    var ratingUpdates: [(id: String, rating: Int?)] = []
    var ratingUpdateResults: [Result<AssetResponseDto, Error>] = []

    func setAssetRating(id: String, rating: Int?) async throws -> AssetResponseDto {
        bump()
        ratingUpdates.append((id: id, rating: rating))
        if !ratingUpdateResults.isEmpty {
            return try ratingUpdateResults.removeFirst().get()
        }
        if let e = globalError { throw e }
        // Echo the rating back the way the server would: the write response is
        // the updated asset, so `exifInfo.rating` follows without a re-fetch.
        var base = try await getAsset(id: id)
        base.exifInfo = ExifResponseDto(rating: rating)
        return base
    }

    func deleteAssets(ids: [String], force: Bool?) async throws {
        bump()
        lastDeleteBody = AssetBulkDeleteDto(ids: ids, force: force)
        if let e = globalError ?? deleteError { throw e }
    }

    // MARK: - Trash (AC-307..AC-309)

    func restoreTrashAssets(ids: [String]) async throws -> TrashResponseDto {
        bump()
        lastRestoreTrashAssetsIds = ids
        if let e = globalError ?? restoreTrashAssetsError { throw e }
        return restoreTrashAssetsResponse ?? TrashResponseDto(count: ids.count)
    }

    func restoreAllTrash() async throws -> TrashResponseDto {
        bump()
        restoreAllTrashCallCount += 1
        if let e = globalError ?? restoreAllTrashError { throw e }
        return restoreAllTrashResponse ?? TrashResponseDto(count: 5)
    }

    func emptyTrash() async throws -> TrashResponseDto {
        bump()
        emptyTrashCallCount += 1
        if let e = globalError ?? emptyTrashError { throw e }
        return emptyTrashResponse ?? TrashResponseDto(count: 5)
    }

    // MARK: - Search (AC-400..AC-406)

    func searchMetadata(dto: MetadataSearchDto) async throws -> SearchResponseDto {
        bump()
        lastMetadataSearchDto = dto
        searchMetadataCalls.append(dto)
        if let gate = searchMetadataGate { try await gate(dto) }
        if let e = globalError ?? searchMetadataError { throw e }
        if let handler = searchMetadataHandler { return try await handler(dto) }
        if let byPage = searchMetadataResponsesByPage[dto.page ?? 1] { return byPage }
        return searchMetadataResponse ?? SearchResponseDto(
            assets: SearchAssetResponseDto(count: 0, items: [], nextPage: nil)
        )
    }

    func searchSmart(dto: SmartSearchDto) async throws -> SearchResponseDto {
        bump()
        lastSmartSearchDto = dto
        if let e = globalError ?? smartSearchError { throw e }
        return smartSearchResponse ?? SearchResponseDto(
            assets: SearchAssetResponseDto(count: 0, items: [], nextPage: nil)
        )
    }

    func getExploreData() async throws -> [SearchExploreResponseDto] {
        bump()
        if let e = globalError ?? exploreError { throw e }
        return exploreResponse ?? []
    }

    func getAssetsByCity() async throws -> [AssetResponseDto] {
        bump()
        if let e = globalError ?? citiesError { throw e }
        return citiesResponse ?? []
    }

    // MARK: - Folder view (gap G11)

    func getFolderAssets(path: String) async throws -> [AssetResponseDto] {
        bump()
        requestedFolderPaths.append(path)
        if let e = globalError ?? folderAssetsError { throw e }
        return folderAssetsResponse ?? []
    }

    func getUniqueFolderPaths() async throws -> [String] {
        bump()
        if let e = globalError ?? folderPathsError { throw e }
        return folderPathsResponse ?? []
    }

    func searchStatistics(dto: SearchStatisticsDto) async throws -> SearchStatisticsResponseDto {
        bump()
        lastStatisticsDto = dto
        if let e = globalError ?? statisticsError { throw e }
        if let city = dto.city, let total = statisticsByCity[city] {
            return SearchStatisticsResponseDto(total: total)
        }
        return statisticsResponse ?? SearchStatisticsResponseDto(total: 0)
    }

    func getMapMarkers(filter: MapMarkerFilter) async throws -> [MapMarkerResponseDto] {
        bump()
        lastMapMarkersFilter = filter
        if let e = globalError ?? mapMarkersError { throw e }
        return mapMarkersResponse ?? []
    }

    // MARK: - Albums (AC-500..AC-518)

    private func cannedAlbum(id: String, name: String = "Album", count: Int = 0) -> AlbumResponseDto {
        AlbumResponseDto(
            id: id, albumName: name, description: "", createdAt: "2024-01-01T00:00:00.000Z",
            updatedAt: "2024-01-01T00:00:00.000Z", albumThumbnailAssetId: nil, shared: false,
            hasSharedLink: false, assetCount: count, isActivityEnabled: false, order: nil
        )
    }

    private func cannedUser(id: String, name: String = "User") -> UserResponseDto {
        UserResponseDto(
            id: id, name: name, email: "\(id)@example.com",
            profileImagePath: "", avatarColor: "#FF0000", profileChangedAt: "2024-01-01T00:00:00.000Z"
        )
    }

    private func cannedPerson(id: String, name: String = "Person") -> PersonResponseDto {
        PersonResponseDto(
            id: id, name: name, birthDate: "2024-01-01", thumbnailPath: "",
            isHidden: false, color: nil, isFavorite: nil, updatedAt: nil
        )
    }

    func getAlbums() async throws -> [AlbumResponseDto] {
        bump()
        if let e = globalError ?? albumsError { throw e }
        return albumsResponse ?? []
    }

    func createAlbum(dto: CreateAlbumDto) async throws -> AlbumResponseDto {
        bump()
        lastCreateAlbumDto = dto
        createdAlbumNames.append(dto.albumName)
        if let e = globalError ?? createAlbumError { throw e }
        return createAlbumResponse ?? cannedAlbum(id: "album-new", name: dto.albumName, count: dto.assetIds?.count ?? 0)
    }

    func getAlbum(id: String) async throws -> AlbumResponseDto {
        bump()
        if let e = globalError ?? getAlbumError { throw e }
        return getAlbumResponse[id] ?? cannedAlbum(id: id)
    }

    func updateAlbum(id: String, dto: UpdateAlbumDto) async throws -> AlbumResponseDto {
        bump()
        lastUpdateAlbumId = id
        lastUpdateAlbumDto = dto
        if let e = globalError ?? updateAlbumError { throw e }
        if let r = updateAlbumResponse { return r }
        var base = getAlbumResponse[id] ?? cannedAlbum(id: id)
        if let name = dto.albumName { base.albumName = name }
        if let desc = dto.description { base.description = desc }
        if let activity = dto.isActivityEnabled { base.isActivityEnabled = activity }
        if let cover = dto.albumThumbnailAssetId { base.albumThumbnailAssetId = cover }
        return base
    }

    func addUsersToAlbum(albumId: String, dto: AddUsersDto) async throws -> AlbumResponseDto {
        bump()
        lastAddUsersAlbumId = albumId
        lastAddUsersDto = dto
        if let e = globalError ?? addUsersError { throw e }
        if let r = addUsersResponse { return r }
        var base = getAlbumResponse[albumId] ?? cannedAlbum(id: albumId)
        base.albumUsers = dto.albumUsers.map { AlbumUserResponseDto(user: cannedUser(id: $0.userId), role: $0.role) }
        return base
    }

    func updateAlbumUserRole(albumId: String, userId: String, dto: UpdateAlbumUserDto) async throws {
        bump()
        lastRoleUpdateAlbumId = albumId
        lastRoleUpdateUserId = userId
        lastRoleUpdateDto = dto
        if let e = globalError ?? updateRoleError { throw e }
    }

    func removeUserFromAlbum(albumId: String, userId: String) async throws {
        bump()
        lastRemovedUserAlbumId = albumId
        lastRemovedUserId = userId
        if let e = globalError ?? removeUserError { throw e }
    }

    func deleteAlbum(id: String) async throws {
        bump()
        deleteAlbumCallCount += 1
        lastDeletedAlbumId = id
        if let e = globalError ?? deleteAlbumError { throw e }
    }

    func addAssetsToAlbum(albumId: String, dto: BulkIdsDto) async throws -> [BulkIdResponseDto] {
        bump()
        lastAddAssetsAlbumId = albumId
        lastAddAssetsIds = dto.ids
        addAssetsToAlbumCalls.append((albumId: albumId, ids: dto.ids))
        if let gate = addAssetsToAlbumGate { try await gate() }
        // Like URLSession: a call made from a cancelled Task fails (the call
        // stays recorded).
        try Task.checkCancellation()
        if let e = globalError ?? addAssetsError { throw e }
        return addAssetsResponse ?? dto.ids.map { BulkIdResponseDto(id: $0, success: true, error: nil, errorMessage: nil) }
    }

    func removeAssetsFromAlbum(albumId: String, dto: BulkIdsDto) async throws -> [BulkIdResponseDto] {
        bump()
        lastRemoveAssetsAlbumId = albumId
        lastRemoveAssetsIds = dto.ids
        if let gate = removeAssetsFromAlbumGate { try await gate(dto) }
        if let e = globalError ?? removeAssetsError { throw e }
        return removeAssetsResponse ?? dto.ids.map { BulkIdResponseDto(id: $0, success: true, error: nil, errorMessage: nil) }
    }

    // MARK: - Shared Links (AC-500..AC-518)

    func getSharedLinks(albumId: String?) async throws -> [SharedLinkResponseDto] {
        bump()
        lastSharedLinksAlbumId = albumId
        if let e = globalError ?? sharedLinksError { throw e }
        return sharedLinksResponse ?? []
    }

    func createSharedLink(dto: SharedLinkCreateDto) async throws -> SharedLinkResponseDto {
        bump()
        lastCreateSharedLinkDto = dto
        if let e = globalError ?? createSharedLinkError { throw e }
        if let r = createSharedLinkResponse { return r }
        return SharedLinkResponseDto(
            id: "link-new", description: dto.description, password: dto.password, userId: "owner",
            key: "a2V5", type: dto.type, createdAt: "2024-01-01T00:00:00.000Z", expiresAt: dto.expiresAt,
            assets: [], album: nil, allowUpload: dto.allowUpload ?? false,
            allowDownload: dto.allowDownload ?? true, showMetadata: dto.showMetadata ?? true,
            slug: dto.slug ?? nil
        )
    }

    func deleteSharedLink(id: String) async throws {
        bump()
        deleteSharedLinkCallCount += 1
        lastDeleteSharedLinkId = id
        if let e = globalError ?? deleteSharedLinkError { throw e }
    }

    func updateSharedLink(id: String, dto: SharedLinkEditDto) async throws -> SharedLinkResponseDto {
        bump()
        lastUpdateSharedLinkId = id
        lastUpdateSharedLinkDto = dto
        if let e = globalError ?? sharedLinksError { throw e }
        if let r = updateSharedLinkResponse { return r }
        return SharedLinkResponseDto(
            id: id, description: dto.description, password: dto.password, userId: "owner",
            key: "a2V5", type: .album, createdAt: "2024-01-01T00:00:00.000Z", expiresAt: dto.expiresAt,
            assets: [], album: nil, allowUpload: dto.allowUpload ?? false,
            allowDownload: dto.allowDownload ?? true, showMetadata: dto.showMetadata ?? true,
            slug: dto.slug ?? nil
        )
    }

    func addAssetsToSharedLink(id: String, assetIds: [String]) async throws -> [AssetIdsResponseDto] {
        bump()
        lastAddAssetsSharedLinkId = id
        lastAddAssetsSharedLinkIds = assetIds
        if let e = globalError ?? addAssetsSharedLinkError { throw e }
        return addAssetsSharedLinkResponse
            ?? assetIds.map { AssetIdsResponseDto(assetId: $0, success: true, error: nil) }
    }

    // MARK: - Opening a shared link (issue #22 — visitor side)

    var sharedLinkMineResponse: SharedLinkResponseDto?
    var sharedLinkMineError: Error?
    var sharedLinkLoginResponse: SharedLinkResponseDto?
    var sharedLinkLoginError: Error?
    var sharedLinkAlbumAssetsResponse: SearchResponseDto?
    var sharedLinkAlbumAssetsError: Error?
    /// Result of a guest upload: the id the server assigned (or an error).
    var sharedLinkUploadResponse: AssetMediaResponseDto?
    var sharedLinkUploadError: Error?

    private(set) var sharedLinkMineCredentials: [SharedLinkCredential] = []
    private(set) var sharedLinkLoginCredentials: [SharedLinkCredential] = []
    private(set) var sharedLinkLoginPasswords: [String] = []
    private(set) var sharedLinkAlbumIds: [String] = []
    private(set) var sharedLinkAlbumPages: [Int] = []
    private(set) var sharedLinkUploadCredentials: [SharedLinkCredential] = []
    private(set) var sharedLinkUploadFilenames: [String] = []

    func getSharedLinkMine(_ credential: SharedLinkCredential) async throws -> SharedLinkResponseDto {
        bump()
        sharedLinkMineCredentials.append(credential)
        if let e = globalError ?? sharedLinkMineError { throw e }
        guard let response = sharedLinkMineResponse else { throw APIError.invalidURL }
        return response
    }

    func loginToSharedLink(_ credential: SharedLinkCredential, password: String) async throws -> SharedLinkResponseDto {
        bump()
        sharedLinkLoginCredentials.append(credential)
        sharedLinkLoginPasswords.append(password)
        if let e = globalError ?? sharedLinkLoginError { throw e }
        guard let response = sharedLinkLoginResponse else { throw APIError.invalidURL }
        return response
    }

    func getSharedLinkAlbumAssets(
        _ credential: SharedLinkCredential,
        albumId: String,
        page: Int,
        size: Int
    ) async throws -> SearchResponseDto {
        bump()
        _ = credential
        sharedLinkAlbumIds.append(albumId)
        sharedLinkAlbumPages.append(page)
        if let e = globalError ?? sharedLinkAlbumAssetsError { throw e }
        return sharedLinkAlbumAssetsResponse
            ?? SearchResponseDto(assets: SearchAssetResponseDto(count: 0, items: [], nextPage: nil))
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
        bump()
        _ = (fileURL, fileCreatedAt, fileModifiedAt, checksum, deviceAssetId, deviceId)
        sharedLinkUploadCredentials.append(credential)
        sharedLinkUploadFilenames.append(filename)
        if let e = globalError ?? sharedLinkUploadError { throw e }
        return sharedLinkUploadResponse ?? AssetMediaResponseDto(id: "uploaded", status: "created")
    }

    // MARK: - People (P0 api-surface-expansion)

    func getPeople(page: Int?, withHidden: Bool?) async throws -> PeopleResponseDto {
        bump()
        lastPeoplePage = page
        lastPeopleWithHidden = withHidden
        let call = PeopleCall(page: page, withHidden: withHidden)
        lock.lock(); getPeopleCalls.append(call); lock.unlock()
        if let gate = peopleGate { try await gate(call) }
        if let e = globalError ?? peopleError { throw e }
        if let byPage = peopleResponsesByPage[page ?? 1] { return byPage }
        return peopleResponse ?? PeopleResponseDto(people: [], hidden: 0, total: 0, hasNextPage: nil)
    }

    func updatePerson(id: String, dto: PersonUpdateDto) async throws -> PersonResponseDto {
        bump()
        lastUpdatePersonId = id
        lastUpdatePersonDto = dto
        if let e = globalError ?? peopleError { throw e }
        var person = cannedPerson(id: id)
        if let name = dto.name { person.name = name }
        if let birthDate = dto.birthDate { person.birthDate = birthDate }
        if let isHidden = dto.isHidden { person.isHidden = isHidden }
        if let isFavorite = dto.isFavorite { person.isFavorite = isFavorite }
        return person
    }

    func clearPersonBirthday(id: String) async throws -> PersonResponseDto {
        bump()
        lastClearedPersonBirthdayId = id
        if let e = globalError ?? peopleError { throw e }
        var person = cannedPerson(id: id)
        person.birthDate = nil
        return person
    }

    var lastCreatePersonName: String?

    func createPerson(name: String) async throws -> PersonResponseDto {
        bump()
        lastCreatePersonName = name
        if let e = globalError ?? peopleError { throw e }
        return cannedPerson(id: "person-new", name: name)
    }

    func mergePeople(ids: [String], into id: String) async throws -> [BulkIdResponseDto] {
        bump()
        lastMergePersonIds = ids
        lastMergeTargetId = id
        if let e = globalError ?? peopleError { throw e }
        return mergePeopleResponse ?? ids.map { BulkIdResponseDto(id: $0, success: true, error: nil, errorMessage: nil) }
    }

    func getPersonStatistics(id: String) async throws -> PersonStatisticsResponseDto {
        bump()
        lock.lock(); personStatisticsCalls.append(id); lock.unlock()
        if let e = globalError ?? peopleError { throw e }
        return personStatisticsResponse[id] ?? PersonStatisticsResponseDto(assets: 0)
    }

    // MARK: - Partners (P0 api-surface-expansion; direction required)

    func getPartners(direction: PartnerDirection) async throws -> [PartnerResponseDto] {
        bump()
        lastPartnersDirections.append(direction)
        if let e = globalError ?? partnersError { throw e }
        switch direction {
        case .sharedWith: return partnersSharedWithResponse ?? []
        case .sharedBy: return partnersSharedByResponse ?? []
        }
    }

    func createPartner(sharedWithId: String) async throws -> PartnerResponseDto {
        bump()
        lastCreatePartnerSharedWithId = sharedWithId
        if let e = globalError ?? partnersError { throw e }
        return createPartnerResponse ?? PartnerResponseDto(
            id: sharedWithId, name: "Partner \(sharedWithId)", email: "\(sharedWithId)@test",
            profileImagePath: "", avatarColor: "", profileChangedAt: "2024-01-01T00:00:00.000Z",
            inTimeline: false
        )
    }

    func updatePartner(id: String, isInTimeline: Bool) async throws -> PartnerResponseDto {
        bump()
        lastUpdatePartnerId = id
        lastUpdatePartnerInTimeline = isInTimeline
        if let e = globalError ?? partnersError { throw e }
        return updatePartnerResponse ?? PartnerResponseDto(
            id: id, name: "Partner", email: "partner@test", profileImagePath: "",
            avatarColor: "", profileChangedAt: "2024-01-01T00:00:00.000Z", inTimeline: isInTimeline
        )
    }

    func removePartner(id: String) async throws {
        bump()
        lastRemovePartnerId = id
        if let e = globalError ?? partnersError { throw e }
    }

    // MARK: - Activity (P0 api-surface-expansion)

    func getActivities(albumId: String, assetId: String?) async throws -> [ActivityResponseDto] {
        bump()
        lastActivitiesAlbumId = albumId
        lastActivitiesAssetId = assetId
        if let e = globalError ?? activitiesError { throw e }
        return activitiesResponse ?? []
    }

    func createActivity(dto: ActivityCreateDto) async throws -> ActivityResponseDto {
        bump()
        lastCreateActivityDto = dto
        if let e = globalError ?? activitiesError { throw e }
        if let r = createActivityResponse { return r }
        return ActivityResponseDto(
            id: "act-new", createdAt: "2024-01-01T00:00:00.000Z", type: dto.type,
            user: cannedUser(id: "me"), assetId: dto.assetId, comment: dto.comment
        )
    }

    func deleteActivity(id: String) async throws {
        bump()
        lastDeleteActivityId = id
        if let e = globalError ?? activitiesError { throw e }
    }

    // MARK: - Memories (P0 api-surface-expansion)

    func getMemories() async throws -> [MemoryResponseDto] {
        bump()
        if let e = globalError ?? memoriesError { throw e }
        return memoriesResponse ?? []
    }

    func getMemory(id: String) async throws -> MemoryResponseDto {
        bump()
        lastGetMemoryId = id
        if let e = globalError ?? memoriesError { throw e }
        return memoryDetailResponses[id] ?? MemoryResponseDto(
            id: id, createdAt: "2024-01-01T00:00:00.000Z", updatedAt: "2024-01-01T00:00:00.000Z",
            memoryAt: "2023-06-15T00:00:00.000Z", ownerId: "owner", type: .on_this_day,
            data: OnThisDayDto(year: 2023), assets: [], isSaved: false
        )
    }

    func updateMemory(id: String, dto: MemoryUpdateDto) async throws -> MemoryResponseDto {
        bump()
        lastUpdateMemoryId = id
        lastUpdateMemoryDto = dto
        if let e = globalError ?? memoriesError { throw e }
        if let r = updateMemoryResponse { return r }
        return MemoryResponseDto(
            id: id, createdAt: "2024-01-01T00:00:00.000Z", updatedAt: "2024-01-01T00:00:00.000Z",
            memoryAt: dto.memoryAt ?? "2023-06-15T00:00:00.000Z", ownerId: "owner",
            type: .on_this_day, data: OnThisDayDto(year: 2023), assets: [],
            isSaved: dto.isSaved ?? false
        )
    }

    func deleteMemory(id: String) async throws {
        bump()
        deleteMemoryCallCount += 1
        lastDeleteMemoryId = id
        if let e = globalError ?? memoriesError { throw e }
    }

    func createMemory(dto: MemoryCreateDto) async throws -> MemoryResponseDto {
        bump()
        lastCreateMemoryDto = dto
        if let e = globalError ?? memoriesError { throw e }
        if let r = createMemoryResponse { return r }
        return MemoryResponseDto(
            id: "new-memory", createdAt: "2024-01-01T00:00:00.000Z", updatedAt: "2024-01-01T00:00:00.000Z",
            memoryAt: dto.memoryAt, ownerId: "owner", type: dto.type,
            data: dto.data, assets: [], isSaved: dto.isSaved ?? false
        )
    }

    func addAssetsToMemory(id: String, assetIds: [String]) async throws -> [BulkIdResponseDto] {
        bump()
        lastAddAssetsMemoryId = id
        lastAddAssetsMemoryIds = assetIds
        if let e = globalError ?? memoriesError { throw e }
        return addAssetsMemoryResponse
            ?? assetIds.map { BulkIdResponseDto(id: $0, success: true, error: nil, errorMessage: nil) }
    }

    func removeAssetsFromMemory(id: String, assetIds: [String]) async throws -> [BulkIdResponseDto] {
        bump()
        lastRemoveAssetsMemoryId = id
        lastRemoveAssetsMemoryIds = assetIds
        if let e = globalError ?? memoriesError { throw e }
        return removeAssetsMemoryResponse
            ?? assetIds.map { BulkIdResponseDto(id: $0, success: true, error: nil, errorMessage: nil) }
    }

    func getMemoriesStatistics() async throws -> MemoryStatisticsResponseDto {
        bump()
        if let e = globalError ?? memoriesError { throw e }
        return memoriesStatisticsResponse ?? MemoryStatisticsResponseDto(total: memoriesResponse?.count ?? 0)
    }

    // MARK: - Duplicates (P0 api-surface-expansion)

    func getDuplicates() async throws -> [DuplicateResponseDto] {
        bump()
        if let e = globalError ?? duplicatesError { throw e }
        return duplicatesResponse ?? []
    }

    // MARK: - Server statistics (P0 api-surface-expansion)

    /// Optional suspension point BEFORE the canned response — lets reentrancy
    /// tests hold a load in flight deterministically (statisticsGate).
    var statisticsGate: (() async -> Void)?

    func getServerStatistics() async throws -> ServerStatsResponseDto {
        bump()
        if let gate = statisticsGate { await gate() }
        if let e = globalError ?? sharedLinksError { throw e }
        return serverStatisticsResponse ?? ServerStatsResponseDto(
            photos: 0, videos: 0, usage: 0, usagePhotos: 0, usageVideos: 0, usageByUser: []
        )
    }

    // MARK: - Bulk asset update (P0: archive via visibility)

    func bulkUpdateAssets(dto: AssetBulkUpdateDto) async throws {
        bump()
        lastBulkUpdateDto = dto
        if let e = globalError ?? sharedLinksError { throw e }
    }

    func getUsers() async throws -> [UserResponseDto] {
        bump()
        if let e = globalError ?? getUsersError { throw e }
        return getUsersResponse ?? []
    }

    func getMyUser() async throws -> UserAdminResponseDto {
        bump()
        if let e = globalError ?? getMyUserError { throw e }
        return getMyUserResponse ?? UserAdminResponseDto(
            id: "me", name: "Me Myself", email: "me@example.com",
            profileImagePath: nil, avatarColor: "#123456", profileChangedAt: nil
        )
    }

    // Change password (gap G18)
    /// Body of the last `POST /api/auth/change-password`, recorded before any
    /// canned error is thrown so the request shape is assertable either way.
    var lastChangePasswordBody: ChangePasswordDto?
    var changePasswordResponse: UserAdminResponseDto?
    var changePasswordError: Error?
    /// Optional suspension point before the canned response — lets the
    /// re-entrancy test hold a submit in flight deterministically.
    var changePasswordGate: (() async -> Void)?
    /// `GET /api/users/me` as read by `AuthViewModel` (the profile screen reads
    /// the same route through `getMyUserResponse`).
    var currentUserResponse: UserAdminResponseDto?
    var currentUserError: Error?

    func changePassword(
        currentPassword: String,
        newPassword: String,
        invalidateSessions: Bool
    ) async throws -> UserAdminResponseDto {
        bump()
        lastChangePasswordBody = ChangePasswordDto(
            password: currentPassword,
            newPassword: newPassword,
            invalidateSessions: invalidateSessions
        )
        if let gate = changePasswordGate { await gate() }
        if let e = globalError ?? changePasswordError { throw e }
        return changePasswordResponse ?? UserAdminResponseDto(
            id: "me", name: "Me Myself", email: "me@example.com",
            profileImagePath: nil, avatarColor: "#123456", profileChangedAt: nil,
            shouldChangePassword: false
        )
    }

    func currentUser() async throws -> UserAdminResponseDto {
        bump()
        if let e = globalError ?? currentUserError { throw e }
        return currentUserResponse ?? UserAdminResponseDto(
            id: "me", name: "Me Myself", email: "me@example.com",
            profileImagePath: nil, avatarColor: "#123456", profileChangedAt: nil,
            shouldChangePassword: false
        )
    }

    func uploadProfileImage(
        fileURL: URL,
        filename: String,
        contentType: String
    ) async throws -> CreateProfileImageResponseDto {
        bump()
        lastProfileImageUpload = (filename, contentType, (try? Data(contentsOf: fileURL)) ?? Data())
        if let e = globalError ?? uploadProfileImageError { throw e }
        return uploadProfileImageResponse ?? CreateProfileImageResponseDto(
            userId: "me",
            profileImagePath: "upload/me/profile.jpg",
            profileChangedAt: "2026-09-15T10:00:00.000Z"
        )
    }

    func deleteProfileImage() async throws {
        bump()
        deleteProfileImageCallCount += 1
        if let e = globalError ?? deleteProfileImageError { throw e }
    }

    /// Optional suspension point right after the upload is recorded — lets a test
    /// hold an upload in flight (e.g. a sleep that only a cancellation ends).
    var uploadGate: (() async throws -> Void)?

    func uploadAsset(
        fileURL: URL, fileCreatedAt: String, fileModifiedAt: String, filename: String,
        duration: Int?, isFavorite: Bool, visibility: AssetVisibility, livePhotoVideoId: String?,
        checksum: String, deviceAssetId: String, deviceId: String
    ) async throws -> AssetMediaResponseDto {
        bump()
        lastUploadData = (try? Data(contentsOf: fileURL)) ?? Data()
        lastUploadFileCreatedAt = fileCreatedAt
        lastUploadFileModifiedAt = fileModifiedAt
        lastUploadFilename = filename
        lastUploadDuration = duration
        lastUploadIsFavorite = isFavorite
        lastUploadVisibility = visibility
        lastUploadChecksum = checksum
        lastUploadLivePhotoVideoId = livePhotoVideoId
        lastUploadDeviceAssetId = deviceAssetId
        lastUploadDeviceId = deviceId
        uploads.append((filename: filename, visibility: visibility,
                        livePhotoVideoId: livePhotoVideoId, deviceAssetId: deviceAssetId))
        if let gate = uploadGate { try await gate() }
        if let e = globalError ?? uploadError { throw e }
        if let e = uploadErrorsByFilename[filename] { throw e }
        if let r = uploadResponsesByFilename[filename] { return r }
        return uploadResponse ?? AssetMediaResponseDto(id: "new-asset", status: "created")
    }

    func bulkUploadCheck(_ request: AssetBulkUploadCheckRequest) async throws -> AssetBulkUploadCheckResponse {
        bump()
        bulkUploadCheckChunks.append(request.assets)
        if let e = globalError { throw e }
        return bulkUploadCheckResponse ?? AssetBulkUploadCheckResponse(results: [])
    }

    // MARK: - Faces (gap #5)

    var lastReassignFaceId: String?
    var lastReassignTargetPersonId: String?
    var reassignFaceError: Error?

    func reassignFace(faceId: String, toPersonId: String) async throws -> PersonResponseDto {
        bump()
        lastReassignFaceId = faceId
        lastReassignTargetPersonId = toPersonId
        if let e = globalError ?? reassignFaceError { throw e }
        return cannedPerson(id: toPersonId)
    }

    var facesResponse: [AssetFaceResponseDto]?
    var lastGetFacesAssetId: String?

    func getFaces(assetId: String) async throws -> [AssetFaceResponseDto] {
        bump()
        lastGetFacesAssetId = assetId
        if let e = globalError ?? reassignFaceError { throw e }
        return facesResponse ?? []
    }

    // MARK: - OCR (gap #8, ocr-text)

    var lastGetAssetOcrId: String?
    var ocrByAssetId: [String: [AssetOcrResponseDto]] = [:]
    var ocrError: Error?

    func getAssetOcr(id: String) async throws -> [AssetOcrResponseDto] {
        bump()
        lastGetAssetOcrId = id
        return try errorToThrow(ocrByAssetId[id] ?? [], ocrError ?? globalError)
    }

    /// Throws the injected error when one is set, else returns `value`.
    private func errorToThrow<T>(_ value: T, _ error: Error?) throws -> T {
        if let error { throw error }
        return value
    }

    // MARK: - Tags (gap #2)

    var tagsResponse: [TagResponseDto]?
    var tagsError: Error?
    var lastCreateTagName: String?
    var lastUpdateTagId: String?
    var lastDeleteTagId: String?
    var lastTagAssetsTagId: String?
    var lastTagAssetsIds: [String]?
    var lastUntagAssetsTagId: String?
    var lastUntagAssetsIds: [String]?

    func getAllTags() async throws -> [TagResponseDto] {
        bump()
        if let e = globalError ?? tagsError { throw e }
        return tagsResponse ?? []
    }

    func createTag(name: String, color: String?) async throws -> TagResponseDto {
        bump()
        lastCreateTagName = name
        if let e = globalError ?? tagsError { throw e }
        return TagResponseDto(id: "tag-new", name: name, value: name, color: color)
    }

    func updateTag(id: String, color: String?) async throws -> TagResponseDto {
        bump()
        lastUpdateTagId = id
        if let e = globalError ?? tagsError { throw e }
        return TagResponseDto(id: id, name: "Tag", value: "Tag", color: color)
    }

    func deleteTag(id: String) async throws {
        bump()
        lastDeleteTagId = id
        if let e = globalError ?? tagsError { throw e }
    }

    func tagAssets(tagId: String, assetIds: [String]) async throws {
        bump()
        lastTagAssetsTagId = tagId
        lastTagAssetsIds = assetIds
        if let e = globalError ?? tagsError { throw e }
    }

    func untagAssets(tagId: String, assetIds: [String]) async throws {
        bump()
        lastUntagAssetsTagId = tagId
        lastUntagAssetsIds = assetIds
        if let e = globalError ?? tagsError { throw e }
    }

    // MARK: - Stacks (gap #1)

    var stacksResponse: [StackResponseDto]?
    /// Per-id answers for `getStack` (falls back to an empty stack).
    var stackDetailResponses: [String: StackResponseDto] = [:]
    var createStackResponse: StackResponseDto?
    var updateStackResponse: StackResponseDto?
    var lastCreateStackIds: [String]?
    var lastUpdateStackId: String?
    var lastUpdateStackPrimaryId: String?
    var lastDeleteStackId: String?
    var lastRemoveFromStackId: String?
    var lastRemoveFromStackAssetId: String?
    var stacksError: Error?

    func searchStacks(primaryAssetId: String?) async throws -> [StackResponseDto] {
        bump()
        if let e = globalError ?? stacksError { throw e }
        return stacksResponse ?? []
    }

    func createStack(assetIds: [String]) async throws -> StackResponseDto {
        bump()
        lastCreateStackIds = assetIds
        if let e = globalError ?? stacksError { throw e }
        return createStackResponse ?? StackResponseDto(id: "stack-new", primaryAssetId: assetIds.first ?? "", assets: [])
    }

    func getStack(id: String) async throws -> StackResponseDto {
        bump()
        if let e = globalError ?? stacksError { throw e }
        return stackDetailResponses[id] ?? StackResponseDto(id: id, primaryAssetId: "", assets: [])
    }

    func updateStack(id: String, primaryAssetId: String?) async throws -> StackResponseDto {
        bump()
        lastUpdateStackId = id
        lastUpdateStackPrimaryId = primaryAssetId
        if let e = globalError ?? stacksError { throw e }
        return updateStackResponse ?? StackResponseDto(id: id, primaryAssetId: primaryAssetId ?? "", assets: [])
    }

    func deleteStack(id: String) async throws {
        bump()
        lastDeleteStackId = id
        if let e = globalError ?? stacksError { throw e }
    }

    func removeAssetFromStack(stackId: String, assetId: String) async throws {
        bump()
        lastRemoveFromStackId = stackId
        lastRemoveFromStackAssetId = assetId
        if let e = globalError ?? stacksError { throw e }
    }

    // MARK: - Admin (gap #12)

    var adminUsersResponse: [UserAdminResponseDto]?
    var lastCreateAdminUserDto: UserAdminCreateDto?
    var lastUpdateAdminUserId: String?
    var lastUpdateAdminUserDto: UserAdminUpdateDto?
    var lastDeleteAdminUserId: String?
    var lastDeleteAdminUserForce: Bool?
    var lastRestoreAdminUserId: String?
    var jobsStatusResponse: [String: QueueResponseLegacyDto]?
    var lastJobCommandName: String?
    var lastJobCommand: String?
    var librariesResponse: [LibraryResponseDto]?
    var lastScanLibraryId: String?
    var lastDeleteLibraryId: String?
    var apiKeysResponse: [ApiKeyResponseDto]?
    var lastCreateApiKeyName: String?
    var lastCreateApiKeyPermissions: [String]?
    var lastDeleteApiKeyId: String?
    /// `GET /api/api-keys/me` — the singular key that carries the request.
    var myAPIKeyResponse: ApiKeyResponseDto?
    var apiKeyCreateResponse: ApiKeyCreateResponseDto?
    var apiKeyRotateResponse: ApiKeyCreateResponseDto?
    var lastRotateApiKeyId: String?
    var adminError: Error?

    func getAdminUsers() async throws -> [UserAdminResponseDto] {
        bump()
        if let e = globalError ?? adminError { throw e }
        return adminUsersResponse ?? []
    }

    func createAdminUser(dto: UserAdminCreateDto) async throws -> UserAdminResponseDto {
        bump()
        lastCreateAdminUserDto = dto
        if let e = globalError ?? adminError { throw e }
        return UserAdminResponseDto(id: "u-new", name: dto.name, email: dto.email)
    }

    func updateAdminUser(id: String, dto: UserAdminUpdateDto) async throws -> UserAdminResponseDto {
        bump()
        lastUpdateAdminUserId = id
        lastUpdateAdminUserDto = dto
        if let e = globalError ?? adminError { throw e }
        return UserAdminResponseDto(id: id, name: dto.name ?? "", email: dto.email ?? "")
    }

    func deleteAdminUser(id: String, force: Bool) async throws -> UserAdminResponseDto {
        bump()
        lastDeleteAdminUserId = id
        lastDeleteAdminUserForce = force
        if let e = globalError ?? adminError { throw e }
        return UserAdminResponseDto(id: id, name: "", email: "")
    }

    func restoreAdminUser(id: String) async throws -> UserAdminResponseDto {
        bump()
        lastRestoreAdminUserId = id
        if let e = globalError ?? adminError { throw e }
        return UserAdminResponseDto(id: id, name: "", email: "")
    }

    func getJobsStatus() async throws -> [String: QueueResponseLegacyDto] {
        bump()
        if let e = globalError ?? adminError { throw e }
        return jobsStatusResponse ?? [:]
    }

    func sendJobCommand(name: String, command: String, force: Bool?) async throws -> QueueResponseLegacyDto {
        bump()
        lastJobCommandName = name
        lastJobCommand = command
        if let e = globalError ?? adminError { throw e }
        return QueueResponseLegacyDto(
            queueStatus: QueueStatusLegacyDto(isActive: false, isPaused: false),
            jobCounts: QueueStatisticsDto(active: 0, completed: 0, failed: 0, delayed: 0, waiting: 0, paused: 0)
        )
    }

    func getLibraries() async throws -> [LibraryResponseDto] {
        bump()
        if let e = globalError ?? adminError { throw e }
        return librariesResponse ?? []
    }

    func scanLibrary(id: String) async throws {
        bump()
        lastScanLibraryId = id
        if let e = globalError ?? adminError { throw e }
    }

    func deleteLibrary(id: String) async throws {
        bump()
        lastDeleteLibraryId = id
        if let e = globalError ?? adminError { throw e }
    }

    func getAPIKeys() async throws -> [ApiKeyResponseDto] {
        bump()
        if let e = globalError ?? adminError { throw e }
        return apiKeysResponse ?? []
    }

    func createAPIKey(name: String, permissions: [String]) async throws -> ApiKeyCreateResponseDto {
        bump()
        lastCreateApiKeyName = name
        lastCreateApiKeyPermissions = permissions
        if let e = globalError ?? adminError { throw e }
        return apiKeyCreateResponse ?? ApiKeyCreateResponseDto(
            secret: "secret",
            apiKey: ApiKeyResponseDto(id: "key-new", name: name)
        )
    }

    func getMyAPIKey() async throws -> ApiKeyResponseDto {
        bump()
        if let e = globalError ?? adminError { throw e }
        return myAPIKeyResponse ?? ApiKeyResponseDto(id: "key-me", name: "session")
    }

    func rotateAPIKey(id: String) async throws -> ApiKeyCreateResponseDto {
        bump()
        lastRotateApiKeyId = id
        if let e = globalError ?? adminError { throw e }
        return apiKeyRotateResponse ?? ApiKeyCreateResponseDto(
            secret: "rotated",
            apiKey: ApiKeyResponseDto(id: id, name: "rotated")
        )
    }

    func deleteAPIKey(id: String) async throws {
        bump()
        lastDeleteApiKeyId = id
        if let e = globalError ?? adminError { throw e }
    }

    // MARK: - Connected devices (gap G19)

    /// `GET /api/sessions` answer. `nil` means "the account has no session",
    /// which is not a state the server produces but is the honest empty value.
    var sessionsResponse: [SessionResponseDto]?
    var sessionsError: Error?
    var deleteSessionError: Error?
    var deleteAllSessionsError: Error?
    /// Every id the single-session DELETE was called with, in order.
    private(set) var deletedSessionIDs: [String] = []
    private(set) var deleteAllSessionsCallCount = 0

    func getSessions() async throws -> [SessionResponseDto] {
        bump()
        if let e = globalError ?? sessionsError { throw e }
        return sessionsResponse ?? []
    }

    func deleteSession(id: String) async throws {
        bump()
        deletedSessionIDs.append(id)
        if let e = globalError ?? deleteSessionError { throw e }
    }

    func deleteAllSessions() async throws {
        bump()
        deleteAllSessionsCallCount += 1
        if let e = globalError ?? deleteAllSessionsError { throw e }
    }

    // MARK: - Download queue (gap G10)

    var downloadInfoResponse = DownloadInfoResponse(totalSize: 0, archives: [])
    var downloadInfoError: Error?
    private(set) var lastDownloadInfoAssetIds: [String]?
    private(set) var lastDownloadInfoAlbumId: String?
    var originalRequestError: Error?
    private(set) var lastOriginalRequestAssetId: String?
    var downloadArchiveRequestError: Error?
    private(set) var lastArchiveName: String?
    private(set) var lastArchiveAssetIds: [String]?
    private(set) var lastArchiveEdited: Bool?
    /// The download endpoints in call order: the batch contract is an ORDER
    /// (`download/info` before `download/archive`), which a "was it called"
    /// flag cannot express.
    private(set) var downloadCallOrder: [String] = []

    func downloadInfo(assetIds: [String], albumId: String?) async throws -> DownloadInfoResponse {
        bump()
        downloadCallOrder.append("info")
        lastDownloadInfoAssetIds = assetIds
        lastDownloadInfoAlbumId = albumId
        if let e = globalError ?? downloadInfoError { throw e }
        return downloadInfoResponse
    }

    func originalRequest(assetId: String) throws -> URLRequest {
        downloadCallOrder.append("original")
        lastOriginalRequestAssetId = assetId
        if let e = originalRequestError { throw e }
        return URLRequest(url: URL(string: "https://example.com/api/assets/\(assetId)/original")!)
    }

    func downloadArchiveRequest(archiveName: String, assetIds: [String], edited: Bool) throws -> URLRequest {
        downloadCallOrder.append("archive")
        lastArchiveName = archiveName
        lastArchiveAssetIds = assetIds
        lastArchiveEdited = edited
        if let e = downloadArchiveRequestError { throw e }
        return URLRequest(url: URL(string: "https://example.com/api/download/archive")!)
    }
}
