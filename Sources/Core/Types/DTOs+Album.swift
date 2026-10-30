import Foundation

// MARK: - Albums (AC-500..AC-518)
//
// Source: github.com/immich-app/immich server/src/dtos/album.dto.ts
// Note: AlbumResponseDto does NOT include an `assets` array (only `assetCount`).
// Album assets are fetched separately via searchMetadata(albumIds:) — see FM-2.

/// `AlbumResponseDto` from `GET /api/albums` and `GET /api/albums/:id`.
/// `albumUsers` is always present server-side (owner first). Explicit CodingKeys
/// keeps decoding resilient to server-side field additions.
struct AlbumResponseDto: Codable, Equatable {
    let id: String
    var albumName: String
    var description: String
    let createdAt: String
    let updatedAt: String
    var albumThumbnailAssetId: String?
    let shared: Bool
    let hasSharedLink: Bool
    let assetCount: Int
    var isActivityEnabled: Bool
    let order: AssetOrder?
    var albumUsers: [AlbumUserResponseDto] = []

    enum CodingKeys: String, CodingKey {
        case id, albumName, description, createdAt, updatedAt
        case albumThumbnailAssetId, shared, hasSharedLink, assetCount
        case isActivityEnabled, order, albumUsers
    }
}

/// `CreateAlbumDto` body for `POST /api/albums`.
/// Optional fields are omitted from JSON when nil (synthesized Codable behavior).
/// `albumUsers` (Immich ≥ 1.109) creates the album pre-shared with those users.
struct CreateAlbumDto: Codable, Equatable {
    let albumName: String
    let description: String?
    let assetIds: [String]?
    var albumUsers: [AlbumUserDto]? = nil
}

/// `AlbumUserRole` — collaborator role in a shared album.
/// Raw values are LOWERCASE per the Immich wire contract
/// (`server/src/enum.ts` — `AlbumUserRole = { Editor: 'editor', Owner: 'owner', Viewer: 'viewer' }`).
enum AlbumUserRole: String, Codable, Equatable, Sendable {
    case owner = "owner"
    case editor = "editor"
    case viewer = "viewer"
}

/// `AlbumUserDto` — a user + role attached to an album (shared albums).
struct AlbumUserDto: Codable, Equatable, Sendable {
    let userId: String
    let role: AlbumUserRole
}

/// `AlbumUserResponseDto` — collaborator entry inside `AlbumResponseDto.albumUsers`.
struct AlbumUserResponseDto: Codable, Equatable, Sendable {
    let user: UserResponseDto
    let role: AlbumUserRole
}

/// `UpdateAlbumDto` body for `PATCH /api/albums/:id`. Optional fields are
/// omitted from JSON when nil (synthesized Codable). Covers cover changes via
/// `albumThumbnailAssetId`; user management uses the dedicated user endpoints.
struct UpdateAlbumDto: Codable, Equatable {
    let albumName: String?
    let description: String?
    let albumThumbnailAssetId: String?
    let isActivityEnabled: Bool?
    let order: AssetOrder?
}

/// `AddUsersDto` body for `PUT /api/albums/:id/users`.
struct AddUsersDto: Codable, Equatable {
    let albumUsers: [AlbumUserDto]
}

/// `UpdateAlbumUserDto` body for `PUT /api/albums/:id/user/:userId`.
struct UpdateAlbumUserDto: Codable, Equatable {
    let role: AlbumUserRole
}

/// `BulkIdResponseDto` — per-asset result for bulk add/remove album assets.
/// `error` and `errorMessage` are present only on failure.
///
/// The server emits lowercase values (`duplicate`, `no_permission`,
/// `not_found`, `unknown`, plus `validation` since v3). Decoding is
/// case-insensitive and any unrecognised value becomes `.unknown`, so one
/// failed entry never fails the whole `[BulkIdResponseDto]` array.
enum BulkIdErrorReason: String, Codable, Equatable {
    case duplicate = "duplicate"
    case noPermission = "no_permission"
    case notFound = "not_found"
    case unknown = "unknown"
    case validation = "validation"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BulkIdErrorReason(rawValue: raw.lowercased()) ?? .unknown
    }
}

struct BulkIdResponseDto: Codable, Equatable {
    let id: String
    let success: Bool
    let error: BulkIdErrorReason?
    let errorMessage: String?
}
