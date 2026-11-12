import SwiftUI
import UIKit

// MARK: - Swimmich logo palette
//
// The mark's own two-colour palette, derived from the interface accent
// `Color.immichPrimary` (indigo #4250AF in light appearance, pale blue #ACCBFA in
// dark). The accent is dynamic; the mark is not, so each end is `immichPrimary`
// resolved once for a fixed appearance: the pale end is its dark value, the deep
// end its light value. Retune the accent and the mark follows.
//
// These are not theme colours. The mark does not change between light and dark
// appearance, so each one is a single, appearance-invariant value rather than an
// asset-catalog colourset with a `luminosity: dark` twin. That also keeps
// `ImmichMark` drawable in targets and harnesses that carry no asset catalog
// (the share extension, unit tests, previews).
//
// `.omp/brand/render-icon.swift` mirrors these two values by hand for the app
// icon: if the accent changes, change `stops` there and re-run it.

extension Color {

    /// The mark's pale end — `immichPrimary` in dark appearance, #ACCBFA.
    static let immichLogoLight = Color(
        uiColor: UIColor(Color.immichPrimary)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
    )

    /// The mark's deep end — `immichPrimary` in light appearance, #4250AF.
    static let immichLogoDeep = Color(
        uiColor: UIColor(Color.immichPrimary)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    )
}

// MARK: - The mark's gradient
//
// The pair, swept across the mark's span: the left side leaves in the pale blue,
// the right side arrives in the indigo. Spanwise because the mark's thick part is
// its middle, where a vertical sweep would bury its own stops. One definition, so
// the app bar, the badge and the icon can never drift apart.

extension LinearGradient {

    /// The Swimmich pair, edge to edge.
    static let immichLogo = LinearGradient(
        colors: [.immichLogoLight, .immichLogoDeep],
        startPoint: .leading,
        endPoint: .trailing
    )
}
