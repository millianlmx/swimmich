import Foundation
import UIKit

/// High-performance, thread-safe in-memory cache and decoder for ThumbHash placeholders.
///
/// Decodes the Immich server's base64-encoded ThumbHash representation into smooth
/// placeholder `UIImage`s for the photo timeline grid while the full-resolution
/// thumbnail is fetched from the network or disk cache.
///
/// Premium characteristics:
/// - **Zero-hitch caching**: Backed by `NSCache<NSString, UIImage>` for instant
///   O(1) synchronous hits on scroll-back or re-render.
/// - **Crash-safe parsing**: Defensively validates headers, coefficients, and bounds.
///   Corrupted or truncated server strings return `nil` without trapping.
/// - **Bilinear interpolation**: Low-resolution (~32×32) output renders natively
///   with hardware bilinear filtering for a soft, natural blur.
public final class ThumbHashDecoder: @unchecked Sendable {

    /// Shared app-wide decoder instance.
    public static let shared = ThumbHashDecoder()

    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        // ThumbHash images are ~32×32 bitmaps (~4 KB each); 1,000 entries cost ~4 MB.
        c.countLimit = 1000
        c.totalCostLimit = 16 * 1024 * 1024
        return c
    }()

    public init() {}

    /// Instant synchronous cache check. Used by views during `init` for zero-latency frame-0 display.
    public func cachedImage(for thumbhash: String) -> UIImage? {
        guard !thumbhash.isEmpty else { return nil }
        return cache.object(forKey: thumbhash as NSString)
    }

    /// Resolves the placeholder `UIImage` for a base64 ThumbHash string, checking cache first.
    public func image(for thumbhash: String) -> UIImage? {
        guard !thumbhash.isEmpty else { return nil }
        if let cached = cache.object(forKey: thumbhash as NSString) {
            return cached
        }
        guard let decoded = decode(thumbhash: thumbhash) else { return nil }
        let cost = Int(decoded.size.width * decoded.size.height * 4)
        cache.setObject(decoded, forKey: thumbhash as NSString, cost: cost)
        return decoded
    }

    /// Clears in-memory decoded ThumbHash cache (e.g. on memory warning or tests).
    public func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - ThumbHash Decoding Algorithm

    /// Decodes a base64 or URL-safe base64 ThumbHash string into a `UIImage`.
    public func decode(thumbhash: String) -> UIImage? {
        guard let data = Self.data(fromBase64: thumbhash) else { return nil }
        return decode(data: data)
    }

    /// Decodes raw ThumbHash binary data into a `UIImage`.
    public func decode(data hash: Data) -> UIImage? {
        // ThumbHash header requires at least 5 bytes.
        guard hash.count >= 5 else { return nil }

        let h0 = UInt32(hash[0])
        let h1 = UInt32(hash[1])
        let h2 = UInt32(hash[2])
        let h3 = UInt16(hash[3])
        let h4 = UInt16(hash[4])

        let header24 = h0 | (h1 << 8) | (h2 << 16)
        let header16 = h3 | (h4 << 8)

        let il_dc = header24 & 63
        let ip_dc = (header24 >> 6) & 63
        let iq_dc = (header24 >> 12) & 63

        let l_dc = Float(il_dc) / 63.0
        let p_dc = Float(ip_dc) / 31.5 - 1.0
        let q_dc = Float(iq_dc) / 31.5 - 1.0

        let il_scale = (header24 >> 18) & 31
        let l_scale = Float(il_scale) / 31.0

        let hasAlpha = (header24 >> 23) != 0
        let ip_scale = (header16 >> 3) & 63
        let iq_scale = (header16 >> 9) & 63

        let p_scale = Float(ip_scale) / 63.0
        let q_scale = Float(iq_scale) / 63.0

        let isLandscape = (header16 >> 15) != 0
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : Int(header16 & 7))
        let ly = max(3, isLandscape ? Int(header16 & 7) : (hasAlpha ? 5 : 7))

        var a_dc: Float = 1.0
        var a_scale: Float = 1.0
        if hasAlpha {
            guard hash.count > 5 else { return nil }
            let ia_dc = hash[5] & 15
            let ia_scale = hash[5] >> 4
            a_dc = Float(ia_dc) / 15.0
            a_scale = Float(ia_scale) / 15.0
        }

        // Read AC varying factors (1.25x saturation boost to compensate for quantization).
        let ac_start = hasAlpha ? 6 : 5
        var ac_index = 0

        func decodeChannel(nx: Int, ny: Int, scale: Float) -> [Float]? {
            var ac: [Float] = []
            for cy in 0..<ny {
                var cx = cy > 0 ? 0 : 1
                while cx * ny < nx * (ny - cy) {
                    let byteOffset = ac_start + (ac_index >> 1)
                    guard byteOffset < hash.count else { return nil }
                    let shift = (ac_index & 1) << 2
                    let iac = (hash[byteOffset] >> shift) & 15
                    let fac = (Float(iac) / 7.5 - 1.0) * scale
                    ac.append(fac)
                    ac_index += 1
                    cx += 1
                }
            }
            return ac
        }

        guard let l_ac = decodeChannel(nx: lx, ny: ly, scale: l_scale),
              let p_ac = decodeChannel(nx: 3, ny: 3, scale: p_scale * 1.25),
              let q_ac = decodeChannel(nx: 3, ny: 3, scale: q_scale * 1.25) else {
            return nil
        }

        let a_ac: [Float]
        if hasAlpha {
            guard let decodedA = decodeChannel(nx: 5, ny: 5, scale: a_scale) else { return nil }
            a_ac = decodedA
        } else {
            a_ac = []
        }

        // Aspect ratio and output pixel dimensions (bounded to ~32x32).
        let ratio = max(0.01, approximateAspectRatio(hash: hash))
        let fw = round(ratio > 1 ? 32 : 32 * ratio)
        let fh = round(ratio > 1 ? 32 / ratio : 32)
        let w = max(1, Int(fw))
        let h = max(1, Int(fh))

        let cx_stop = max(lx, hasAlpha ? 5 : 3)
        let cy_stop = max(ly, hasAlpha ? 5 : 3)

        var fx = [Float](repeating: 0, count: cx_stop)
        var fy = [Float](repeating: 0, count: cy_stop)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)

        var pixelOffset = 0
        for y in 0..<h {
            for x in 0..<w {
                var l = l_dc
                var p = p_dc
                var q = q_dc
                var a = a_dc

                // Precompute horizontal DCT basis
                for cx in 0..<cx_stop {
                    fx[cx] = cos(Float.pi / Float(w) * (Float(x) + 0.5) * Float(cx))
                }

                // Precompute vertical DCT basis
                for cy in 0..<cy_stop {
                    fy[cy] = cos(Float.pi / Float(h) * (Float(y) + 0.5) * Float(cy))
                }

                // Decode L
                var j = 0
                for cy in 0..<ly {
                    var cx = cy > 0 ? 0 : 1
                    let fy2 = fy[cy] * 2.0
                    while cx * ly < lx * (ly - cy) {
                        l += l_ac[j] * fx[cx] * fy2
                        j += 1
                        cx += 1
                    }
                }

                // Decode P and Q
                j = 0
                for cy in 0..<3 {
                    var cx = cy > 0 ? 0 : 1
                    let fy2 = fy[cy] * 2.0
                    while cx < 3 - cy {
                        let f = fx[cx] * fy2
                        p += p_ac[j] * f
                        q += q_ac[j] * f
                        j += 1
                        cx += 1
                    }
                }

                // Decode Alpha
                if hasAlpha {
                    j = 0
                    for cy in 0..<5 {
                        var cx = cy > 0 ? 0 : 1
                        let fy2 = fy[cy] * 2.0
                        while cx < 5 - cy {
                            a += a_ac[j] * fx[cx] * fy2
                            j += 1
                            cx += 1
                        }
                    }
                }

                // Convert LPQA -> RGB
                let b = l - (2.0 / 3.0) * p
                let r = (3.0 * l - b + q) / 2.0
                let g = r - q

                var clampedR = max(0.0, min(1.0, r)) * 255.0
                var clampedG = max(0.0, min(1.0, g)) * 255.0
                var clampedB = max(0.0, min(1.0, b)) * 255.0
                let clampedA = max(0.0, min(1.0, a)) * 255.0

                // Premultiply alpha for CoreGraphics premultipliedLast bitmap
                if clampedA < 255.0 {
                    let alphaScale = clampedA / 255.0
                    clampedR *= alphaScale
                    clampedG *= alphaScale
                    clampedB *= alphaScale
                }

                rgba[pixelOffset] = UInt8(clampedR.rounded())
                rgba[pixelOffset + 1] = UInt8(clampedG.rounded())
                rgba[pixelOffset + 2] = UInt8(clampedB.rounded())
                rgba[pixelOffset + 3] = UInt8(clampedA.rounded())
                pixelOffset += 4
            }
        }

        let cfData = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: cfData) else { return nil }
        guard let cgImage = CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .perceptual
        ) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    /// Approximate aspect ratio decoded from the ThumbHash header.
    public func approximateAspectRatio(hash: Data) -> Float {
        guard hash.count >= 5 else { return 1.0 }
        let header = hash[3]
        let hasAlpha = (hash[2] & 0x80) != 0
        let isLandscape = (hash[4] & 0x80) != 0
        let lx = isLandscape ? (hasAlpha ? 5 : 7) : Int(header & 7)
        let ly = isLandscape ? Int(header & 7) : (hasAlpha ? 5 : 7)
        guard ly > 0 else { return 1.0 }
        return Float(lx) / Float(ly)
    }

    // MARK: - Base64 Helper

    private static func data(fromBase64 string: String) -> Data? {
        var base64 = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = base64.count % 4
        if rem > 0 {
            base64.append(String(repeating: "=", count: 4 - rem))
        }
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }
}
