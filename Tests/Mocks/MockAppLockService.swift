import SwiftUI
@testable import ImmichSwiftUI

/// Test double for `AppLockService`. Mirrors `AppLockViewModel` semantics
/// (FM-1/FM-2 mitigations, scene-phase table) but lets tests inject the
/// authentication result without touching `LAContext`.
@MainActor
final class MockAppLockService: AppLockService, @unchecked Sendable {
    var isLocked: Bool
    var isEnabled: Bool
    var isAuthenticating: Bool = false
    private var isPrivacyMasked = false
    private var promptOnNextActive: Bool

    /// Result returned by `authenticate()`. Default `true` for happy-path wiring tests.
    var authenticateResult: Bool

    var cover: AppLockCover {
        guard isEnabled else { return .none }
        if isLocked { return .lock }
        return isPrivacyMasked ? .mask : .none
    }

    init(isEnabled: Bool = false, isLocked: Bool? = nil, authenticateResult: Bool = true) {
        self.isEnabled = isEnabled
        self.isLocked = isLocked ?? isEnabled
        self.promptOnNextActive = isEnabled
        self.authenticateResult = authenticateResult
    }

    @discardableResult
    func authenticate() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if authenticateResult { isLocked = false }
        return authenticateResult
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            isLocked = false
            isPrivacyMasked = false
            promptOnNextActive = false
        }
    }

    func lock() {
        guard !isAuthenticating, isEnabled else { return }
        isLocked = true
        promptOnNextActive = true
    }

    @discardableResult
    func scenePhaseChanged(to phase: ScenePhase) -> Task<Bool, Never>? {
        switch phase {
        case .background:
            isPrivacyMasked = isEnabled
            lock()
            if isEnabled && isLocked { promptOnNextActive = true }
            return nil
        case .inactive:
            isPrivacyMasked = isEnabled
            return nil
        case .active:
            isPrivacyMasked = false
            let shouldPrompt = promptOnNextActive && isEnabled && isLocked && !isAuthenticating
            promptOnNextActive = false
            return shouldPrompt ? Task { await self.authenticate() } : nil
        @unknown default:
            return nil
        }
    }
}
