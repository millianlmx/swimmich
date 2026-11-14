import Foundation
import CoreGraphics

// MARK: - CropAspectRatio

/// Predefined crop aspect ratios (cahier §5 L119).
/// `value` returns nil for freeform (uncropped).
/// AC-601.
enum CropAspectRatio: String, CaseIterable, Codable, Sendable {
    case freeform
    case square
    case fourByThree
    case threeByTwo
    case twoByThree
    case sixteenByNine
    case nineBySixteen

    /// width / height. Nil = freeform.
    var value: CGFloat? {
        switch self {
        case .freeform:     return nil
        case .square:       return 1.0
        case .fourByThree:  return 4.0 / 3.0
        case .threeByTwo:   return 3.0 / 2.0
        case .twoByThree:   return 2.0 / 3.0
        case .sixteenByNine: return 16.0 / 9.0
        case .nineBySixteen: return 9.0 / 16.0
        }
    }
}

// MARK: - EditState

/// Non-destructive local edit state for an asset (cahier §5 L117-125).
///
/// - `cropRect` is **normalized 0..1 relative to the ORIGINAL extent** (FM-4):
///   origin top-left UIKit-style, where (0,0) = top-left, (1,1) = bottom-right.
///   Conversion to CoreImage bottom-left pixels happens in `EditPipeline.applyEditState`.
/// - `orientationSteps` (0/1/2/3 = 0°/90°/180°/270° CW) and `straightenDeg` (-45..+45)
///   are **independent** controls (Photos-like; one does not clobber the other) — resolved
///   loop 1 challenger objection S1.
/// - Adjustments use their respective CIFilter neutral-point at 0.
///
/// Codable + Equatable + Sendable (AC-600). JSON roundtrip via JSONEncoder.immich.
struct EditState: Codable, Equatable, Sendable {
    var cropRect: CGRect?          // normalized 0..1, UIKit top-left origin
    var orientationSteps: Int = 0  // 0/1/2/3
    var straightenDeg: Double = 0  // -45..+45
    var aspectRatio: CropAspectRatio?
    var exposure: Double = 0       // -2..+2 (EV)
    var contrast: Double = 0       // -1..+1
    var saturation: Double = 0     // -1..+1
    var warmth: Double = 0         // -1..+1
    /// Left-right flip, in the frame of the oriented, cropped image, applied BEFORE the quarter
    /// turns (same meaning as the official client's `flipHorizontal`).
    var mirrorHorizontal: Bool = false
    /// Top-bottom flip, same frame and order as `mirrorHorizontal`.
    var mirrorVertical: Bool = false

    private enum CodingKeys: String, CodingKey {
        case cropRect, orientationSteps, straightenDeg, aspectRatio
        case exposure, contrast, saturation, warmth
        case mirrorHorizontal, mirrorVertical
    }

    /// Identity state (no edits). AC-600.
    static let neutral = EditState()

    /// Combined absolute rotation in degrees (orientationSteps × 90 + straightenDeg). AC-600.
    var totalRotationDeg: Double {
        straightenDeg + Double(orientationSteps % 4) * 90
    }

    /// True iff at least one field differs from `.neutral`. AC-602.
    var hasEdits: Bool {
        cropRect != nil
            || orientationSteps != 0
            || straightenDeg != 0
            || aspectRatio != nil
            || exposure != 0
            || contrast != 0
            || saturation != 0
            || warmth != 0
            || mirrorHorizontal
            || mirrorVertical
    }

    /// True when the server's edit list (crop, quarter turns, mirror) can express the state:
    /// no free straightening and no colour adjustment.
    var isServerExpressible: Bool {
        straightenDeg == 0 && exposure == 0 && contrast == 0 && saturation == 0 && warmth == 0
    }
}

extension EditState {
    /// A draft written before the mirror fields existed reads them as `false`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cropRect = try c.decodeIfPresent(CGRect.self, forKey: .cropRect)
        orientationSteps = try c.decodeIfPresent(Int.self, forKey: .orientationSteps) ?? 0
        straightenDeg = try c.decodeIfPresent(Double.self, forKey: .straightenDeg) ?? 0
        aspectRatio = try c.decodeIfPresent(CropAspectRatio.self, forKey: .aspectRatio)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        mirrorHorizontal = try c.decodeIfPresent(Bool.self, forKey: .mirrorHorizontal) ?? false
        mirrorVertical = try c.decodeIfPresent(Bool.self, forKey: .mirrorVertical) ?? false
    }
}
