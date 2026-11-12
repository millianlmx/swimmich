import SwiftUI

// MARK: - Reduce Motion plumbing
//
// `@PVReduceMotion` is the only reader of the system setting (plus the UI-test
// switch, see `PVMotion.isReduced`). It re-reads the environment at every render,
// so flipping the setting while the app is open applies to the next interaction
// without a relaunch.

/// `@PVReduceMotion private var reduceMotion` — true when the user asked to
/// reduce motion (or the UI-test switch is on).
@propertyWrapper
struct PVReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system

    init() {}

    var wrappedValue: Bool {
        PVMotion.isReduced(system: system)
    }
}

// MARK: - Scroll effect (parallax)

private struct PVScrollEffectModifier: ViewModifier {
    let scale: CGFloat
    let opacity: Double
    let anchor: UnitPoint
    @PVReduceMotion private var reduceMotion

    func body(content: Content) -> some View {
        // Values are read here, outside the `@Sendable` scroll closure, which then
        // does nothing but apply them.
        let reduced = reduceMotion
        let itemScale = scale
        let itemOpacity = opacity
        let itemAnchor = anchor
        return content.scrollTransition { effectContent, phase in
            Self.apply(effectContent, phase: phase, scale: itemScale, opacity: itemOpacity, anchor: itemAnchor, reduced: reduced)
        }
    }

    private static func apply(
        _ content: EmptyVisualEffect,
        phase: ScrollTransitionPhase,
        scale: CGFloat,
        opacity: Double,
        anchor: UnitPoint,
        reduced: Bool
    ) -> some VisualEffect {
        let effect = PVMotion.scrollEffect(
            isIdentity: phase.isIdentity,
            scale: scale,
            opacity: opacity,
            reduceMotion: reduced
        )
        return content.scaleEffect(effect.scale, anchor: anchor).opacity(effect.opacity)
    }
}

// MARK: - Symbol bounce

private struct PVSymbolBounceModifier<V: Equatable>: ViewModifier {
    let value: V
    @PVReduceMotion private var reduceMotion

    func body(content: Content) -> some View {
        // Same structure in both modes: flipping the setting never recreates the view.
        content
            .symbolEffect(.bounce, value: value)
            .symbolEffectsRemoved(PVMotion.symbolEffectsRemoved(reduceMotion: reduceMotion))
    }
}

extension View {
    /// Parallax at the edge of the screen: scale and opacity ease toward the given
    /// values as the item leaves. Identity (no effect) under Reduce Motion.
    func pvScrollEffect(scale: CGFloat, opacity: Double, anchor: UnitPoint = .center) -> some View {
        modifier(PVScrollEffectModifier(scale: scale, opacity: opacity, anchor: anchor))
    }

    /// `symbolEffect(.bounce)` that stays still under Reduce Motion.
    func pvSymbolBounce<V: Equatable>(value: V) -> some View {
        modifier(PVSymbolBounceModifier(value: value))
    }
}
