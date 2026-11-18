import SwiftUI

// MARK: - PVHeaderBadge
//
// "Badge bg-accent" header mark (PRD §5.10 Écran 1): a large icon in a soft
// indigo wash, used as the hero of onboarding/auth screen headers — the
// visual anchor the plain 36pt icons of the input screens were missing. The
// badge exposes itself as a VoiceOver header via `.accessibilityAddTraits`.
//
// Two flavours, one wash: an SF Symbol for the step screens (`icon:`), or any
// view SF Symbols has no equivalent for. Keeping the wash, the 72-pt tile and
// the header trait in one place is what keeps the badges alike. (The welcome
// screen shows the app's icon instead, `SwimmichLogo`.)

/// Icon-in-wash hero badge for onboarding/auth screen headers.
struct PVHeaderBadge<Icon: View>: View {
    private let icon: Icon

    /// SF Symbol flavour — the input/step screens.
    init(icon systemName: String) where Icon == Image {
        self.icon = Image(systemName: systemName)
    }

    /// Arbitrary-glyph flavour — brand marks and anything SF Symbols has no
    /// equivalent for. `.font`/`.foregroundStyle` below are no-ops for it.
    init(@ViewBuilder icon: () -> Icon) {
        self.icon = icon()
    }

    var body: some View {
        icon
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(Color.immichPrimary)
            .frame(width: 72, height: 72)
            .background(Color.immichPrimary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
            .accessibilityAddTraits(.isHeader)
    }
}
