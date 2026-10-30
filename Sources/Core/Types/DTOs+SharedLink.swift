import Foundation

// MARK: - Shared Links (AC-500..AC-518)
//
// Source: github.com/immich-app/immich server/src/dtos/shared-link.dto.ts

/// `SharedLinkType` enum — ALBUM shares a whole album, INDIVIDUAL shares
/// a set of standalone assets.
enum SharedLinkType: String, Codable, Sendable {
    case album = "ALBUM"
    case individual = "INDIVIDUAL"
}

/// `SharedLinkCreateDto` body for `POST /api/shared-links`.
/// `type` is required; `albumId` (ALBUM) or `assetIds` (INDIVIDUAL) provides
/// the shared content. Optional permission booleans default server-side
/// (`allowUpload ?? true`, `allowDownload ?? true`).
///
/// `slug` is the custom URL slug ("Custom URL slug" in the OpenAPI): when set,
/// the link's public URL becomes `…/s/<slug>` instead of `…/share/<key>`.
struct SharedLinkCreateDto: Codable, Equatable {
    let type: SharedLinkType
    let albumId: String?
    let assetIds: [String]?
    let description: String?
    let password: String?
    let expiresAt: String?
    let allowUpload: Bool?
    let allowDownload: Bool?
    let showMetadata: Bool?
    let slug: String?

    init(
        type: SharedLinkType,
        albumId: String? = nil,
        assetIds: [String]? = nil,
        description: String? = nil,
        password: String? = nil,
        expiresAt: String? = nil,
        allowUpload: Bool? = nil,
        allowDownload: Bool? = nil,
        showMetadata: Bool? = nil,
        slug: String? = nil
    ) {
        self.type = type
        self.albumId = albumId
        self.assetIds = assetIds
        self.description = description
        self.password = password
        self.expiresAt = expiresAt
        self.allowUpload = allowUpload
        self.allowDownload = allowDownload
        self.showMetadata = showMetadata
        self.slug = slug
    }
}

/// `SharedLinkResponseDto` from `GET /api/shared-links` and `POST /api/shared-links`.
/// `password` is returned by the server (nullable) — MUST NOT be displayed in UI
/// (VM-J manual). `album`/`assets` are inlined by the server.
struct SharedLinkResponseDto: Codable, Equatable {
    let id: String
    let description: String?
    let password: String?
    let userId: String
    let key: String
    let type: SharedLinkType
    let createdAt: String
    let expiresAt: String?
    let assets: [AssetResponseDto]
    let album: AlbumResponseDto?
    let allowUpload: Bool
    let allowDownload: Bool
    let showMetadata: Bool
    let slug: String?

    enum CodingKeys: String, CodingKey {
        case id, description, password, userId, key, type
        case createdAt, expiresAt, assets, album
        case allowUpload, allowDownload, showMetadata, slug
    }
}

// MARK: - Shared link assets (owner-side)

/// `AssetIdsDto` — body of `PUT /api/shared-links/{id}/assets`.
/// Note the field name: this route takes `assetIds`, where the album routes
/// take `ids` (`BulkIdsDto`).
struct AssetIdsDto: Codable, Equatable {
    let assetIds: [String]
}

/// Error reason of `AssetIdsResponseDto`. The server enum is `@deprecated` in
/// favour of `BulkIdErrorReason`, but this route serialises the same lowercase
/// strings; only the field name (`assetId` here, `id` there) and the absence
/// of `validation` tell the two apart.
enum AssetIdErrorReason: String, Codable, Equatable {
    case duplicate
    case noPermission = "no_permission"
    case notFound = "not_found"
}

/// `AssetIdsResponseDto` — per-asset result of `PUT /api/shared-links/{id}/assets`.
/// `error` is present only on failure. Field is `assetId`, not `id`: this is
/// NOT `BulkIdResponseDto`.
struct AssetIdsResponseDto: Codable, Equatable {
    let assetId: String
    let success: Bool
    let error: AssetIdErrorReason?
}

// MARK: - Visitor side (issue #22 — opening a link someone sent you)

/// How a visitor addresses a shared link on the wire: `?key=<base64url>` for
/// the random key the server generated, `?slug=<slug>` for the custom slug the
/// owner chose.
///
/// One enum instead of two optionals because the server accepts **either** and
/// reads the key first (`AuthService.validate`: `query.key` → `validateSharedLinkKey`,
/// else `query.slug` → `validateSharedLinkSlug`) — a request carrying both or
/// neither has no meaning, so the type refuses to express it.
enum SharedLinkCredential: Equatable, Sendable, Hashable {
    case key(String)
    case slug(String)

    /// The `key` / `slug` query item every visitor request carries — the
    /// credential never travels in a header (`ImmichHeader.SharedLinkKey`
    /// exists server-side, but the query is what the web client uses).
    var queryItem: URLQueryItem {
        switch self {
        case .key(let value): URLQueryItem(name: "key", value: value)
        case .slug(let value): URLQueryItem(name: "slug", value: value)
        }
    }
}

/// `SharedLinkLoginDto` — body of `POST /api/shared-links/login`.
struct SharedLinkLoginDto: Codable, Equatable {
    let password: String
}
