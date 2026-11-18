import SwiftUI

// MARK: - ImmichAppBar
//
// The title of a pushed screen or a sheet, placed in
// `ToolbarItem(placement: .principal)`: the title alone, in the bar's own
// type, like a native inline title. It used to sit beside the app's former
// mark (a petal lens, since removed) — a logo in the middle of a settings
// screen or a filter sheet had nothing to say there anyway.
//
// Native compromise: SwiftUI toolbar background, scrolling behaviour, and
// safe-area insets remain iOS-native (no Material elevation), per the
// "Immich-flavored native SwiftUI" approach.

/// Title of a screen's navigation bar.
/// Drop into `ToolbarItem(placement: .principal)`.
struct ImmichAppBar: View {
    /// A key, not a `String`: a literal passed to a `String` property is never
    /// extracted by the compiler and never translated (it rendered verbatim).
    let title: LocalizedStringKey
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(title: LocalizedStringKey = "Swimmich") {
        self.title = title
    }

    var body: some View {
        // At accessibility sizes the title moves into the content
        // (`immichAppBarTitleHeader`), where it can wrap.
        if !dynamicTypeSize.isAccessibilitySize {
            Text(title)
                .font(.pvHeadline)
                .foregroundStyle(Color.textPrimaryPV)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

private struct ImmichAppBarTitleHeader: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(title)
                    .font(.pvH6)
                    .foregroundStyle(Color.textPrimaryPV)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PVSpacing.s16)
                    .padding(.vertical, PVSpacing.s8)
                    .background(Color.bgPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("appBarTitleHeader")
            }
        }
    }
}

extension View {
    /// Shows the app bar title in the content at accessibility sizes, where
    /// `ImmichAppBar` draws nothing. Pass the key given to `ImmichAppBar`.
    func immichAppBarTitleHeader(_ title: LocalizedStringKey) -> some View {
        modifier(ImmichAppBarTitleHeader(title: title))
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
