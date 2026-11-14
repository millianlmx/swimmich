import Foundation
import ImageIO
import UIKit
import os

/// A tile's size on the glass, in pixels (points × screen scale).
struct WidgetPixelSize: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// Prepares the JPEG bytes the widget carries in its timeline entry: one image
/// per drawn tile, exactly as large as the tile, never larger than its source.
///
/// WidgetKit archives every entry to disk and reads it back to render, and it
/// refuses an image whose area is too large for the widget ("Widget archival
/// failed due to image being too large … totalArea > max"). A widget whose entry
/// was never archived shows its **placeholder forever**: no photos, no error,
/// no log line on the extension side. That is the symptom this project chased
/// for two days, and it never reproduced on a simulator because the test stub
/// serves 8×8 PNGs.
///
/// So each photo is decoded once, at the size of the tile it is drawn in
/// (`encode(_:toCover:)`), and the whole entry stays inside `budget`. A tile is
/// sharp at the widget's real size on any screen, and nothing bigger than a
/// tile ever reaches the archive.
enum WidgetImageEncoder {

    /// Total image bytes an entry may carry, every photo and every memory card
    /// together (1 MiB). Each image is already bounded by its tile, so the
    /// budget is a safety net, not a quality knob: quality is never lowered.
    static let budget = 1_048_576

    /// JPEG quality of every encoded image.
    static let quality: CGFloat = 0.6

    /// Decodes `data` just large enough to cover `tile`, then crops it to the
    /// tile, centred: each dimension is `min(source reduced to cover the tile,
    /// tile)`. The source is never enlarged. Returns nil when the bytes cannot
    /// be decoded (the caller then renders its branded plate) or the tile is
    /// empty.
    static func encode(_ data: Data, toCover tile: WidgetPixelSize) -> Data? {
        guard tile.width > 0, tile.height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        // Pixel sizes are those of the stored image; orientations 5…8 turn it.
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
           (5...8).contains(orientation) {
            swap(&width, &height)
        }
        let factor = min(1, max(CGFloat(tile.width) / CGFloat(width), CGFloat(tile.height) / CGFloat(height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((CGFloat(max(width, height)) * factor - 1e-6).rounded(.up)),
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let outWidth = min(decoded.width, tile.width)
        let outHeight = min(decoded.height, tile.height)
        var image = decoded
        if outWidth != decoded.width || outHeight != decoded.height {
            let crop = CGRect(
                x: (decoded.width - outWidth) / 2,
                y: (decoded.height - outHeight) / 2,
                width: outWidth,
                height: outHeight
            )
            guard let cropped = decoded.cropping(to: crop) else { return nil }
            image = cropped
        }
        return UIImage(cgImage: image).jpegData(compressionQuality: quality)
    }

    /// Keeps the images of `photos` (already encoded, in the order they are
    /// drawn) while the running total stays inside `budget`; a photo that would
    /// overflow it loses its bytes but keeps its cell — a partial mosaic beats
    /// an entry that never renders.
    static func budgeted(_ photos: [WidgetPhoto], budget: Int = budget) -> [WidgetPhoto] {
        var spent = 0
        return photos.map { photo in
            guard let data = photo.imageData else { return photo }
            guard spent + data.count <= budget else {
                // `hydrating(with: nil)` is a no-op by design, so this needs a fresh photo.
                return WidgetPhoto(
                    id: photo.id,
                    imageData: nil,
                    isVideo: photo.isVideo,
                    isFavorite: photo.isFavorite,
                    day: photo.day
                )
            }
            spent += data.count
            return photo
        }
    }
}
