import XCTest
import SwiftUI
@testable import ImmichSwiftUI

/// Test double for `AppLockService`. Mirrors `AppLockViewModel` semantics
/// (FM-1/FM-2 mitigations, scene-phase table) but lets tests inject the
/// authentication result without touching `LAContext`.
@MainActor
final class MockAppLockService: AppLockService, @unchecked Sendable {
    var isLocked: Bool
    private(set) var isEnabled: Bool
    var isAuthenticating: Bool = false
    private var isPrivacyMasked = false
    private var promptOnNextActive: Bool

    /// Result returned by `authenticate()`. Default `true` for happy-path wiring tests.
    var authenticateResult: Bool
    /// What the availability probe answers in `requestEnable()`.
    var isAvailable: Bool

    var cover: AppLockCover {
        guard isEnabled else { return .none }
        if isLocked { return .lock }
        return isPrivacyMasked ? .mask : .none
    }

    init(isEnabled: Bool = false, isLocked: Bool? = nil, authenticateResult: Bool = true, isAvailable: Bool = true) {
        self.isEnabled = isEnabled
        self.isLocked = isLocked ?? isEnabled
        self.promptOnNextActive = isEnabled
        self.authenticateResult = authenticateResult
        self.isAvailable = isAvailable
    }

    @discardableResult
    func authenticate() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if authenticateResult { isLocked = false }
        return authenticateResult
    }

    @discardableResult
    func requestEnable() async -> AppLockActivationResult {
        guard !isEnabled else { return .enabled }
        guard !isAuthenticating else { return .inProgress }
        guard isAvailable else { return .unavailable }
        guard await authenticate() else { return .notAuthenticated }
        isEnabled = true
        isLocked = false
        isPrivacyMasked = false
        promptOnNextActive = false
        return .enabled
    }

    func disable() {
        isEnabled = false
        isLocked = false
        isPrivacyMasked = false
        promptOnNextActive = false
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

/// Answers `true` to the first evaluation (the activation prompt), then
/// delegates every later one to `next`, so an evaluator counter such as
/// `PromptProbe.calls` stays at zero after activation.
private actor ActivationGate {
    private var activationPending = true
    private let next: @Sendable () async -> Bool

    init(next: @escaping @Sendable () async -> Bool) {
        self.next = next
    }

    func evaluate() async -> Bool {
        if activationPending {
            activationPending = false
            return true
        }
        return await next()
    }
}

/// An `AppLockViewModel` that went through the real activation path (probe
/// available, first prompt succeeds): enabled, unlocked, cover `.none`, no
/// scene phase received. Later evaluations go to `next`.
@MainActor
func makeActivatedAppLock(then next: @escaping @Sendable () async -> Bool) async -> AppLockViewModel {
    UserDefaults.standard.removeObject(forKey: AppLockViewModel.enabledKey)
    let gate = ActivationGate(next: next)
    let vm = AppLockViewModel(evaluator: { await gate.evaluate() }, availability: { true })
    let result = await vm.requestEnable()
    XCTAssertEqual(result, .enabled)
    return vm
}
