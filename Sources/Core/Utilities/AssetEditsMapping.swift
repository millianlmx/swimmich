import Foundation
import CoreGraphics
import ImageIO

/// Pure conversion between the editor's `EditState` and the server's edit list
/// (`/api/assets/{id}/edits`). No UIKit.
///
/// Server semantics (`media.repository.ts`): the original is decoded with its EXIF orientation applied,
/// cropped by the `crop` action, then transformed by the `mirror` and `rotate` actions in list order.
/// `rotate` turns clockwise, `mirror horizontal` flips left to right.
enum AssetEditsMapping {

    // MARK: Orientation

    /// EXIF orientation of the server record. Unknown or missing → `.up`.
    static func orientation(_ exif: ExifResponseDto?) -> CGImagePropertyOrientation {
        switch exif?.orientation.flatMap({ Int($0) }) {
        case 2: return .upMirrored
        case 3, 180: return .down
        case 4: return .downMirrored
        case 5: return .leftMirrored
        case 6, 90: return .right
        case 7: return .rightMirrored
        case 8, -90: return .left
        default: return .up
        }
    }

    /// Size of the EXIF-oriented image (what the server crops), nil without both dimensions.
    static func orientedSize(_ exif: ExifResponseDto?) -> (width: Int, height: Int)? {
        guard let w = exif?.exifImageWidth, let h = exif?.exifImageHeight, w > 0, h > 0 else { return nil }
        switch exif?.orientation.flatMap({ Int($0) }) {
        case 5, 6, 7, 8, 90, -90: return (h, w)
        default: return (w, h)
        }
    }

    /// Normalized rect of the raw buffer → normalized rect of the oriented image (both top-left origin).
    static func orientedRect(_ r: CGRect, _ o: CGImagePropertyOrientation) -> CGRect {
        let x = r.origin.x, y = r.origin.y, w = r.width, h = r.height
        switch o {
        case .up: return CGRect(x: x, y: y, width: w, height: h)
        case .upMirrored: return CGRect(x: 1 - x - w, y: y, width: w, height: h)
        case .down: return CGRect(x: 1 - x - w, y: 1 - y - h, width: w, height: h)
        case .downMirrored: return CGRect(x: x, y: 1 - y - h, width: w, height: h)
        case .leftMirrored: return CGRect(x: y, y: x, width: h, height: w)
        case .right: return CGRect(x: 1 - y - h, y: x, width: h, height: w)
        case .rightMirrored: return CGRect(x: 1 - y - h, y: 1 - x - w, width: h, height: w)
        case .left: return CGRect(x: y, y: 1 - x - w, width: h, height: w)
        @unknown default: return r
        }
    }

    /// Inverse of `orientedRect`: only the two quarter turns are not their own inverse.
    static func rawRect(_ r: CGRect, _ o: CGImagePropertyOrientation) -> CGRect {
        switch o {
        case .right: return orientedRect(r, .left)
        case .left: return orientedRect(r, .right)
        default: return orientedRect(r, o)
        }
    }

    // MARK: State → server list

    /// The server list for `state`: crop, then `mirror horizontal`, `mirror vertical`, then `rotate`
    /// (the official client's order). Requires `state.isServerExpressible`.
    static func edits(for state: EditState, exif: ExifResponseDto) -> [AssetEditItem] {
        var list: [AssetEditItem] = []
        if let crop = state.cropRect, let size = orientedSize(exif) {
            let r = orientedRect(crop, orientation(exif))
            let w = Double(size.width), h = Double(size.height)
            let left = Double(r.minX) * w, top = Double(r.minY) * h
            let x = min(max(Int((left + 1e-6).rounded(.down)), 0), size.width - 1)
            let y = min(max(Int((top + 1e-6).rounded(.down)), 0), size.height - 1)
            let width = min(max(Int((Double(r.width) * w + 1e-6).rounded(.down)), 1), size.width - x)
            let height = min(max(Int((Double(r.height) * h + 1e-6).rounded(.down)), 1), size.height - y)
            if (x, y, width, height) != (0, 0, size.width, size.height) {
                list.append(.crop(x: x, y: y, width: width, height: height))
            }
        }
        if state.mirrorHorizontal { list.append(.mirror(.horizontal)) }
        if state.mirrorVertical { list.append(.mirror(.vertical)) }
        let quarters = ((state.orientationSteps % 4) + 4) % 4
        if quarters != 0 { list.append(.rotate(angle: quarters * 90)) }
        return list
    }

    // MARK: Server list → state

    /// The editor state a server list stands for: neutral adjustments, no aspect ratio.
    static func state(from edits: [AssetEditItem], exif: ExifResponseDto) -> EditState {
        var state = EditState.neutral
        var crop: (x: Int, y: Int, width: Int, height: Int)?
        var others: [AssetEditItem] = []
        for item in edits {
            if case let .crop(x, y, width, height) = item {
                if crop == nil { crop = (x, y, width, height) }
            } else {
                others.append(item)
            }
        }

        if let crop, let size = orientedSize(exif),
           (crop.x, crop.y, crop.width, crop.height) != (0, 0, size.width, size.height) {
            let w = Double(size.width), h = Double(size.height)
            let rect = CGRect(x: Double(crop.x) / w, y: Double(crop.y) / h,
                              width: Double(crop.width) / w, height: Double(crop.height) / h)
            state.cropRect = rawRect(rect, orientation(exif))
        }

        if let literal = literalTransform(others) {
            state.mirrorHorizontal = literal.horizontal
            state.mirrorVertical = literal.vertical
            state.orientationSteps = literal.steps
        } else {
            let normalized = normalizedTransform(others)
            state.mirrorHorizontal = normalized.horizontal
            state.mirrorVertical = normalized.vertical
            state.orientationSteps = normalized.steps
        }
        return state
    }

    private typealias Transform = (steps: Int, horizontal: Bool, vertical: Bool)

    /// Mirrors (at most one per axis, any order) followed by at most one rotation: read as is.
    private static func literalTransform(_ items: [AssetEditItem]) -> Transform? {
        var horizontal = false, vertical = false
        var steps = 0
        var rotated = false
        for item in items {
            switch item {
            case .mirror(let axis):
                guard !rotated else { return nil }
                if axis == .horizontal {
                    guard !horizontal else { return nil }
                    horizontal = true
                } else {
                    guard !vertical else { return nil }
                    vertical = true
                }
            case .rotate(let angle):
                guard !rotated else { return nil }
                rotated = true
                steps = (angle / 90) % 4
            case .crop:
                return nil
            }
        }
        return (steps, horizontal, vertical)
    }

    /// 2×2 integer matrix on the screen (x right, y down), `[[a, b], [c, d]]`.
    private typealias Matrix = (a: Int, b: Int, c: Int, d: Int)

    private static let identity: Matrix = (1, 0, 0, 1)
    private static let quarterTurn: Matrix = (0, -1, 1, 0)
    private static let flipH: Matrix = (-1, 0, 0, 1)
    private static let flipV: Matrix = (1, 0, 0, -1)

    private static func multiply(_ p: Matrix, _ q: Matrix) -> Matrix {
        (p.a * q.a + p.b * q.c, p.a * q.b + p.b * q.d,
         p.c * q.a + p.d * q.c, p.c * q.b + p.d * q.d)
    }

    /// Composes the actions in list order, then writes the result as `R^steps · mirror`.
    private static func normalizedTransform(_ items: [AssetEditItem]) -> Transform {
        var m = identity
        for item in items {
            switch item {
            case .mirror(.horizontal): m = multiply(flipH, m)
            case .mirror(.vertical): m = multiply(flipV, m)
            case .rotate(let angle):
                for _ in 0..<((angle / 90) % 4) { m = multiply(quarterTurn, m) }
            case .crop:
                break
            }
        }
        let determinant = m.a * m.d - m.b * m.c
        // A mirrored result is R^k · H, so R^k = M · H.
        let rotation = determinant == 1 ? m : multiply(m, flipH)
        var k = 0
        var power = identity
        while k < 4 && power != rotation {
            power = multiply(quarterTurn, power)
            k += 1
        }
        k %= 4
        if determinant == 1 { return (k, false, false) }
        return k < 2 ? (k, true, false) : ((k + 2) % 4, false, true)
    }
}
