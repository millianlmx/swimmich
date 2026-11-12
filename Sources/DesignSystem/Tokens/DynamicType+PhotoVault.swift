import SwiftUI
import UIKit

// MARK: - Dynamic Type tools
//
// Lives in `Tokens/` because the share extension compiles that folder too
// (`project.yml`), and `ShareConfirmationView` uses these tools.
//
// Text follows the system text size up to AX5 everywhere, except two layout
// exemptions: thumbnail tile content (capped at the default size) and
// full-screen chrome text (capped at AX2). Glyph-only controls keep their fixed
// frame and stop growing at xxxLarge, like the system bars.

enum PVTypeCap {
    /// Text drawn inside a thumbnail tile: stays at the default size.
    static let tileContent: DynamicTypeSize = .large
    /// Text laid over full-screen media (viewer, slideshow, memory playback).
    static let fullscreenChrome: DynamicTypeSize = .accessibility2
    /// Glyph-only controls in a fixed frame. Never applied to a view holding a `Text`.
    static let glyphControl: DynamicTypeSize = .xxxLarge
}

extension View {
    func pvTileTextCap() -> some View { dynamicTypeSize(...PVTypeCap.tileContent) }
    func pvFullscreenChromeTextCap() -> some View { dynamicTypeSize(...PVTypeCap.fullscreenChrome) }
    func pvGlyphControlCap() -> some View { dynamicTypeSize(...PVTypeCap.glyphControl) }
}

/// The only way to measure text outside a view (layout maths, tests).
enum PVFontMetrics {
    static func resolved(_ font: Font, at size: DynamicTypeSize) -> Font.Resolved {
        var environment = EnvironmentValues()
        environment.dynamicTypeSize = size
        return font.resolve(in: environment.fontResolutionContext)
    }

    static func uiFont(_ font: Font, at size: DynamicTypeSize) -> UIFont {
        // CTFont and UIFont are toll-free bridged.
        unsafeBitCast(resolved(font, at: size).ctFont, to: UIFont.self)
    }

    static func lineHeight(_ font: Font, at size: DynamicTypeSize) -> CGFloat {
        uiFont(font, at: size).lineHeight
    }
}

/// A row on one line, or a column at accessibility sizes. The children keep
/// their identity across the switch.
struct PVAdaptiveStack<Content: View>: View {
    private let hAlignment: VerticalAlignment
    private let vAlignment: HorizontalAlignment
    private let spacing: CGFloat?
    private let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        hAlignment: VerticalAlignment = .center,
        vAlignment: HorizontalAlignment = .leading,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.hAlignment = hAlignment
        self.vAlignment = vAlignment
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: vAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: hAlignment, spacing: spacing))
        layout { content }
    }
}

/// `LabeledContent` that puts the value under its label at accessibility sizes.
/// At the other sizes the system rendering is untouched.
struct PVAdaptiveLabeledContentStyle: LabeledContentStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: PVSpacing.s4) {
                configuration.label
                configuration.content
                    .foregroundStyle(Color.textSecondaryPV)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LabeledContent(configuration)
        }
    }
}

extension LabeledContentStyle where Self == PVAdaptiveLabeledContentStyle {
    static var pvAdaptive: PVAdaptiveLabeledContentStyle { PVAdaptiveLabeledContentStyle() }
}
