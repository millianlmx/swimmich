import SwiftUI

/// Abstraction over device-local app lock (Face ID / Touch ID / passcode).
/// `@MainActor` matches the `AppLockViewModel` impl; conformers are UI-layer
/// `@Observable` view models.
@MainActor
protocol AppLockService: AnyObject {
    var isLocked: Bool { get }
    var isEnabled: Bool { get }
    var isAuthenticating: Bool { get }
    /// What the lock window must show right now (privacy mask vs. lock).
    var cover: AppLockCover { get }
    func authenticate() async -> Bool
    /// The only way to turn the lock on: probes availability, then
    /// authenticates. There is no synchronous activation.
    func requestEnable() async -> AppLockActivationResult
    /// Immediate, no authentication.
    func disable()
    func lock()
    /// Single lifecycle entry point; returns the prompt task when the
    /// transition must start an authentication.
    @discardableResult
    func scenePhaseChanged(to phase: ScenePhase) -> Task<Bool, Never>?
}
