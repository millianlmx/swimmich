import Foundation
import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Failures of the "save edited copy" path. Messages live in `PhotoEditorViewModel.message(for:)`.
enum EditorSaveError: Error, Equatable {
    case metadataUnavailable
    case renderFailed
    case fileWriteFailed
    case uploadRejected
}

/// What the edited JPEG inherits from the original asset: a file name and the capture date,
/// all derived from the server's dates so the copy lands on the same timeline day/hour.
struct EditedCopyMetadata: Equatable, Sendable {
    let fileName: String
    /// EXIF `DateTimeOriginal`, `yyyy:MM:dd HH:mm:ss` (wall-clock = `localDateTime` read as UTC).
    let dateTimeOriginal: String
    /// EXIF `OffsetTimeOriginal`, `±HH:MM` = `localDateTime − fileCreatedAt`.
    let offsetTimeOriginal: String
    /// EXIF `SubsecTimeOriginal`, 3 digits.
    let subsecTimeOriginal: String

    init(asset: AssetResponseDto) throws {
        let base = (asset.originalFileName as NSString).deletingPathExtension
        guard !base.isEmpty else { throw EditorSaveError.metadataUnavailable }
        guard let local = Self.parse(asset.localDateTime),
              let created = Self.parse(asset.fileCreatedAt) else {
            throw EditorSaveError.metadataUnavailable
        }
        self.fileName = base + "_edited.jpg"

        // Split into whole seconds + milliseconds from an integer count, so a rounded
        // 999.6 ms can never print as ":59.1000".
        let totalMs = Int((local.timeIntervalSince1970 * 1000).rounded())
        var seconds = totalMs / 1000
        var ms = totalMs % 1000
        if ms < 0 { ms += 1000; seconds -= 1 }
        self.dateTimeOriginal = Self.exifFormatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
        self.subsecTimeOriginal = String(format: "%03d", ms)

        let deltaMinutes = Int((local.timeIntervalSince(created) / 60).rounded())
        let magnitude = abs(deltaMinutes)
        let sign = deltaMinutes >= 0 ? "+" : "-"
        self.offsetTimeOriginal = sign + String(format: "%02d:%02d", magnitude / 60, magnitude % 60)
    }

    private static func parse(_ string: String) -> Date? {
        ISO8601.immichFormatter.date(from: string) ?? ISO8601.fallbackFormatter.date(from: string)
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}

/// Stateless full-resolution render of an `EditState` to a JPEG file.
enum EditedImageRenderer {

    /// Hand-written (the SDK has no public conversion; raw values differ between the two enums).
    static func propertyOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    /// Integer pixel rect used by both the preview and the file, so a 90° rotation never gains a pixel.
    static func renderRect(_ extent: CGRect) -> CGRect {
        CGRect(x: extent.origin.x.rounded(),
               y: extent.origin.y.rounded(),
               width: extent.size.width.rounded(),
               height: extent.size.height.rounded())
    }

    /// Fills the empty corners left by straightening with opaque black (#23) and crops to the render rect.
    static func opaqueOutput(_ image: CIImage) -> CIImage {
        let rect = renderRect(image.extent)
        return image
            .composited(over: CIImage(color: .black).cropped(to: rect))
            .cropped(to: rect)
    }

    /// Renders `cgImage` (raw pixels) with `state`, bakes `orientation` in, and writes a JPEG
    /// (quality 0.9, Orientation = 1, EXIF capture date only, no GPS/TIFF) to `url`.
    static func writeJPEG(cgImage: CGImage,
                          orientation: UIImage.Orientation,
                          state: EditState,
                          metadata: EditedCopyMetadata,
                          to url: URL) throws {
        let edited = EditPipeline.applyEditState(to: CIImage(cgImage: cgImage), state: state)
            .oriented(propertyOrientation(orientation))
        let output = opaqueOutput(edited)

        let colorSpace: CGColorSpace
        if let source = cgImage.colorSpace, source.model == .rgb {
            colorSpace = source
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        guard let rendered = CIContext().createCGImage(output,
                                                       from: renderRect(output.extent),
                                                       format: .RGBA8,
                                                       colorSpace: colorSpace) else {
            throw EditorSaveError.renderFailed
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EditorSaveError.fileWriteFailed
        }
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: metadata.dateTimeOriginal,
            kCGImagePropertyExifOffsetTimeOriginal: metadata.offsetTimeOriginal,
            kCGImagePropertyExifSubsecTimeOriginal: metadata.subsecTimeOriginal
        ]
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyExifDictionary: exif
        ]
        CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw EditorSaveError.fileWriteFailed
        }
    }
}
