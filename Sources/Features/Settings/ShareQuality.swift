import Foundation

/// Quality a photo is shared in from the viewer (upstream's `ShareAssetType`,
/// stored under `shareFileType`). The raw values are the ones persisted.
enum ShareQuality: String, CaseIterable, Identifiable, Sendable {
    case original
    case preview

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .original: "Original"
        case .preview: "Preview"
        }
    }
}
