import CoreGraphics

/// Pure zoom maths of the photo viewer (L-06): the scale ceiling that follows a
/// photo's resolution, the rectangle the image occupies, and the pan bounds.
/// No state, no view — everything here is unit-tested directly.
enum ZoomGeometry {
    static let minScale: CGFloat = 1
    /// Ceiling when the pixel size is unknown (and for an edited asset).
    static let unknownMaxScale: CGFloat = 4
    /// A small image still zooms this far, even though its native scale is lower.
    static let floorMaxScale: CGFloat = 2
    static let doubleTapScale: CGFloat = 3
    /// A pinch released under this scale springs back to 1x.
    static let snapBackThreshold: CGFloat = 1.05
    /// Above this scale the photo counts as zoomed (swipe-to-dismiss is blocked).
    static let zoomedThreshold: CGFloat = 1.01

    /// The `.fit` rectangle of an image of `aspect` (width / height) centered in
    /// `viewport`, before zoom. A degenerate aspect or viewport fills the viewport.
    static func fittedRect(aspect: CGFloat, in viewport: CGSize) -> CGRect {
        guard aspect > 0, viewport.width > 0, viewport.height > 0 else {
            return CGRect(origin: .zero, size: viewport)
        }
        let size = CGSize(
            width: min(viewport.height * aspect, viewport.width),
            height: min(viewport.height, viewport.width / aspect)
        )
        return CGRect(
            x: (viewport.width - size.width) / 2,
            y: (viewport.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Aspect (width / height) of the image actually drawn: the decoded image
    /// when known, else the EXIF pixel size, else `fallback`.
    static func displayAspect(decoded: CGSize?, pixelSize: PixelSize?, fallback: CGFloat) -> CGFloat {
        if let decoded, decoded.width > 0, decoded.height > 0 {
            return decoded.width / decoded.height
        }
        return pixelSize?.aspectRatio ?? fallback
    }

    /// The scale at which one photo pixel covers one screen pixel.
    static func nativeScale(pixelSize: PixelSize, viewport: CGSize, displayScale: CGFloat) -> CGFloat? {
        guard viewport.width > 0, viewport.height > 0, displayScale > 0 else { return nil }
        let fittedWidth = fittedRect(aspect: pixelSize.aspectRatio, in: viewport).width
        guard fittedWidth > 0 else { return nil }
        return CGFloat(pixelSize.width) / (fittedWidth * displayScale)
    }

    /// Zoom ceiling: native pixels for a large photo, `floorMaxScale` for a small
    /// one, `unknownMaxScale` without a pixel size. No absolute cap.
    static func maxScale(pixelSize: PixelSize?, viewport: CGSize, displayScale: CGFloat) -> CGFloat {
        guard let pixelSize,
              let native = nativeScale(pixelSize: pixelSize, viewport: viewport, displayScale: displayScale)
        else { return unknownMaxScale }
        return max(native, floorMaxScale)
    }

    static func doubleTapTarget(maxScale: CGFloat) -> CGFloat {
        min(doubleTapScale, maxScale)
    }

    /// Bounds the pan so no edge of the zoomed image enters the viewport. On an
    /// axis where the zoomed image is smaller than the viewport it stays centered.
    static func clampedOffset(_ offset: CGSize, scale: CGFloat, fitted: CGSize, viewport: CGSize) -> CGSize {
        let excessW = max(0, (fitted.width * scale - viewport.width) / 2)
        let excessH = max(0, (fitted.height * scale - viewport.height) / 2)
        return CGSize(
            width: min(max(offset.width, -excessW), excessW),
            height: min(max(offset.height, -excessH), excessH)
        )
    }

    /// The resting state for a scale/offset under a (possibly new) ceiling:
    /// scale capped at `maxScale`, offset re-bounded, 1x with no offset under the
    /// snap-back threshold.
    static func settled(
        scale: CGFloat,
        offset: CGSize,
        maxScale: CGFloat,
        fitted: CGSize,
        viewport: CGSize
    ) -> (scale: CGFloat, offset: CGSize) {
        let capped = max(minScale, min(scale, maxScale))
        if capped < snapBackThreshold { return (1, .zero) }
        return (capped, clampedOffset(offset, scale: capped, fitted: fitted, viewport: viewport))
    }
}
