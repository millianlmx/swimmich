import Foundation

// MARK: - Search Request DTOs

/// Body for `POST /api/search/metadata` — text/EXIF field search.
/// For MVP free-text search: caller sets `query`. Field-specific search
/// (city, make, model, ...) is used by Explore tap (AC-404b).
struct MetadataSearchDto: Codable, Equatable {
    var query: String?
    /// v3.2.0 field filters — the replacement of the struct's deprecated scalar
    /// fields (`ocr` among them). Optional so the key disappears from the body
    /// when no filter is active; see `SearchFilterDto`.
    var filter: SearchFilterDto?
    var make: String?
    var model: String?
    var lensModel: String?
    var city: String?
    var state: String?
    var country: String?
    var type: String?
    var isFavorite: Bool?
    /// Filter by rating `1...5` (the server's scale — `0` is invalid since v3).
    ///
    /// The flat field is `x-immich-state: Deprecated` since v3.2.0, **but so are
    /// the 33 other flat fields of this schema** (`isFavorite`, `city`, `make`,
    /// `model`, `visibility`, …), i.e. every filter this screen already sends.
    /// Its replacement is `filter.rating`, and the two are mutually exclusive in
    /// one body: this field is what the *flat* route carries, the structured one
    /// is built by `structuredShape(cursor:)`.
    var rating: Int?
    var personIds: [String]?
    var albumIds: [String]? // AC-519 — enables album asset fetch (FM-2 mitigation)
    /// Direction-only sort (`asc`/`desc`), deprecated since v3.2.0. Written by
    /// the album detail screen on the flat route (the album's own direction);
    /// never written by search, whose Sort option goes through `orderBy` (which
    /// names a field; `order` cannot). Absent from the body when nil.
    var order: String?
    var page: Int?
    var size: Int?
    var withExif: Bool?
    /// Taken-date range — ISO-8601 strings, because the schema publishes them
    /// as `string`/`date-time` and the `Date` → `String` step belongs to the
    /// ViewModel. Deprecated flat fields (replacement: `filter.takenAt`), kept
    /// for the same reason as `rating`: they are what the flat route carries.
    /// Written only while the Filters sheet's date toggle is on.
    var takenAfter: String?
    var takenBefore: String?
    /// Sort of the result set — a `SearchOrder` (`field` × `direction`), added
    /// in v3.2.0 and the non-deprecated replacement of `order`, which search
    /// therefore never writes (it cannot name a field).
    var orderBy: SearchOrderDto?
    /// Pagination of the structured route: the opaque cursor the previous
    /// response handed out (`SearchAssetResponseDto.nextCursor`), added in
    /// v3.2.0. Never written next to the flat `page` — the server rejects the
    /// mix — so `flatShape()` drops it.
    var cursor: String?

    // MARK: - The two shapes of the request

    /// The v3.2.0 shape of this request — `query`, `filter`, `orderBy`,
    /// `cursor` — with **not one** deprecated flat field.
    ///
    /// The flat fields are not merely redundant here: `withShapeExclusivity`
    /// (`search.dto.ts`) rejects every deprecated field sent next to
    /// `filter`/`orderBy`/`cursor`, `page` and `rating` included, with a 400.
    /// The constraints therefore travel as a `SearchFilter`, and pagination as
    /// a cursor.
    func structuredShape(cursor: String?) -> MetadataSearchDto {
        var dto = MetadataSearchDto(query: query, orderBy: orderBy, cursor: cursor)
        dto.filter = structuredFilter
        dto.size = size
        dto.withExif = withExif
        return dto
    }

    /// The flat shape — the body this app has always sent, and the only one a
    /// server older than v3.2.0 understands. No `filter`/`orderBy`/`cursor`:
    /// one of them next to a flat field is the same 400.
    func flatShape() -> MetadataSearchDto {
        var dto = self
        dto.filter = nil
        dto.orderBy = nil
        dto.cursor = nil
        return dto
    }

    /// The flat constraints of this request, projected onto `SearchFilter`.
    ///
    /// One writer per constraint and one operator each (`nonEmptyPartial`
    /// server-side): `eq` for the single-valued fields the sheet collects, and
    /// `gte`/`lte` for the two ends of the date range — the operators the
    /// server's own legacy builder uses on the very same column.
    private var structuredFilter: SearchFilterDto? {
        var structured = SearchFilterDto()
        structured.ocr = filter?.ocr
        if let city { structured.city = StringFilterNullableDto(eq: city) }
        if let state { structured.state = StringFilterNullableDto(eq: state) }
        if let country { structured.country = StringFilterNullableDto(eq: country) }
        if let make { structured.make = StringFilterNullableDto(eq: make) }
        if let model { structured.model = StringFilterNullableDto(eq: model) }
        if let lensModel { structured.lensModel = StringFilterNullableDto(eq: lensModel) }
        if let type { structured.type = EnumFilterAssetTypeDto(eq: type) }
        if let isFavorite { structured.isFavorite = BoolFilterDto(eq: isFavorite) }
        if let rating { structured.rating = NumberFilterNullableDto(eq: Double(rating)) }
        if takenAfter != nil || takenBefore != nil {
            structured.takenAt = DateFilterDto(gte: takenAfter, lte: takenBefore)
        }
        // An operator-less `SearchFilter` would make the body say "filtered"
        // while nothing is filtered; the key simply stays out.
        return structured == SearchFilterDto() ? nil : structured
    }
}

/// `SearchOrder` of the published contract: the `orderBy` body of a metadata
/// search. Both members are enums server-side (`SearchOrderField`,
/// `AssetOrder`); kept as strings here so the DTO stays a plain mirror.
struct SearchOrderDto: Codable, Equatable {
    var field: String
    var direction: String
}

/// Body for `POST /api/search/smart` — CLIP semantic search.
struct SmartSearchDto: Codable, Equatable {
    var query: String
    var page: Int?
    var size: Int?
    var withExif: Bool?
}

/// Body for `POST /api/search/statistics` — returns a total count for a given
/// metadata filter. Used by Explore to show "247 photos" per place. Mirrors
/// the subset of `BaseSearchSchema` field filters the server honors.
struct SearchStatisticsDto: Codable, Equatable {
    var city: String?
    var state: String?
    var country: String?
    var make: String?
    var model: String?
    var lensModel: String?
}

/// Response for `POST /api/search/statistics`.
struct SearchStatisticsResponseDto: Codable, Equatable {
    let total: Int
}

// MARK: - Search Response DTOs

/// Top-level response wrapper. Immich server also serializes `albums`, which
/// we intentionally ignore via explicit CodingKeys (FM-1 mitigation — Swift
/// JSONDecoder ignores unknown JSON keys when CodingKeys is explicit).
struct SearchResponseDto: Codable, Equatable {
    let assets: SearchAssetResponseDto

    enum CodingKeys: String, CodingKey {
        case assets
    }
}

/// `assets` payload. Immich server also sends `total` (deprecated) and
/// `facets` arrays — ignored via CodingKeys.
struct SearchAssetResponseDto: Codable, Equatable {
    let count: Int
    let items: [AssetResponseDto]
    /// Flat pagination: the **number** of the next page, `null` on the last one.
    /// `x-immich-state: Deprecated` since v3.2.0, and `null` on every
    /// structured response — which is why the cursor below is not optional
    /// reading: a v3.2.0 server paginates with one and never with the other.
    let nextPage: String?
    /// Structured pagination (v3.2.0): the opaque cursor of the next page, the
    /// very string the next request must send back as `cursor`. `var` with an
    /// implicit `nil` so every existing constructor keeps compiling — the
    /// synthesized `Codable` still decodes the key when the server sends it.
    var nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case count, items, nextPage, nextCursor
    }
}

// MARK: - Explore

/// `GET /api/search/explore` response. Grouped by `fieldName`
/// (e.g. "exifInfo.city"), each value carrying a representative thumbnail.
struct SearchExploreResponseDto: Codable, Equatable {
    let fieldName: String
    let items: [SearchExploreItem]
}

struct SearchExploreItem: Codable, Equatable {
    let value: String
    let data: AssetResponseDto
}
