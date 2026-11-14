import Foundation

// MARK: - People DTOs (P0 api-surface-expansion)

/// `PersonResponseDto` — full schema verified against OpenAPI (main branch).
///
/// Replaces the stale minimal definition previously in DTOs.swift.
struct PersonResponseDto: Codable, Equatable, Hashable, Identifiable {
    let id: String
    var name: String
    var birthDate: String?
    var thumbnailPath: String?
    var isHidden: Bool
    var color: String?
    var isFavorite: Bool?
    var updatedAt: String?
}

/// `GET /api/people`
struct PeopleResponseDto: Codable, Equatable {
    let people: [PersonResponseDto]
    let hidden: Int
    let total: Int
    var hasNextPage: Bool?
}

/// `PUT /api/people/{id}` — all fields optional, only provided fields are updated.
struct PersonUpdateDto: Codable, Equatable {
    var name: String?
    var birthDate: String?
    var color: String?
    var featureFaceAssetId: String?
    var isFavorite: Bool?
    var isHidden: Bool?
}

/// Body of the birthday-clear call (`PUT /api/people/{id}`).
///
/// `PersonUpdateDto` **cannot** express "set `birthDate` to null": Swift's
/// synthesized `encode(to:)` writes optional properties with `encodeIfPresent`,
/// so `PersonUpdateDto(birthDate: nil)` emits a body with no `birthDate` key at
/// all — the server has nothing to update and the birthday silently stays put.
/// The OpenAPI schema declares the field `nullable: true`, so an explicit
/// `null` is the only accepted clear (`""` is rejected by `format: date`), and
/// this single-field body is the only way to send one.
///
/// Mono-field by construction: it can never overwrite `name`, `color`,
/// `featureFaceAssetId`, `isFavorite` or `isHidden`.
struct PersonBirthdayClearDto: Encodable {
    enum CodingKeys: String, CodingKey { case birthDate }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .birthDate)
    }
}

/// `POST /api/people` — create a new person.
struct PersonCreateDto: Codable, Equatable {
    var name: String
    var birthDate: String?
    var isHidden: Bool?
    var isFavorite: Bool?
    var color: String?
}

/// `POST /api/people/{id}/merge` (legacy, `ids` = sources) or `POST /api/people/merge`
/// (v3.2.1+, `ids` = target first, then sources) — note: POST, not PUT.
struct MergePersonDto: Codable, Equatable {
    let ids: [String]
}

/// `GET /api/people/{id}/statistics`
struct PersonStatisticsResponseDto: Codable, Equatable {
    let assets: Int
}

/// `GET /api/partners`
struct PartnerResponseDto: Codable, Equatable {
    let id: String
    let name: String
    let email: String
    let profileImagePath: String
    let avatarColor: String
    let profileChangedAt: String
    let inTimeline: Bool
}

/// `PUT /api/partners/{id}` — `inTimeline` is required by the server.
struct PartnerUpdateDto: Codable, Equatable {
    let inTimeline: Bool
}

/// Which side of the partner relation a query asks about.
///
/// The direction is the side **the current user sits on**, and the server
/// always returns the *other* user of the pair (`PartnerService.search` →
/// `mapPartner`):
/// - `sharedBy` — rows where `sharedById == me`, so the response carries the
///   people **I** added ("Sharing").
/// - `sharedWith` — rows where `sharedWithId == me`, so the response carries
///   the people who share **their** library with me ("Shared with me").
enum PartnerDirection: String, Codable, Equatable {
    case sharedBy = "shared-by"
    case sharedWith = "shared-with"
}

/// `POST /api/partners` — the server takes a **user id**, not an email
/// (`PartnerCreateDto`, `server/src/dtos/partner.dto.ts`).
struct PartnerCreateDto: Codable, Equatable {
    let sharedWithId: String
}

// MARK: - Faces (gap #5)

/// A single detected face on an asset (`AssetFaceResponseDto`).
struct AssetFaceResponseDto: Codable, Equatable, Identifiable {
    let id: String
    let person: PersonResponseDto?
    let boundingBoxX1: Int
    let boundingBoxX2: Int
    let boundingBoxY1: Int
    let boundingBoxY2: Int
    let imageHeight: Int
    let imageWidth: Int
    var sourceType: String?
}

/// `FaceDto` — body of `PUT /api/faces/{personId}` (re-assign a face).
struct FaceDto: Codable, Equatable {
    let id: String
}