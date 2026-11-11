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
    let assets: [SharedLinkAssetDto]
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

// MARK: - Visitor side: photos as a link hands them out

/// Duration of a photo of a shared link, in milliseconds.
///
/// Wire format by server version (checked on `server/src/dtos/asset-response.dto.ts`):
/// v3.x sends an int32 of milliseconds (null for a still); v2.x sends a *string*
/// (`"0:00:00.00000"` for a still, never null, or the raw string of the EXIF
/// tool). Decoding **never throws on the content**: a value that cannot be read
/// is "no duration" — a link must not fail to open over a badge label.
struct SharedLinkAssetDuration: Codable, Equatable {
    let milliseconds: Int?

    init(milliseconds: Int?) {
        self.milliseconds = milliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            milliseconds = value >= 0 ? value : nil
        } else if let value = try? container.decode(Double.self) {
            milliseconds = value.isFinite && value >= 0 && value <= Double(Int32.max)
                ? Int(value.rounded()) : nil
        } else if let text = try? container.decode(String.self) {
            milliseconds = Self.milliseconds(fromServerText: text)
        } else {
            milliseconds = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let milliseconds {
            try container.encode(milliseconds)
        } else {
            try container.encodeNil()
        }
    }

    /// `"H:MM:SS[.fff]"` (hours and minutes digits only, seconds digits with an
    /// optional fraction, no sign) → milliseconds; nil for anything else or above
    /// `Int32.max` (the v3 bound).
    static func milliseconds(fromServerText text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        func digits(_ part: Substring) -> Bool {
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
        let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard digits(parts[0]), digits(parts[1]),
              secondParts.count <= 2, digits(secondParts[0]),
              secondParts.count == 1 || digits(secondParts[1]),
              let hours = Double(parts[0]), let minutes = Double(parts[1]),
              let seconds = Double(parts[2])
        else { return nil }
        let total = ((hours * 3600 + minutes * 60) + seconds) * 1000
        guard total.isFinite, total <= Double(Int32.max) else { return nil }
        return Int(total.rounded())
    }
}

/// A photo as a shared link hands it to the visitor — full or reduced form, any
/// server version. Serves **only** the photos of a link (`SharedLinkResponseDto.assets`,
/// the album search of a link): `AssetResponseDto` keeps its required fields and
/// every other screen keeps refusing an incomplete record.
///
/// - v2.0.0: reduced = `id, type, thumbhash, originalMimeType, localDateTime,
///   duration (string), livePhotoVideoId, hasMetadata`; no `width`/`height`.
/// - v2.7.5: same with `width`/`height` (nullable). The album search of a v2.x
///   server answers the **full** form even for a link that hides metadata.
/// - v3.x: reduced = the ten keys of `SanitizedAssetResponseDto`, duration in ms.
///
/// The fields a link may hide are optional here and read as absent: no stand-in
/// value is made up at this level.
struct SharedLinkAssetDto: Codable, Equatable {
    let id: String
    let type: String
    // Sent in both forms.
    var thumbhash: String?
    var duration: SharedLinkAssetDuration?
    var hasMetadata: Bool?
    var livePhotoVideoId: String?
    /// Absent from the reduced form and before v2.5.0.
    var isEdited: Bool?
    // Hidden by the server when the link hides metadata.
    var originalFileName: String?
    var originalPath: String?
    var ownerId: String?
    var createdAt: String?
    var fileCreatedAt: String?
    var fileModifiedAt: String?
    var updatedAt: String?
    var isFavorite: Bool?
    var isArchived: Bool?
    var isTrashed: Bool?
    var isOffline: Bool?
    var visibility: String?
    var checksum: String?
    var exifInfo: ExifResponseDto?

    var durationMilliseconds: Int? { duration?.milliseconds }
}

/// `POST /api/search/metadata` as a link visitor uses it (photos of an album
/// link): only `assets.items` and `assets.nextPage` are read.
struct SharedLinkAlbumAssetsResponseDto: Codable, Equatable {
    let assets: Page

    struct Page: Codable, Equatable {
        let items: [SharedLinkAssetDto]
        let nextPage: String?

        enum CodingKeys: String, CodingKey { case items, nextPage }
    }

    enum CodingKeys: String, CodingKey { case assets }
}
