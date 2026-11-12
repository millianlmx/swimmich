import SwiftUI

/// Floating Liquid Glass banner telling the user that the language they just
/// picked is only fully applied after a reopen (issue #21).
///
/// Non-blocking and single-action on purpose: the choice is already persisted,
/// most of the UI has already switched (the view tree re-renders through the
/// injected locale), and the strings built outside a render — view models,
/// notifications, widget copy — are resolved from the bundle at launch. iOS
/// has no supported way to restart an app, so the banner states the fact
/// instead of offering a button that could not do what it says.
struct LanguageToast: View {
    /// The only answer: acknowledge and drop the notice.
    var onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Entrance only: the banner fades — and slides, unless Reduce Motion is on
    /// — into place when the parent inserts it.
    @State private var isVisible = false

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .top, spacing: PVSpacing.s12) {
                Image(systemName: "globe")
                    .font(.system(size: 20, weight: .semibold))

                Text("Language changed. Some text updates after you reopen the app.")
                    .font(.pvSubhead)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: PVSpacing.s0)

                Button {
                    onDismiss()
                } label: {
                    Text("Got It")
                        .font(.pvSubhead.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("languageToastDismiss")
            }
            .padding(PVSpacing.s16)
            .pvFloating(.bar)
        }
        .padding(.horizontal, PVSpacing.s16)
        .opacity(isVisible ? 1 : 0)
        .offset(y: isVisible || reduceMotion ? 0 : PVSpacing.s12)
        // No `accessibilityIdentifier` on the container: SwiftUI propagates it to
        // every descendant and OVERRIDES theirs, which would hide the button's
        // own identifier from the UI tests.
        .onAppear {
            withAnimation(PVMotion.adaptive(PVMotion.snappy, reduceMotion: reduceMotion)) {
                isVisible = true
            }
        }
    }
}
