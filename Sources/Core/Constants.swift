import Foundation

/// API path constants and helpers shared across the app.
enum ImmichAPI {
    static let apiPath = "/api"

    static let auth = SubPath(root: "/auth")
    // OAuth lives on its own controller, not under /auth (Immich open-api spec).
    static let oauthAuthorize = SubPath(root: "/oauth/authorize") // P5 oauth
    static let oauthCallback = SubPath(root: "/oauth/callback") // P5 oauth
    static let server = SubPath(root: "/server")
    static let assets = SubPath(root: "/assets")
    static let timeline = SubPath(root: "/timeline")
    static let trash = SubPath(root: "/trash") // AC-311
    static let search = SubPath(root: "/search") // AC-400
    static let view = SubPath(root: "/view") // gap G11 (folder view)
    static let map = SubPath(root: "/map") // AC-710 (MapKit markers)
    static let people = SubPath(root: "/people") // AC-400 (deferred People feature)
    static let faces = SubPath(root: "/faces") // gap #5 (face reassignment)
    static let albums = SubPath(root: "/albums") // AC-500
    static let tags = SubPath(root: "/tags") // gap #2 (asset tags)
    static let sharedLinks = SubPath(root: "/shared-links") // AC-500
    static let users = SubPath(root: "/users") // photo share — user picker
    static let partners = SubPath(root: "/partners") // P0 api-surface-expansion
    static let activity = SubPath(root: "/activities") // P0 api-surface-expansion
    static let memories = SubPath(root: "/memories") // P0 api-surface-expansion
    static let duplicates = SubPath(root: "/duplicates") // P0 api-surface-expansion
    static let stacks = SubPath(root: "/stacks") // gap #1 (asset stacking)
    static let admin = SubPath(root: "/admin") // gap #12 (admin panel)
    static let jobs = SubPath(root: "/jobs") // gap #12 (admin jobs, deprecated since v2.4.0)
    static let queues = SubPath(root: "/queues") // replaces /jobs from v2.4.0
    static let publicConfig = SubPath(root: "/public/config") // replaces GET /server/config (no auth) from v3.2.0
    static let userConfig = SubPath(root: "/config") // authenticated config, from v3.2.0
    static let libraries = SubPath(root: "/libraries") // gap #12 (admin libraries)
    static let apiKeys = SubPath(root: "/api-keys") // gap #12 (admin api keys)
    /// Connected devices (gap G19). Exactly `/sessions`: the two elevation
    /// routes live under `/auth/session/*` and belong to `ImmichAPI.auth`.
    static let sessions = SubPath(root: "/sessions")

    struct SubPath {
        let root: String
        func path(_ suffix: String) -> String { apiPath + root + suffix }
    }

    /// Header used for SHA1 checksum dedup on uploads + bulk-upload-check.
    static let checksumHeader = "x-immich-checksum"
}

/// Server version at which a replacement route appears (OpenAPI `x-immich-history`).
/// A replacement is used only when the routing version is known and at least
/// the threshold; an unknown version keeps the legacy route (L-20).
enum ImmichRouteThreshold {
    static let queues = ServerVersionResponseDto(major: 2, minor: 4, patch: 0, prerelease: nil)
    static let config = ServerVersionResponseDto(major: 3, minor: 2, patch: 0, prerelease: nil)
    static let peopleMerge = ServerVersionResponseDto(major: 3, minor: 2, patch: 1, prerelease: nil)
}

extension Optional where Wrapped == ServerVersionResponseDto {
    /// True when the version is known and `>= threshold` (`prerelease` ignored).
    func serves(_ threshold: ServerVersionResponseDto) -> Bool {
        guard let self else { return false }
        return self.isAtLeast(major: threshold.major, minor: threshold.minor, patch: threshold.patch)
    }
}

enum ImmichHeader {
    static let authorization = "Authorization"
    static let contentType = "Content-Type"
    static let accept = "Accept"
    static let checksum = "x-immich-checksum"
    static let cookie = "Cookie"
    static let userToken = ServerRequestAuthorization.userTokenHeader
}

/// Cookie names the server sets — mirrors `ImmichCookie` in
/// `server/src/enum.ts`. Only the shared-link one concerns the app: the
/// auth-token cookie belongs to the web client.
enum ImmichCookie {
    /// Session cookie of a password-protected shared link, returned by
    /// `POST /api/shared-links/login` and required by `GET /api/shared-links/me`
    /// for the rest of the visit.
    static let sharedLinkToken = "immich_shared_link_token"
}

enum AssetMediaSize: String {
    case thumbnail
    case preview
    case fullsize
}

enum AssetVisibility: String, Codable, CaseIterable, Sendable {
    case archive
    case timeline
    case hidden
    case locked
}

enum AssetType: String, Codable, Sendable {
    case image = "IMAGE"
    case video = "VIDEO"
    case audio = "AUDIO"
    case other = "OTHER"
}

enum AssetOrder: String, Codable, Sendable {
    case asc
    case desc
}

enum AssetOrderBy: String, Codable, Sendable {
    case takenAt
    case createdAt
}
