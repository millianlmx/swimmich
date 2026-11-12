import SwiftUI

// MARK: - PhotoVault Motion Tokens
//
// Three named springs cover the app's motion language, and a "gate" decides what
// a view gets when the user turned Reduce Motion on. Views never call
// `withAnimation`, `.animation`, `.transition`, ... with a raw animation: they go
// through the functions below, which hand back either the requested animation
// (setting off — nothing changes) or something that only changes opacity, or
// nothing at all (setting on). `Tests/MotionGuardTests.swift` fails the build on
// any site that bypasses the gate.
//
//  - `movement`   — anything that moves, resizes, scales or scrolls: `nil` when reduced.
//  - `fading`     — sites whose change only animates opacities once reduced: the fade.
//  - `appearance` — insertion/removal transitions: a fade when reduced.
//  - `contentChange`, `scale`, `offset`, `scrollEffect`, `shimmerLoop`, ... — the same
//    rule for the other motion carriers.
//
// The setting is read by `@PVReduceMotion` (PVMotionModifiers.swift), the only reader
// of `accessibilityReduceMotion`.
//
// `PVDuration` mirrors the Immich `ImmichDuration` scale (ms) for any caller
// that needs a raw TimeInterval (custom transitions, debounce haptics, etc.).

enum PVMotion {
    static let standard: Animation = .spring(response: 0.35, dampingFraction: 0.86)
    static let snappy: Animation = .spring(response: 0.25, dampingFraction: 0.75)
    static let gentle: Animation = .easeInOut(duration: 0.5)

    /// The cross-fade: opacity only, allowed in both modes.
    static let fade: Animation = .linear(duration: 0.3)

    // MARK: - Reading the setting

    /// Launch-argument switch (`-uiTestReduceMotion YES`) a UI test uses to get the
    /// reduced-motion behaviour: the system flag cannot be injected. Never written
    /// outside tests.
    static let uiTestReduceMotionKey = "uiTestReduceMotion"

    /// Read once per process.
    static let uiTestReduceMotion: Bool = UserDefaults.standard.bool(forKey: uiTestReduceMotionKey)

    /// The system flag, or the test switch.
    static func isReduced(system: Bool, testSwitch: Bool = uiTestReduceMotion) -> Bool {
        system || testSwitch
    }

    // MARK: - Animations

    /// For any change that moves, resizes, scales or scrolls: no animation when reduced.
    static func movement(_ requested: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : requested
    }

    /// For sites whose change only animates opacities once reduced (closed list in
    /// `MotionGuardTests`): the fade when reduced.
    static func fading(_ requested: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : requested
    }

    static func scale(_ value: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : value
    }

    static func offset(_ value: CGFloat, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : value
    }

    // MARK: - Transitions

    static func appearance(_ requested: PVTransition, reduceMotion: Bool) -> PVTransition {
        reduceMotion ? .fade : requested
    }

    // MARK: - Scroll effect

    static func scrollEffect(isIdentity: Bool, scale: CGFloat, opacity: Double, reduceMotion: Bool) -> PVScrollEffect {
        if isIdentity || reduceMotion { return PVScrollEffect(scale: 1, opacity: 1) }
        return PVScrollEffect(scale: scale, opacity: opacity)
    }

    // MARK: - Symbols and contents

    static func contentChange(_ requested: ContentTransition, reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .opacity : requested
    }

    static func symbolEffectsRemoved(reduceMotion: Bool) -> Bool {
        reduceMotion
    }

    // MARK: - Loading shimmer

    static func shimmerLoop(duration: TimeInterval, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .linear(duration: duration).repeatForever(autoreverses: false)
    }

    static func shimmerVisible(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    // MARK: - Full-screen covers

    static func coverStyle(selfAnimated: Bool, reduceMotion: Bool) -> PVCoverStyle {
        if selfAnimated { return .selfAnimated }
        return reduceMotion ? .fade : .system
    }
}

/// The insertion/removal transitions the app uses.
enum PVTransition: Equatable {
    case opacity
    case fade
    case opacityAndScale(CGFloat)
    case opacityAndMove(Edge)

    var anyTransition: AnyTransition {
        switch self {
        case .opacity:
            return .opacity
        case .fade:
            return .opacity.animation(PVMotion.fade)
        case .opacityAndScale(let s):
            return .opacity.combined(with: .scale(scale: s))
        case .opacityAndMove(let e):
            return .opacity.combined(with: .move(edge: e))
        }
    }
}

/// Scale and opacity a scrolling item takes at the edge of the screen.
struct PVScrollEffect: Equatable {
    var scale: CGFloat
    var opacity: Double
}

/// Immich `ImmichDuration` scale bridged to `TimeInterval` (seconds).
enum PVDuration {
    static let extraFast: TimeInterval = 0.10
    static let fast: TimeInterval = 0.15
    static let normal: TimeInterval = 0.20
    static let moderate: TimeInterval = 0.30
    static let slow: TimeInterval = 0.50
    static let extraSlow: TimeInterval = 0.70
}
