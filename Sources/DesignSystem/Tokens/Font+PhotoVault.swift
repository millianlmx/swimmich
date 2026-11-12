import SwiftUI

// MARK: - PhotoVault Font Tokens
//
// Semantic typographic scale. Every token is built on an iOS text style, so it
// follows the system text size (Dynamic Type, up to AX5). At the default size
// ("Large") each token reproduces the previous fixed point size: `pvBody` 17pt
// (body), `pvCaption` 13pt (footnote)… Immich-flavored heading tokens
// (`pvBodyLarge`, `pvH1`..`pvH6`) mirror the upstream Immich `ImmichTextSize`
// scale, expressed as a text style scaled by the ratio to that style's default
// size so they grow with the setting too.
// `pvNumeric` uses `.monospacedDigit()` so counts / timestamps don't shift
// width while animating. `pvTitleXL` uses `.rounded` for hero numerals.
// A `Font` is a late-binding token resolved in the view's environment, so the
// tokens stay `static let` and nothing is cached or frozen.

extension Font {
    // Legacy / iOS-HIG scale.
    static let pvTitleXL = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let pvTitle   = Font.system(.title, weight: .bold)
    static let pvHeadline = Font.system(.headline, weight: .semibold)
    static let pvBody    = Font.system(.body, weight: .regular)
    static let pvSubhead = Font.system(.subheadline, weight: .regular)
    static let pvCaption = Font.system(.footnote, weight: .regular)
    static let pvNumeric = Font.system(.body, weight: .semibold).monospacedDigit()

    // Immich heading scale (ImmichTextSize).
    static let pvBodyLarge = Font.system(.callout, weight: .semibold)
    static let pvH6 = Font.system(.body, weight: .semibold).scaled(by: 18.0 / 17.0)
    static let pvH5 = Font.system(.title3, weight: .semibold)
    static let pvH4 = Font.system(.title2, weight: .bold).scaled(by: 24.0 / 22.0)
    static let pvH3 = Font.system(.title, weight: .bold).scaled(by: 30.0 / 28.0)
    static let pvH2 = Font.system(.largeTitle, weight: .bold).scaled(by: 36.0 / 34.0)
    static let pvH1 = Font.system(.largeTitle, weight: .bold).scaled(by: 48.0 / 34.0)
}
