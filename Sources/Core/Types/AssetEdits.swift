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

    /// Temporary switch (`-assetEditsServerSave YES`): the editor saves server-side edits only
    /// when on. Off in production until the display of edited photos ships.
    static let serverSaveDefaultsKey = "assetEditsServerSave"
    static let isEditorServerSaveEnabled = UserDefaults.standard.bool(forKey: serverSaveDefaultsKey)
}
