import Foundation

/// Pure display formatters for `ExifResponseDto`. Zero state, unit-testable.
/// Covers AC-201 (happy paths) + AC-201b (nil cases / FM-2 coverage).
extension ExifResponseDto {
    /// e.g. "50 mm". Nil when `focalLength` is nil (FM-2).
    var focalLengthFormatted: String? {
        guard let fl = focalLength else { return nil }
        return String(format: "%.0f mm", fl)
    }

    /// e.g. "4032 × 3024". Nil unless BOTH dimensions are present (FM-2).
    var dimensionsFormatted: String? {
        guard let w = exifImageWidth, let h = exifImageHeight else { return nil }
        return "\(w) × \(h)"
    }

    /// e.g. "4 MB" via system format style. Nil when bytes absent.
    var fileSizeFormatted: String? {
        guard let bytes = fileSizeInByte else { return nil }
        return Int64(bytes).formatted(.byteCount(style: .file))
    }

    /// e.g. "f/1.8". Nil when fNumber absent.
    var apertureFormatted: String? {
        guard let f = fNumber else { return nil }
        return String(format: "f/%.1f", f)
    }

    /// e.g. "ISO 400". Nil when iso absent.
    var isoFormatted: String? {
        guard let iso else { return nil }
        return "ISO \(iso)"
    }

    /// e.g. "1/250s". Nil when exposureTime absent.
    var exposureFormatted: String? {
        guard let exposureTime else { return nil }
        return "\(exposureTime)s"
    }

    /// e.g. "Canon EOS R". Nil when make absent (model alone insufficient for a "Camera" label).
    var cameraFormatted: String? {
        guard let make else { return nil }
        return [make, model].compactMap { $0 }.joined(separator: " ")
    }

    /// e.g. "30 juil. 2024 à 14:32" (locale-dependent). Nil when dateTimeOriginal absent;
    /// returns raw string if parsing fails so UI degrades gracefully.
    var dateFormatted: String? {
        guard let raw = dateTimeOriginal else { return nil }
        guard let date = LongDateFormatter.parse(isoTimestamp: raw) else { return raw }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}
