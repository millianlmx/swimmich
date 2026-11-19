import SwiftUI
import UIKit

// MARK: - PhotoVault Floating Controls
//
// The one material for every control that floats above photos or video:
// dark tinted glass with white content, the same in light and dark
// appearance (the photo behind it decides the contrast, not the theme). Three
// roles, three shapes, one style each: `.circle` for an icon button, `.pill`
// for a capsule (badge, position, small menu), `.bar` for a floating bar or
// banner. Screens never write their own glass, material or translucent black.
// Over an interface surface rather than a photo (the map), `pvGlass` gives the
// same three shapes in the system's adaptive glass instead.

/// Tokens of the floating-control style. Every colour drawn directly on the
/// glass comes from here, and each one is checked for WCAG contrast against the
/// glass composited on pure white and pure black (`FloatingControlStyleTests`).
enum PVFloating {
    /// Glass tint.
    static let tint: Color = .black.opacity(0.6)
    /// Glyphs and primary text.
    static let content: Color = .white
    /// Secondary text, inactive segments, placeholders.
    static let secondaryContent: Color = .white.opacity(0.85)
    /// Thumb behind the selected segment of a segmented bar.
    static let selection: Color = .white.opacity(0.1)
    /// Glyph of an active state (OCR on, AirPlay connected, upload running):
    /// `immichPrimary` resolved in dark appearance, fixed in both appearances.
    /// A glyph colour, never a text colour.
    static let accent: Color = Color(
        uiColor: UIColor(Color.immichPrimary)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
    )
}

/// The role a floating control plays; it decides the shape.
enum PVFloatingRole: CaseIterable {
    case circle, pill, bar
}

extension View {
    /// Dresses the view as a floating control of `role`: white content on dark
    /// tinted glass. Apply after the frame / padding that sizes the control and
    /// before its accessibility modifiers.
    func pvFloating(_ role: PVFloatingRole) -> some View {
        foregroundStyle(PVFloating.content)
            .glassEffect(.regular.tint(PVFloating.tint), in: role.shape)
    }
}

extension View {
    /// Dresses the view as a floating control of `role` over an INTERFACE
    /// surface (the map, a list): the system's own adaptive Liquid Glass with
    /// primary content — light in light mode, dark in dark mode, exactly like
    /// the navigation bar and the tab bar it sits next to. `pvFloating` stays
    /// for controls over photos and video, where the media decides the
    /// contrast; side by side with the system chrome its fixed dark tint read
    /// as a different material.
    func pvGlass(_ role: PVFloatingRole) -> some View {
        foregroundStyle(Color.primary)
            .glassEffect(.regular.interactive(), in: role.shape)
    }
}

private extension PVFloatingRole {
    var shape: AnyShape {
        switch self {
        case .circle: AnyShape(Circle())
        case .pill: AnyShape(Capsule())
        case .bar: AnyShape(RoundedRectangle(cornerRadius: PVRadius.xl, style: .continuous))
        }
    }
}
