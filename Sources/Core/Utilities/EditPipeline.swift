import Foundation
import CoreImage
import CoreGraphics
import ImageIO
import simd

// MARK: - EditPipeline
//
// Pure, non-isolated, unit-testable functions implementing the non-destructive edit
// pipeline (cahier §5). No UIKit, no CIContext — operates on `CIImage` only.
//
// Pipeline order (matches the server's semantics, so a saved edit looks like its preview):
//   0. `orientation`: the EXIF orientation of the raw buffer is applied first
//   1. Color filters: exposure → color(contrast+saturation combined) → warmth
//   2. Crop (cropRect: normalized, raw-buffer space → oriented image, then CoreImage pixels, Y-axis flip)
//   3. Mirror (horizontal, then vertical, around the center of the cropped image)
//   4. Quarter turns (`orientationSteps` × 90°, clockwise on screen)
//   5. Straighten (`straightenDeg`)
//
// Neutral state with `.up` = identity (extent unchanged).

enum EditPipeline {

    // MARK: Filters (AC-607)

    /// Builds the ordered list of CIFilters for the color-adjustment phase.
    /// Neutral values are omitted (empty array for `.neutral`).
    ///
    /// Order: exposure (CIExposureAdjust) → color (CIColorControls UNIQUE, contrast+saturation combined)
    /// → warmth (CITemperatureAndTint). FM-1.
    static func buildEditFilters(for state: EditState) -> [CIFilter] {
        var filters: [CIFilter] = []

        // Exposure — CIExposureAdjust.inputEV
        if state.exposure != 0 {
            let f = CIFilter(name: "CIExposureAdjust")!
            f.setValue(state.exposure, forKey: "inputEV")
            filters.append(f)
        }

        // Contrast + Saturation combined into ONE CIColorControls filter (loop 2 advisory resolution).
        if state.contrast != 0 || state.saturation != 0 {
            let f = CIFilter(name: "CIColorControls")!
            f.setValue(state.contrast, forKey: "inputContrast")
            f.setValue(state.saturation, forKey: "inputSaturation")
            // inputBrightness stays neutral (0).
            filters.append(f)
        }

        // Warmth — CITemperatureAndTint. Scale warmth [-1,+1] → ±1500K temperature delta.
        if state.warmth != 0 {
            let f = CIFilter(name: "CITemperatureAndTint")!
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 6500 + state.warmth * 1500, y: 0), forKey: "inputTargetNeutral")
            filters.append(f)
        }

        return filters
    }

    // MARK: Apply (AC-607, AC-619)

    /// Applies the full pipeline to a `CIImage` of raw pixels whose EXIF orientation is `orientation`.
    /// Pure function, deterministic.
    static func applyEditState(to image: CIImage,
                               state: EditState,
                               orientation: CGImagePropertyOrientation = .up) -> CIImage {
        // 0. EXIF orientation
        var output = orientation == .up ? image : image.oriented(orientation)

        // 1. Color filters
        for filter in buildEditFilters(for: state) {
            filter.setValue(output, forKey: kCIInputImageKey)
            guard let filtered = filter.outputImage else { continue }
            output = filtered
        }

        // 2. Crop (raw-buffer space → oriented image → CoreImage pixels, Y-axis flip)
        if let crop = state.cropRect.map({ AssetEditsMapping.orientedRect($0, orientation) }) {
            let extent = output.extent
            if extent.width > 0 && extent.height > 0 {
                let xPx = extent.minX + crop.origin.x * extent.width
                // UIKit top-left vs CoreImage bottom-left → flip Y.
                let yPx = extent.minY + (1.0 - crop.origin.y - crop.height) * extent.height
                let wPx = crop.width * extent.width
                let hPx = crop.height * extent.height
                let pixelRect = CGRect(x: xPx, y: yPx, width: wPx, height: hPx)
                if let cropFilter = CIFilter(name: "CICrop") {
                    cropFilter.setValue(output, forKey: kCIInputImageKey)
                    cropFilter.setValue(CIVector(cgRect: pixelRect), forKey: "inputRectangle")
                    if let cropped = cropFilter.outputImage {
                        output = cropped
                    }
                }
            }
        }

        // 3. Mirror, around the center of the (possibly cropped) extent.
        if state.mirrorHorizontal {
            output = output.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                              tx: 2 * output.extent.midX, ty: 0))
        }
        if state.mirrorVertical {
            output = output.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                              tx: 0, ty: 2 * output.extent.midY))
        }

        // 4. Quarter turns, clockwise on screen. CoreImage's y axis points up, so (x, y) → (y, -x).
        //    Integer matrices keep the extent exact.
        switch ((state.orientationSteps % 4) + 4) % 4 {
        case 1: output = output.transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0))
        case 2: output = output.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0))
        case 3: output = output.transformed(by: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0))
        default: break
        }

        // 5. Straighten around the center of the extent. A positive angle turns counter-clockwise
        //    on screen (CoreImage's y axis points up): the sign the slider has always had.
        if state.straightenDeg != 0 {
            let center = CGPoint(x: output.extent.midX, y: output.extent.midY)
            let radians = CGFloat(state.straightenDeg * .pi / 180.0)
            let rotation = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: radians)
                .translatedBy(x: -center.x, y: -center.y)
            output = output.transformed(by: rotation)
        }

        return output
    }

    // MARK: Gesture helper (AC-618)

    /// Converts a gesture-space CGRect (view points) to normalized 0..1 coordinates
    /// relative to the display size. Pure helper, unit-testable.
    static func gestureRectToNormalized(_ gestureRect: CGRect, in displaySize: CGSize) -> CGRect {
        guard displaySize.width > 0 && displaySize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: gestureRect.origin.x / displaySize.width,
            y: gestureRect.origin.y / displaySize.height,
            width: gestureRect.width / displaySize.width,
            height: gestureRect.height / displaySize.height
        )
    }
}
