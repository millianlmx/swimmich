import CoreGraphics

/// Size in pixels of a photo as it is displayed (EXIF orientation applied).
struct PixelSize: Hashable, Sendable {
    let width: Int
    let height: Int

    /// nil when either side is missing or not positive.
    init?(width: Int?, height: Int?) {
        guard let width, let height, width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    /// Reads `exifImageWidth` × `exifImageHeight`. Orientations 5–8 (and the
    /// degree forms 90 / -90) turn the photo by a quarter turn, so the displayed
    /// width and height swap. nil without EXIF or without both dimensions.
    init?(exif: ExifResponseDto?) {
        guard let exif, let w = exif.exifImageWidth, let h = exif.exifImageHeight else { return nil }
        let quarterTurn = exif.orientation.flatMap { Int($0) }.map { [5, 6, 7, 8, 90, -90].contains($0) } ?? false
        self.init(width: quarterTurn ? h : w, height: quarterTurn ? w : h)
    }

    var aspectRatio: CGFloat { CGFloat(width) / CGFloat(height) }
}
