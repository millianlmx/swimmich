import CoreGraphics
import CoreVideo
import UIKit

/// What an export frame is drawn with: the handful of operations the
/// road-trip film needs, in canvas pixels with y down. The frame's scene
/// (`RoadTripVideoRenderer.drawFrame`) is written once against it; the GPU
/// draws it (`RoadTripMetalCanvas`), Core Graphics where Metal is missing
/// and as the tests' reference (`RoadTripCGCanvas`).
protocol RoadTripFrameCanvas: AnyObject {
    var size: CGSize { get }

    /// `rect` filled with `color`, tilted `rotation` radians (clockwise)
    /// about its center.
    func fill(_ rect: CGRect, color: RoadTripRGBA, rotation: Double)

    /// The `source` part of `image` (0…1 of its width and height, top-left
    /// origin) stretched over `rect`, tilted about the rect's center, faded to
    /// `alpha`, cut by `mask`.
    func draw(_ image: CGImage, in rect: CGRect, source: CGRect, alpha: Double, rotation: Double, mask: RoadTripMask)

    /// A dot of `color`.
    func circle(center: CGPoint, radius: CGFloat, color: RoadTripRGBA)

    /// The soft shadow of a circle inscribed in `rect`, `blur` pixels wide.
    func circleShadow(in rect: CGRect, blur: CGFloat, color: RoadTripRGBA)

    /// Lines stroked one style over the other (round caps and joins), the
    /// whole faded to `alpha` as one layer.
    func stroke(_ lines: [[CGPoint]], styles: [(color: RoadTripRGBA, width: CGFloat)], alpha: Double)

    /// The slideshow's vignette: clear to 55 % of the radius, then
    /// darkening to 45 % black.
    func vignette()

    /// The frame is drawn: its pixels are in the buffer when this returns.
    func finish()
}

/// How an image is cut.
enum RoadTripMask: Equatable {
    case none
    case roundedRect(radius: CGFloat)
    case ellipse
}

/// A colour, not premultiplied, in the frame's device RGB.
struct RoadTripRGBA: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let black = RoadTripRGBA(red: 0, green: 0, blue: 0, alpha: 1)
    static let white = RoadTripRGBA(red: 1, green: 1, blue: 1, alpha: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }

    func withAlpha(_ factor: Double) -> RoadTripRGBA {
        RoadTripRGBA(red: red, green: green, blue: blue, alpha: alpha * factor)
    }

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [red, green, blue, alpha].map { CGFloat($0) })
            ?? UIColor.black.cgColor
    }
}

extension RoadTripFrameCanvas {
    func fill(_ rect: CGRect, color: RoadTripRGBA) {
        fill(rect, color: color, rotation: 0)
    }

    /// The whole canvas filled with `color`.
    func fill(_ color: RoadTripRGBA) {
        fill(CGRect(origin: .zero, size: size), color: color, rotation: 0)
    }

    /// All of `image` stretched over `rect`.
    func draw(_ image: CGImage, in rect: CGRect, alpha: Double = 1) {
        draw(image, in: rect, source: CGRect(x: 0, y: 0, width: 1, height: 1), alpha: alpha, rotation: 0, mask: .none)
    }

    /// `image` filling `rect` without distortion (centered, the overflow cut),
    /// pushed in by `zoom` — the player's `.fill` photo.
    func drawFilled(
        _ image: CGImage, in rect: CGRect, zoom: Double = 1, alpha: Double = 1,
        rotation: Double = 0, mask: RoadTripMask = .none
    ) {
        draw(image, in: rect, source: Self.fillSource(image: image, rect: rect, zoom: zoom),
             alpha: alpha, rotation: rotation, mask: mask)
    }

    /// The part of `image` an aspect fill of `rect` shows (0…1), the image
    /// pushed in by `zoom` about its center.
    static func fillSource(image: CGImage, rect: CGRect, zoom: Double) -> CGRect {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard iw > 0, ih > 0, rect.width > 0, rect.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let scale = max(rect.width / iw, rect.height / ih) * CGFloat(max(zoom, 1e-3))
        let w = rect.width / scale / iw, h = rect.height / scale / ih
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}

// MARK: - Core Graphics

/// The frame drawn by Core Graphics into the buffer's memory: the fallback
/// where Metal is missing, and the reference the GPU frames are tested
/// against.
final class RoadTripCGCanvas: RoadTripFrameCanvas {
    let size: CGSize
    private let ctx: CGContext
    private let pixelBuffer: CVPixelBuffer

    init?(pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let data = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(
                data: data, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            return nil
        }
        // Top-left coordinates, as the map snapshots and the live player.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        self.ctx = ctx
        self.pixelBuffer = pixelBuffer
        self.size = CGSize(width: width, height: height)
    }

    func fill(_ rect: CGRect, color: RoadTripRGBA, rotation: Double) {
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: CGFloat(rotation))
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    func draw(_ image: CGImage, in rect: CGRect, source: CGRect, alpha: Double, rotation: Double, mask: RoadTripMask) {
        ctx.saveGState()
        ctx.setAlpha(CGFloat(alpha))
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: CGFloat(rotation))
        let local = CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        switch mask {
        case .none:
            ctx.clip(to: local)
        case .roundedRect(let radius):
            let r = min(radius, local.width / 2, local.height / 2)
            ctx.addPath(CGPath(roundedRect: local, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.clip()
        case .ellipse:
            ctx.addEllipse(in: local)
            ctx.clip()
        }
        // The whole image laid so that its `source` part covers `local`.
        let w = local.width / max(source.width, 1e-6), h = local.height / max(source.height, 1e-6)
        let whole = CGRect(x: local.minX - source.minX * w, y: local.minY - source.minY * h, width: w, height: h)
        ctx.interpolationQuality = .medium
        // `CGContext.draw` lays an image out for a y-up space: flipped back.
        ctx.translateBy(x: 0, y: whole.minY + whole.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: whole)
        ctx.restoreGState()
    }

    func circle(center: CGPoint, radius: CGFloat, color: RoadTripRGBA) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    func circleShadow(in rect: CGRect, blur: CGFloat, color: RoadTripRGBA) {
        // The shadow alone: the circle far off the canvas, its shadow thrown
        // back onto `rect`.
        let away = size.width * 4
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: away, height: 0), blur: blur, color: color.cgColor)
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fillEllipse(in: rect.offsetBy(dx: -away, dy: 0))
        ctx.restoreGState()
    }

    func stroke(_ lines: [[CGPoint]], styles: [(color: RoadTripRGBA, width: CGFloat)], alpha: Double) {
        let paths = lines.filter { $0.count >= 2 }.map { points -> CGPath in
            let path = CGMutablePath()
            path.addLines(between: points)
            return path
        }
        guard !paths.isEmpty else { return }
        // A see-through line needs a layer (its strokes faded as one).
        let layered = alpha < 1
        ctx.saveGState()
        if layered {
            ctx.setAlpha(CGFloat(alpha))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for style in styles {
            ctx.setStrokeColor(style.color.cgColor)
            ctx.setLineWidth(style.width)
            for path in paths {
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
        if layered { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    func vignette() {
        let colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(0.45).cgColor
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.55, 1.0]) else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(size.width, size.height) * 0.72
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    func finish() {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
}
