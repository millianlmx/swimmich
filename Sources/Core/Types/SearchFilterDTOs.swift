import Foundation

// MARK: - Search filter DTOs (v3.2.0 structured filters)

/// `StringSimilarityFilter` — a text field matched by **similarity** (trigram /
/// full-text search), not by equality.
///
/// The server declares `additionalProperties: false` on the schema, so this
/// mirrors exactly what the OpenAPI publishes and nothing more.
struct StringSimilarityFilterDto: Codable, Equatable {
    var matches: String
}

/// `StringFilterNullable` — the operator set of the nullable string filters
/// (`city`, `state`, `country`, `make`, `model`, `lensModel`).
///
/// The sub-filters of `SearchFilter` are `nonEmptyPartial` server-side: a
/// sub-filter with no operator is rejected ("At least one of the following
/// fields is required"), which is why a projection writes at least one.
struct StringFilterNullableDto: Codable, Equatable {
    var eq: String?
    var ne: String?
    var `in`: [String]?
    var notIn: [String]?
}

/// `NumberFilterNullable` — the operator set of `SearchFilter.rating`.
///
/// `eq`/`ne` are nullable in the contract ("null for unrated"); the app only
/// writes `eq`, because the flat `rating` field it replaces cannot express
/// "unrated" either (a `nil` `Int?` leaves the body instead of sending `null`).
struct NumberFilterNullableDto: Codable, Equatable {
    var eq: Double?
    var ne: Double?
    var lt: Double?
    var lte: Double?
    var gt: Double?
    var gte: Double?
    var `in`: [Double]?
    var notIn: [Double]?
}

/// `DateFilter` — the operator set of `SearchFilter.takenAt`.
///
/// The schema publishes `date-time` strings, so the values are the very
/// ISO-8601 strings the flat `takenAfter`/`takenBefore` already carry: one
/// formatter, one wire format, whether the request goes out flat or structured.
struct DateFilterDto: Codable, Equatable {
    var eq: String?
    var ne: String?
    var gt: String?
    var gte: String?
    var lt: String?
    var lte: String?
}

/// `EnumFilterAssetType` — the operator set of `SearchFilter.type`, whose
/// values are `AssetTypeEnum`'s (`IMAGE`, `VIDEO`, `AUDIO`, `OTHER`).
struct EnumFilterAssetTypeDto: Codable, Equatable {
    var eq: String?
    var ne: String?
    var `in`: [String]?
    var notIn: [String]?
}

/// `BoolFilter` — `SearchFilter.isFavorite`. `eq` is the schema's only property
/// and the only **required** one in the whole filter tree.
struct BoolFilterDto: Codable, Equatable {
    var eq: Bool
}

/// `IdsFilter` — `personIds` and `tagIds` of `SearchFilter`. `all` means every
/// id must match (tags: descendants included server-side); `any` and `none`
/// complete the schema's operator set.
struct IdsFilterDto: Codable, Equatable {
    var any: [String]?
    var all: [String]?
    var none: [String]?
}

/// `StringPatternFilter` — the operator set of `originalFileName` and
/// `description`. The app writes `like`, a case- and accent-insensitive
/// "contains" server-side, the same match the flat fields perform.
struct StringPatternFilterDto: Codable, Equatable {
    var eq: String?
    var ne: String?
    var `in`: [String]?
    var notIn: [String]?
    var like: String?
    var notLike: String?
    var startsWith: String?
    var endsWith: String?
}

/// `EnumFilterAssetVisibility` — the operator set of `SearchFilter.visibility`,
/// whose values are `AssetVisibility`'s raw values.
struct EnumFilterAssetVisibilityDto: Codable, Equatable {
    var eq: String?
    var ne: String?
    var `in`: [String]?
    var notIn: [String]?
}

/// `SearchFilter` — the v3.2.0 replacement of the deprecated scalar fields of
/// `MetadataSearchDto` (`city`, `rating`, `ocr` among them).
///
/// Stays a strict subset of `SearchFilter` (the server rejects additional
/// properties at this level) and carries **what the Search tab can set**: the
/// Filters sheet's constraints, the people and tag pickers, the display
/// options and the file name / description text modes. Album and path filters
/// are not declared: the official mobile client has none. The sub-filters are
/// optional so an undone constraint leaves the body instead of sending `null`.
struct SearchFilterDto: Codable, Equatable {
    var ocr: StringSimilarityFilterDto?
    var city: StringFilterNullableDto?
    var state: StringFilterNullableDto?
    var country: StringFilterNullableDto?
    var make: StringFilterNullableDto?
    var model: StringFilterNullableDto?
    var lensModel: StringFilterNullableDto?
    var type: EnumFilterAssetTypeDto?
    var isFavorite: BoolFilterDto?
    var rating: NumberFilterNullableDto?
    /// `takenAt` — the structured form of the flat `takenAfter`/`takenBefore`
    /// pair (one range, `gte` × `lte`). The server maps it to
    /// `asset.fileCreatedAt`, the same column the flat bounds filter on, so the
    /// two routes answer the same question.
    var takenAt: DateFilterDto?
    var personIds: IdsFilterDto?
    var tagIds: IdsFilterDto?
    /// `hasAlbums.eq == false` is "not in any album".
    var hasAlbums: BoolFilterDto?
    var visibility: EnumFilterAssetVisibilityDto?
    var originalFileName: StringPatternFilterDto?
    var description: StringPatternFilterDto?
}
