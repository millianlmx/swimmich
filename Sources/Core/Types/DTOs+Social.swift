import Foundation

// MARK: - Activity DTOs (P0 api-surface-expansion)

enum ReactionType: String, Codable, Equatable {
    case comment
    case like
}

/// `POST /api/activities`
struct ActivityCreateDto: Codable, Equatable {
    let albumId: String
    let type: ReactionType
    var assetId: String?
    var comment: String?
}

/// `GET /api/activities`
struct ActivityResponseDto: Codable, Equatable {
    let id: String
    let createdAt: String
    let type: ReactionType
    let user: UserResponseDto
    /// nil for an activity posted on the album itself.
    let assetId: String?
    var comment: String?
}

// MARK: - Memories DTOs (P0 api-surface-expansion)

enum MemoryType: String, Codable, Equatable {
    case on_this_day
    /// Server-side memory types this client doesn't render yet. Decoding
    /// unknown types as `.unknown` keeps the whole `GET /api/memories`
    /// payload decodable instead of failing the entire list.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryType(rawValue: raw) ?? .unknown
    }
}

struct OnThisDayDto: Codable, Equatable {
    let year: Int
}

/// `GET /api/memories`
struct MemoryResponseDto: Codable, Equatable {
    let id: String
    let createdAt: String
    let updatedAt: String
    let memoryAt: String
    let ownerId: String
    let type: MemoryType
    let data: OnThisDayDto
    let assets: [AssetResponseDto]
    let isSaved: Bool
    var showAt: String?
    var hideAt: String?
    var seenAt: String?
    var deletedAt: String?
}

/// `POST /api/memories` — the server's create contract, verified against the
/// published OpenAPI: `data`, `memoryAt` and `type` are **required** (a missing
/// one is a 400), and there is **no name/description field at all** — a memory
/// is a date, a type and a set of assets. `type` only ever takes `on_this_day`
/// server-side (`MemoryType` there is a single-value enum).
///
/// The client does not schedule memories (`showAt`/`hideAt`) — that is how the
/// server's own `on_this_day` lanes stay hidden until their day; a memory
/// created here is visible immediately and dated by `memoryAt`.
struct MemoryCreateDto: Codable, Equatable {
    let assetIds: [String]
    let data: OnThisDayDto
    let memoryAt: String
    let type: MemoryType
    /// Set by `MemoriesViewModel.createMemory`: the server's cleanup job deletes
    /// **unsaved** memories older than 30 days, so a memory the user asked for
    /// explicitly must not be born unsaved (see `MemoryRepository.cleanup`).
    var isSaved: Bool?
}

/// `PUT /api/memories/{id}` — every field optional; omitted ones are left
/// untouched. The app only writes `isSaved` (the save/unsave toggle) — the
/// other two are the server's own contract, kept so the DTO stays a faithful
/// mirror of `MemoryUpdateDto`.
struct MemoryUpdateDto: Codable, Equatable {
    var isSaved: Bool?
    var memoryAt: String?
    var seenAt: String?
}

/// `GET /api/memories/statistics` — `{total}`.
///
/// Unlike `GET /api/memories`, this count is **not** filtered down to memories
/// that still show assets (the server counts rows; `MemoryService.search` drops
/// the empty ones), so it can legitimately exceed `memories.count`. It is the
/// count the server's own paging answers to: `size`/`page` on the list route
/// only apply when the caller passes `size`, which this client does not — the
/// web client passes `size: 250` and uses this total to decide whether a next
/// page exists.
struct MemoryStatisticsResponseDto: Codable, Equatable {
    let total: Int
}

// MARK: - Duplicates DTOs (P0 api-surface-expansion)

/// `GET /api/duplicates` — one entry per detected duplicate group.
struct DuplicateResponseDto: Codable, Equatable {
    let duplicateId: String
    let assets: [AssetResponseDto]
    let suggestedKeepAssetIds: [String]
}