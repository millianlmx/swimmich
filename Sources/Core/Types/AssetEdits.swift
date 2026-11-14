import Foundation

// MARK: - Non-destructive server edits (`/api/assets/{id}/edits`)

enum MirrorAxis: String, Codable, Sendable {
    case horizontal, vertical
}

/// One action of the server's edit list. Wire form:
/// `{"action": "crop|rotate|mirror", "parameters": {…}}`.
///
/// Crop values are pixels of the EXIF-oriented original. Servers v2.5–v2.7 type them (and the rotation
/// angle) as `number`, so decoding reads `Double` and rounds down; encoding always writes integers.
enum AssetEditItem: Codable, Equatable, Sendable {
    case crop(x: Int, y: Int, width: Int, height: Int)
    /// Clockwise, one of 0, 90, 180, 270.
    case rotate(angle: Int)
    case mirror(MirrorAxis)

    private enum CodingKeys: String, CodingKey { case action, parameters }
    private enum CropKeys: String, CodingKey { case x, y, width, height }
    private enum RotateKeys: String, CodingKey { case angle }
    private enum MirrorKeys: String, CodingKey { case axis }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(String.self, forKey: .action)
        switch action {
        case "crop":
            let p = try container.nestedContainer(keyedBy: CropKeys.self, forKey: .parameters)
            func whole(_ key: CropKeys) throws -> Int {
                let value = try p.decode(Double.self, forKey: key)
                guard value >= 0 else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: p, debugDescription: "Negative crop value")
                }
                return Int((value + 1e-6).rounded(.down))
            }
            let x = try whole(.x)
            let y = try whole(.y)
            let width = try max(1, whole(.width))
            let height = try max(1, whole(.height))
            self = .crop(x: x, y: y, width: width, height: height)
        case "rotate":
            let p = try container.nestedContainer(keyedBy: RotateKeys.self, forKey: .parameters)
            let raw = try p.decode(Double.self, forKey: .angle)
            var angle = raw.truncatingRemainder(dividingBy: 360)
            if angle < 0 { angle += 360 }
            let quarters = (angle / 90).rounded()
            guard abs(angle - quarters * 90) <= 0.001 else {
                throw DecodingError.dataCorruptedError(forKey: .angle, in: p, debugDescription: "Rotation is not a quarter turn")
            }
            self = .rotate(angle: (Int(quarters) % 4) * 90)
        case "mirror":
            let p = try container.nestedContainer(keyedBy: MirrorKeys.self, forKey: .parameters)
            self = .mirror(try p.decode(MirrorAxis.self, forKey: .axis))
        default:
            throw DecodingError.dataCorruptedError(forKey: .action, in: container,
                                                   debugDescription: "Unknown edit action \(action)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .crop(x, y, width, height):
            try container.encode("crop", forKey: .action)
            var p = container.nestedContainer(keyedBy: CropKeys.self, forKey: .parameters)
            try p.encode(x, forKey: .x)
            try p.encode(y, forKey: .y)
            try p.encode(width, forKey: .width)
            try p.encode(height, forKey: .height)
        case let .rotate(angle):
            try container.encode("rotate", forKey: .action)
            var p = container.nestedContainer(keyedBy: RotateKeys.self, forKey: .parameters)
            try p.encode(angle, forKey: .angle)
        case let .mirror(axis):
            try container.encode("mirror", forKey: .action)
            var p = container.nestedContainer(keyedBy: MirrorKeys.self, forKey: .parameters)
            try p.encode(axis, forKey: .axis)
        }
    }
}

/// `PUT /api/assets/{id}/edits` body. Replaces the whole list; the server refuses an empty one.
struct AssetEditsCreateDto: Encodable, Equatable {
    let edits: [AssetEditItem]
}

/// `GET`/`PUT /api/assets/{id}/edits` response. The per-action `id` is ignored.
struct AssetEditsResponseDto: Decodable, Equatable {
    let assetId: String
    let edits: [AssetEditItem]
}

enum AssetEditsSupport {
    /// The routes appeared (beta) in v2.5.0.
    static let minimumServerVersion = (major: 2, minor: 5, patch: 0)

    /// False for an unreadable version: the caller decides what "unknown" means.
    static func isSupported(_ version: ServerVersionResponseDto?) -> Bool {
        let minimum = minimumServerVersion
        return version?.isAtLeast(major: minimum.major, minor: minimum.minor, patch: minimum.patch) == true
    }

    /// `DownloadArchiveDto.edited` exists from v2.6.0 (an older server ignores it).
    static let minimumArchiveServerVersion = (major: 2, minor: 6, patch: 0)

    /// A server that serves `/edits` and takes `edited` in the archive request: a selection of
    /// photos, whose items do not say whether one is edited, then offers "edited or original".
    /// False for an unreadable version.
    static func acceptsEditedArchive(_ version: ServerVersionResponseDto?) -> Bool {
        let minimum = minimumArchiveServerVersion
        return isSupported(version)
            && version?.isAtLeast(major: minimum.major, minor: minimum.minor, patch: minimum.patch) == true
    }

    /// The viewer's rule for offering "edited version or original": the photo's own record
    /// (`GET /api/assets/{id}`, `isEdited`) says it is edited. An unreadable record, or a server
    /// older than v2.5.0 that sends no `isEdited`, offers nothing and the original goes without a question.
    static func isEditedOnServer(assetId: String, client: any ImmichClient) async -> Bool {
        (try? await client.getAsset(id: assetId))?.isEdited == true
    }
}

/// Waits for the server to regenerate the thumbnails of a photo whose edits just changed (L-21).
/// The job (`AssetEditThumbnailGeneration`) runs after the `PUT` or `DELETE` answered; until it ends,
/// `edited=true` still serves the old image under the old thumbhash. The official client waits for
/// the `AssetEditReadyV1`/`V2` event for up to 10 s; this reads the record each second for as long,
/// which also covers a server whose socket is not reachable.
enum EditedAssetRefresh {
    static let defaultAttempts = 10
    static let defaultInterval: Duration = .seconds(1)

    /// The record with a thumbhash different from `previousThumbhash`, or nil when it never changed
    /// within `attempts` reads (an edit that leaves the thumbnail alone) or the task was cancelled.
    static func awaitRegeneration(
        assetId: String,
        previousThumbhash: String?,
        client: any ImmichClient,
        attempts: Int = defaultAttempts,
        interval: Duration = defaultInterval
    ) async -> AssetResponseDto? {
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: interval) }
            if Task.isCancelled { return nil }
            if let record = try? await client.getAsset(id: assetId), record.thumbhash != previousThumbhash {
                return record
            }
        }
        return nil
    }
}
