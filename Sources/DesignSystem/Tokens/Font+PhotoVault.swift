import SwiftUI

// MARK: - PhotoVault Font Tokens
//
// Semantic typographic scale. `pvBody` stays at iOS-HIG 17pt (body) for native
// readability; Immich-flavored heading tokens (`pvBodyLarge`, `pvH1`..`pvH6`)
// mirror the upstream Immich `ImmichTextSize` scale for chrome / hero text.
// `pvNumeric` uses `.monospacedDigit()` so counts / timestamps don't shift
// width while animating. `pvTitleXL` uses `.rounded` for hero numerals.

extension Font {
    // Legacy / iOS-HIG scale (unchanged for body readability).
    static let pvTitleXL = Font.system(size: 34, weight: .bold, design: .rounded)
    static let pvTitle   = Font.system(size: 28, weight: .bold)
    static let pvHeadline = Font.system(size: 17, weight: .semibold)
    static let pvBody    = Font.system(size: 17, weight: .regular)
    static let pvSubheadSize: CGFloat = 15
    static let pvCaptionSize: CGFloat = 13
    static let pvSubhead = Font.system(size: pvSubheadSize, weight: .regular)
    static let pvCaption = Font.system(size: pvCaptionSize, weight: .regular)
    static let pvNumeric = Font.system(size: 17, weight: .semibold).monospacedDigit()

    // Immich heading scale (ImmichTextSize).
    static let pvBodyLarge = Font.system(size: 16, weight: .semibold)
    static let pvH6 = Font.system(size: 18, weight: .semibold)
    static let pvH5 = Font.system(size: 20, weight: .semibold)
    static let pvH4 = Font.system(size: 24, weight: .bold)
    static let pvH3 = Font.system(size: 30, weight: .bold)
    static let pvH2 = Font.system(size: 36, weight: .bold)
    static let pvH1 = Font.system(size: 48, weight: .bold)
}
