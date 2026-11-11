import SwiftUI

/// The single gate every haptic in the app goes through (settings-parity, gap
/// G22).
///
/// "Haptic Feedback: off" must silence all of them — 29 modifiers across 15
/// files. Replacing each with an `if` would be 29 conditions to keep in sync
/// (and one forgotten call site is a setting that half works), so the switch
/// lives in one `ViewModifier` that renders `nil` instead of the feedback:
/// the SDK's `sensoryFeedback(trigger:_:)` takes a closure returning
/// `SensoryFeedback?`, and `nil` suppresses the response while the view keeps
/// declaring its intent.
///
/// `defaultValue = true` is what makes the gate safe outside the root tree
/// (Xcode previews, views built in isolation): without it, reading an absent
/// environment value would trap.

private struct HapticsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var hapticsEnabled: Bool {
        get { self[HapticsEnabledKey.self] }
        set { self[HapticsEnabledKey.self] = newValue }
    }
}

private struct AppSensoryFeedbackModifier<T: Equatable>: ViewModifier {
    @Environment(\.hapticsEnabled) private var hapticsEnabled

    let feedback: SensoryFeedback
    let trigger: T
    /// Reports the feedback actually handed to SwiftUI (`nil` when haptics are
    /// off). Only UI-test probes pass one; the gate itself stays this closure.
    let onEmit: ((SensoryFeedback?) -> Void)?

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: trigger) { _, _ in
            let played = hapticsEnabled ? feedback : nil
            onEmit?(played)
            return played
        }
    }
}

extension View {
    /// Plays `feedback` when `trigger` changes — unless the user turned haptics
    /// off, in which case nothing plays at all.
    ///
    /// Same call shape as the SDK's `sensoryFeedback(_:trigger:)`, so a call
    /// site only changes the method name.
    func appSensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        appSensoryFeedback(feedback, trigger: trigger, onEmit: nil)
    }

    /// Same gate, plus `onEmit` reporting what the gate returned (see
    /// `MemoryPlaybackView`'s test probe).
    func appSensoryFeedback<T: Equatable>(
        _ feedback: SensoryFeedback,
        trigger: T,
        onEmit: ((SensoryFeedback?) -> Void)?
    ) -> some View {
        modifier(AppSensoryFeedbackModifier(feedback: feedback, trigger: trigger, onEmit: onEmit))
    }
}
