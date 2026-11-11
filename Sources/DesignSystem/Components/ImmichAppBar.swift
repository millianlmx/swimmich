import SwiftUI

// MARK: - ImmichAppBar
//
// Immich-flavored app bar identity, placed in `ToolbarItem(placement: .principal)`.
// Renders the app's own mark + "Swimmich" wordmark inline — the recognizable
// top-of-screen identity. The upstream Flutter `ImmichSliverAppBar`
// draws `immich-logo-inline-light.svg` / `-dark.svg`: a logo plus a wordmark PNG
// that differs only by appearance. This app draws its own mark instead
// (`ImmichMark`: a lens whose opening is the petal motif, in the app's accent pair),
// and native text follows the system appearance on its own, so the lockup here
// is the mark + a `Text`, in every app state, from one code path.
//
// Native compromise: SwiftUI toolbar background, scrolling behaviour, and
// safe-area insets remain iOS-native (no Material elevation), per the
// "Immich-flavored native SwiftUI" approach.

/// Swimmich top app bar identity: logo glyph + wordmark.
/// Drop into `ToolbarItem(placement: .principal)` on top-level screens.
struct ImmichAppBar: View {
    /// A key, not a `String`: a literal passed to a `String` property is never
    /// extracted by the compiler and never translated (it rendered verbatim).
    let title: LocalizedStringKey

    init(title: LocalizedStringKey = "Swimmich") {
        self.title = title
    }

    var body: some View {
        ImmichLogo(title: title)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
    }
}

/// Standalone Swimmich mark + wordmark — also reusable outside toolbars
/// (auth screens, launch, empty-state headers).
struct ImmichLogo: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: PVSpacing.s8) {
            // 24: the mark's own bounding box fills the frame, so its ink carries
            // the optical weight the replaced SF Symbol did at this size.
            ImmichMark()
                .frame(width: 24, height: 24)
            Text(title)
                .font(.pvH6)
                .foregroundStyle(Color.textPrimaryPV)
        }
    }
}

// MARK: - Immich bottom-bar styling
//
// Native iOS 26 Liquid Glass floating tab bar (adaptive to content), with the
// Immich indigo active-tab tint. Applied on the root TabView.

private struct ImmichBottomBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(Color.immichPrimary)
    }
}

extension View {
    /// Styles the root `TabView` with the native floating Liquid Glass tab bar
    /// (adaptive) and the Immich indigo active-tab tint.
    func immichBottomBar() -> some View {
        modifier(ImmichBottomBarModifier())
    }
}
