import Observation
import UIKit

/// `IdleTimerControlling` on the real `UIApplication`: reads and writes go
/// straight to the system flag, so a hold taken later restores exactly what it
/// found. The class is `@Observable` for the viewer's test probe, which
/// re-evaluates when the flag changes.
@Observable
@MainActor
final class SystemIdleTimer: IdleTimerControlling {
    var isIdleTimerDisabled: Bool {
        get {
            access(keyPath: \.isIdleTimerDisabled)
            return UIApplication.shared.isIdleTimerDisabled
        }
        set {
            withMutation(keyPath: \.isIdleTimerDisabled) {
                UIApplication.shared.isIdleTimerDisabled = newValue
            }
        }
    }
}
