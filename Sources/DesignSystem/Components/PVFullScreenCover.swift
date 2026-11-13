import SwiftUI

// MARK: - Full-screen cover that fades under Reduce Motion
//
// Every full-screen presentation of the app goes through `pvFullScreenCover`.
//
//  - `.system`       — setting off: the system presentation, which slides up from the bottom.
//  - `.fade`         — setting on: no system animation; the cover is transparent and its
//                      content fades in (and out, before the cover is removed).
//  - `.selfAnimated` — the presented content animates itself (the zoomed photo viewer):
//                      the plain `fullScreenCover` on the caller's binding, clear background.
//
// Invariant: the content of a fading cover draws its own opaque backdrop (the
// photo viewer, the memory player, RoadTrip and the shared-link pager all do), since
// the cover's own background is clear so that the fade shows the screen beneath.

/// Constant identity for the `isPresented:` flavour.
private struct PVCoverToken: Identifiable {
    let id = 0
}

/// Set by the authenticated root to ask every `pvFullScreenCover` below it to
/// close: a new value is a new request, `nil` is "none yet".
extension EnvironmentValues {
    @Entry var coverDismissalRequest: UUID? = nil
}

private struct PVFullScreenCoverModifier<Item: Identifiable, Cover: View>: ViewModifier {
    @Binding var item: Item?
    let onDismiss: (() -> Void)?
    let selfAnimated: Bool
    let cover: (Item) -> Cover

    @PVReduceMotion private var reduceMotion
    /// What the system cover is actually presenting (mirror of `item`).
    @State private var shown: Item?
    @State private var coverOpacity: Double = 1
    /// Frozen at each presentation: a setting flip while open does not change its close.
    @State private var presentedStyle: PVCoverStyle = .system
    @State private var closing = false
    /// A signal from the root to close whatever full-screen cover is up (a
    /// widget link must reach its target, and a presentation is refused while
    /// another occupies the screen).
    @Environment(\.coverDismissalRequest) private var coverDismissalRequest

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: coverBinding, onDismiss: onDismiss) { presented in
                cover(presented)
                    .modifier(PVCoverChrome(style: selfAnimated ? .selfAnimated : presentedStyle, opacity: coverOpacity))
                    .onAppear { fadeIn() }
            }
            .onChange(of: item?.id, initial: true) { _, _ in
                externalChanged()
            }
            .onChange(of: coverDismissalRequest) { _, _ in
                guard item != nil else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { item = nil }
            }
    }

    /// The binding the system cover reads and writes.
    private var coverBinding: Binding<Item?> {
        if selfAnimated { return $item }
        return Binding(
            get: { shown },
            set: { newValue in
                if let newValue {
                    shown = newValue
                    item = newValue
                } else {
                    close()
                }
            }
        )
    }

    private func externalChanged() {
        guard !selfAnimated else { return }
        if let incoming = item {
            guard incoming.id != shown?.id else { return }
            let style = PVMotion.coverStyle(selfAnimated: false, reduceMotion: reduceMotion)
            presentedStyle = style
            switch style {
            case .fade:
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    coverOpacity = 0
                    shown = incoming
                }
            case .system, .selfAnimated:
                shown = incoming
            }
        } else if shown != nil {
            close()
        }
    }

    private func fadeIn() {
        guard !selfAnimated, presentedStyle == .fade, coverOpacity < 1 else { return }
        withAnimation(PVMotion.fade) { coverOpacity = 1 }
    }

    private func close() {
        guard !closing, shown != nil else { return }
        switch presentedStyle {
        case .fade:
            closing = true
            withAnimation(PVMotion.fade, completionCriteria: .removed) {
                coverOpacity = 0
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    shown = nil
                    item = nil
                    coverOpacity = 1
                    closing = false
                }
            }
        case .system, .selfAnimated:
            shown = nil
            item = nil
        }
    }
}

/// Transparent cover background and fade opacity, applied per style.
private struct PVCoverChrome: ViewModifier {
    let style: PVCoverStyle
    let opacity: Double

    func body(content: Content) -> some View {
        switch style {
        case .system:
            content
        case .selfAnimated:
            content.presentationBackground(.clear)
        case .fade:
            content
                .presentationBackground(.clear)
                .opacity(opacity)
        }
    }
}

extension View {
    /// `fullScreenCover(item:)` whose presentation and dismissal are a fade under
    /// Reduce Motion. `selfAnimated`: the content animates itself — the cover is
    /// presented and removed as before, with a clear background.
    func pvFullScreenCover<Item: Identifiable, C: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        selfAnimated: Bool = false,
        @ViewBuilder content: @escaping (Item) -> C
    ) -> some View {
        modifier(PVFullScreenCoverModifier(item: item, onDismiss: onDismiss, selfAnimated: selfAnimated, cover: content))
    }

    /// `fullScreenCover(isPresented:)` flavour of `pvFullScreenCover(item:)`.
    func pvFullScreenCover<C: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> C
    ) -> some View {
        pvFullScreenCover(
            item: Binding<PVCoverToken?>(
                get: { isPresented.wrappedValue ? PVCoverToken() : nil },
                set: { isPresented.wrappedValue = $0 != nil }
            ),
            onDismiss: onDismiss
        ) { _ in content() }
    }
}
