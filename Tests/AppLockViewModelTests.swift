import SwiftUI
import XCTest
@testable import ImmichSwiftUI

final class AppLockViewModelTests: XCTestCase {

    private func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: AppLockViewModel.enabledKey)
    }

    override func tearDown() {
        resetDefaults()
    }

    // AC-108(a): init with isEnabled=true (persisted) → isLocked=true (fresh-launch locked).
    @MainActor
    func test_AC_108a_initEnabledIsLocked() {
        resetDefaults()
        UserDefaults.standard.set(true, forKey: AppLockViewModel.enabledKey)
        let vm = AppLockViewModel(evaluator: { true })
        XCTAssertTrue(vm.isEnabled)
        XCTAssertTrue(vm.isLocked, "fresh launch with feature on must start locked (AC-113)")
    }

    // AC-108(b): disable() → isLocked=false (FM-2 mitigation).
    @MainActor
    func test_AC_108b_disableUnlocks() {
        resetDefaults()
        UserDefaults.standard.set(true, forKey: AppLockViewModel.enabledKey)
        let vm = AppLockViewModel(evaluator: { true })
        XCTAssertTrue(vm.isLocked)

        vm.disable()
        XCTAssertFalse(vm.isEnabled)
        XCTAssertFalse(vm.isLocked, "disabling must release any active lock")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppLockViewModel.enabledKey))
    }

    // AC-108(c): enabled + lock() → isLocked=true.
    @MainActor
    func test_AC_108c_lockSetsIsLocked() async {
        let vm = await makeActivatedAppLock(then: { true })
        XCTAssertFalse(vm.isLocked, "activation alone does not lock")

        vm.lock()
        XCTAssertTrue(vm.isLocked)
    }

    // AC-108(d): authenticate(fake=true) → isLocked=false, returns true.
    @MainActor
    func test_AC_108d_authenticateSuccessUnlocks() async {
        resetDefaults()
        let vm = await makeActivatedAppLock(then: { true })
        vm.lock()
        XCTAssertTrue(vm.isLocked)

        let ok = await vm.authenticate()
        XCTAssertTrue(ok)
        XCTAssertFalse(vm.isLocked)
        XCTAssertFalse(vm.isAuthenticating)
    }

    // AC-108(e): authenticate(fake=false) → isLocked stays true, returns false.
    @MainActor
    func test_AC_108e_authenticateFailureStaysLocked() async {
        resetDefaults()
        let vm = await makeActivatedAppLock(then: { false })
        vm.lock()
        XCTAssertTrue(vm.isLocked)

        let ok = await vm.authenticate()
        XCTAssertFalse(ok)
        XCTAssertTrue(vm.isLocked, "failed auth must keep the lock")
    }

    // AC-108(f): lock() during isAuthenticating==true is a no-op (FM-1).
    @MainActor
    func test_AC_108f_lockDuringAuthIsNoOp() async {
        resetDefaults()

        // Evaluator blocks on a continuation held inside an actor; we release
        // it from the test body, so isAuthenticating is reliably true when we
        // call lock().
        actor Latch {
            private var continuation: CheckedContinuation<Bool, Never>?
            func wait() async -> Bool {
                await withCheckedContinuation { self.continuation = $0 }
            }
            func release(_ value: Bool) {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let latch = Latch()
        let evaluator: @Sendable () async -> Bool = { await latch.wait() }

        let vm = await makeActivatedAppLock(then: evaluator)
        XCTAssertTrue(vm.isEnabled)

        async let authResult: Bool = vm.authenticate()
        // Spin until the evaluator has flipped isAuthenticating.
        for _ in 0..<200 where !vm.isAuthenticating {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(vm.isAuthenticating, "evaluator should be blocking → isAuthenticating true")

        let lockedBefore = vm.isLocked
        vm.lock() // MUST be a no-op while authenticating.
        XCTAssertEqual(vm.isLocked, lockedBefore, "lock() must not fire during auth (FM-1)")

        await latch.release(true)
        let ok = await authResult
        XCTAssertTrue(ok)
        XCTAssertFalse(vm.isLocked)
    }

    // AC-111: default evaluator wiring is the LAContext-backed system path
    // (verified by source grep AC-100/AC-106; here we assert the default
    // init compiles and the type matches the injectable signature).
    @MainActor
    func test_AC_111_defaultEvaluatorCompiles() {
        resetDefaults()
        let vm = AppLockViewModel() // uses AppLockViewModel.systemEvaluator by default
        XCTAssertFalse(vm.isEnabled)
        XCTAssertFalse(vm.isLocked)
    }
}

/// Evaluator double: counts calls and, when `blocking`, holds the prompt open
/// until `release(_:)`. A release arriving before the wait is not lost.
private actor PromptProbe {
    private(set) var calls = 0
    private(set) var isWaiting = false
    private let blocking: Bool
    private let result: Bool
    private var continuation: CheckedContinuation<Bool, Never>?
    private var early: Bool?

    init(blocking: Bool = false, result: Bool = false) {
        self.blocking = blocking
        self.result = result
    }

    func evaluate() async -> Bool {
        calls += 1
        guard blocking else { return result }
        if let early { return early }
        isWaiting = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ value: Bool) {
        if let continuation { continuation.resume(returning: value) } else { early = value }
        continuation = nil
    }
}

extension AppLockViewModelTests {
    @MainActor
    private func makeEnabled(_ probe: PromptProbe) async -> AppLockViewModel {
        await makeActivatedAppLock(then: { await probe.evaluate() })
    }

    @MainActor
    private func waitUntilPromptIsShown(_ probe: PromptProbe) async {
        var attempts = 0
        while attempts < 400, !(await probe.isWaiting) {
            attempts += 1
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // AC-10: a failed prompt is never relaunched by a later `.active`.
    @MainActor
    func test_AC_10_failedPromptIsNotRelaunched() async {
        let probe = PromptProbe(result: false)
        let vm = await makeEnabled(probe)
        vm.scenePhaseChanged(to: .background)
        let task = vm.scenePhaseChanged(to: .active)
        XCTAssertNotNil(task)
        _ = await task?.value
        let afterFirst = await probe.calls
        XCTAssertEqual(afterFirst, 1)

        XCTAssertNil(vm.scenePhaseChanged(to: .inactive))
        XCTAssertNil(vm.scenePhaseChanged(to: .active))
        let afterRoundTrip = await probe.calls
        XCTAssertEqual(afterRoundTrip, 1)
        XCTAssertEqual(vm.cover, .lock)

        let ok = await vm.authenticate()
        XCTAssertFalse(ok)
        let afterExplicit = await probe.calls
        XCTAssertEqual(afterExplicit, 2)
    }

    // AC-11: the mask is published inside the `.inactive` call, no await.
    @MainActor
    func test_AC_11_inactivePublishesMaskSynchronously() async {
        let vm = await makeEnabled(PromptProbe())
        var covers: [AppLockCover] = []
        vm.onCoverChange = { covers.append($0) }
        vm.scenePhaseChanged(to: .inactive)
        XCTAssertEqual(covers, [.mask])
    }

    // AC-12: Control Center round trip unmasks without prompting.
    @MainActor
    func test_AC_12_inactiveRoundTripUnmasksWithoutPrompt() async {
        let probe = PromptProbe()
        let vm = await makeEnabled(probe)
        vm.scenePhaseChanged(to: .inactive)
        XCTAssertEqual(vm.cover, .mask)
        XCTAssertNil(vm.scenePhaseChanged(to: .active))
        XCTAssertEqual(vm.cover, .none)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }

    // AC-13: lock disabled → nothing is ever covered or published.
    @MainActor
    func test_AC_13_disabledNeverCovers() async {
        resetDefaults()
        let probe = PromptProbe()
        let vm = AppLockViewModel(evaluator: { await probe.evaluate() })
        var published = 0
        vm.onCoverChange = { _ in published += 1 }
        for phase in [ScenePhase.inactive, .background, .active] {
            XCTAssertNil(vm.scenePhaseChanged(to: phase))
            XCTAssertEqual(vm.cover, .none, "phase \(phase)")
        }
        XCTAssertEqual(published, 0)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }

    // AC-16 (model clause): enabling does not lock; the next background does.
    @MainActor
    func test_AC_16_enabledThenBackgroundLocksAndPrompts() async {
        resetDefaults()
        let probe = PromptProbe(result: true)
        let vm = await makeActivatedAppLock(then: { await probe.evaluate() })
        XCTAssertEqual(vm.cover, .none)
        vm.scenePhaseChanged(to: .background)
        XCTAssertEqual(vm.cover, .lock)
        let task = vm.scenePhaseChanged(to: .active)
        XCTAssertNotNil(task)
        _ = await task?.value
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(vm.cover, .none)
    }

    // AC-17: cold launch is locked and prompts exactly once, on first `.active`.
    @MainActor
    func test_AC_17_coldLaunchPromptsOnceOnFirstActive() async {
        resetDefaults()
        UserDefaults.standard.set(true, forKey: AppLockViewModel.enabledKey)
        let probe = PromptProbe(result: false)
        let vm = AppLockViewModel(evaluator: { await probe.evaluate() })
        XCTAssertEqual(vm.cover, .lock)
        XCTAssertNil(vm.scenePhaseChanged(to: .inactive))
        let task = vm.scenePhaseChanged(to: .active)
        XCTAssertNotNil(task)
        _ = await task?.value
        XCTAssertNil(vm.scenePhaseChanged(to: .inactive))
        XCTAssertNil(vm.scenePhaseChanged(to: .active))
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    // AC-18: disabling releases the lock; nothing locks afterwards.
    @MainActor
    func test_AC_18_disableThenBackgroundNeverLocks() async {
        let probe = PromptProbe()
        let vm = await makeEnabled(probe)
        vm.scenePhaseChanged(to: .background)
        XCTAssertEqual(vm.cover, .lock)
        vm.disable()
        XCTAssertEqual(vm.cover, .none)
        vm.scenePhaseChanged(to: .active)
        vm.scenePhaseChanged(to: .background)
        XCTAssertEqual(vm.cover, .none)
        XCTAssertNil(vm.scenePhaseChanged(to: .active))
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppLockViewModel.enabledKey))
    }

    // AC-19: the prompt's own `.inactive`/`.active` churn neither re-locks nor re-prompts.
    @MainActor
    func test_AC_19_promptInactiveRoundTripSucceedsOnce() async {
        let probe = PromptProbe(blocking: true)
        let vm = await makeEnabled(probe)
        vm.scenePhaseChanged(to: .background)
        let task = vm.scenePhaseChanged(to: .active)
        XCTAssertNotNil(task)
        await waitUntilPromptIsShown(probe)

        vm.scenePhaseChanged(to: .inactive)
        XCTAssertEqual(vm.cover, .lock)
        XCTAssertNil(vm.scenePhaseChanged(to: .active))
        vm.scenePhaseChanged(to: .inactive)

        await probe.release(true)
        let ok = await task?.value
        XCTAssertEqual(ok, true)
        XCTAssertEqual(vm.cover, .mask)
        XCTAssertNil(vm.scenePhaseChanged(to: .active))
        XCTAssertEqual(vm.cover, .none)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    // AC-19 (S-3): a second authenticate() while one is in flight is a no-op.
    @MainActor
    func test_AC_19_concurrentAuthenticateRunsEvaluatorOnce() async {
        let probe = PromptProbe(blocking: true)
        let vm = await makeEnabled(probe)
        vm.lock()
        async let first = vm.authenticate()
        await waitUntilPromptIsShown(probe)
        let second = await vm.authenticate()
        XCTAssertFalse(second)
        XCTAssertTrue(vm.isLocked, "the rejected call must not touch isLocked")
        await probe.release(true)
        let firstResult = await first
        XCTAssertTrue(firstResult)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    // AC-20: a lock persisted by the previous version still gates the app.
    @MainActor
    func test_AC_20_persistedEnabledSurvivesUpgrade() {
        resetDefaults()
        UserDefaults.standard.set(true, forKey: AppLockViewModel.enabledKey)
        let vm = AppLockViewModel(evaluator: { true })
        XCTAssertTrue(vm.isEnabled)
        XCTAssertTrue(vm.isLocked)
        XCTAssertEqual(vm.cover, .lock)
    }

    // AC-22: Control Center while locked after a cancelled prompt does not re-prompt.
    @MainActor
    func test_AC_22_inactiveRoundTripWhileLockedDoesNotPrompt() async {
        let probe = PromptProbe(result: false)
        let vm = await makeEnabled(probe)
        vm.scenePhaseChanged(to: .background)
        let task = vm.scenePhaseChanged(to: .active)
        _ = await task?.value

        vm.scenePhaseChanged(to: .inactive)
        XCTAssertEqual(vm.cover, .lock)
        XCTAssertNil(vm.scenePhaseChanged(to: .active))
        XCTAssertEqual(vm.cover, .lock)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }
}

// Activation conditioned on authentication (B-5/B-6/B-30/B-31). Prefixed
// `test_Activation_AC_` so a search for "AC-n" never hits the sister feature.
extension AppLockViewModelTests {
    private var keyIsOn: Bool { UserDefaults.standard.bool(forKey: AppLockViewModel.enabledKey) }

    // AC-14: device cannot authenticate → refused, no prompt, no key, no lock.
    @MainActor
    func test_Activation_AC_14_unavailableRefusesWithoutPrompt() async {
        resetDefaults()
        let probe = PromptProbe(result: true)
        let vm = AppLockViewModel(evaluator: { await probe.evaluate() }, availability: { false })
        var published = 0
        vm.onCoverChange = { _ in published += 1 }

        let result = await vm.requestEnable()
        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(vm.isEnabled)
        XCTAssertFalse(keyIsOn)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0, "no prompt when the device cannot authenticate")

        vm.scenePhaseChanged(to: .background)
        XCTAssertNil(vm.scenePhaseChanged(to: .active))
        XCTAssertEqual(vm.cover, .none)
        XCTAssertEqual(published, 0)
    }

    // AC-15: failed or cancelled prompt → silent refusal, key untouched.
    @MainActor
    func test_Activation_AC_15_failedPromptStaysOff() async {
        resetDefaults()
        let probe = PromptProbe(result: false)
        let vm = AppLockViewModel(evaluator: { await probe.evaluate() }, availability: { true })

        let result = await vm.requestEnable()
        XCTAssertEqual(result, .notAuthenticated)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(vm.isEnabled)
        XCTAssertFalse(keyIsOn)
        XCTAssertFalse(vm.isLocked)
        XCTAssertFalse(vm.isAuthenticating)
        XCTAssertEqual(vm.cover, .none)
    }

    // AC-16: success persists, does not lock, and the next background locks.
    @MainActor
    func test_Activation_AC_16_successEnablesThenBackgroundLocks() async {
        resetDefaults()
        let probe = PromptProbe(result: true)
        let vm = AppLockViewModel(evaluator: { await probe.evaluate() }, availability: { true })

        let result = await vm.requestEnable()
        XCTAssertEqual(result, .enabled)
        XCTAssertTrue(vm.isEnabled)
        XCTAssertTrue(keyIsOn)
        XCTAssertFalse(vm.isLocked, "a successful activation is not followed by a lock")
        XCTAssertEqual(vm.cover, .none)

        let again = await vm.requestEnable()
        XCTAssertEqual(again, .enabled)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1, "already enabled: no second prompt")

        vm.scenePhaseChanged(to: .background)
        XCTAssertEqual(vm.cover, .lock)
        XCTAssertNotNil(vm.scenePhaseChanged(to: .active))
    }

    // AC-30: the prompt's own scene-phase churn neither masks nor locks.
    @MainActor
    func test_Activation_AC_30_promptChurnNeitherMasksNorLocks() async {
        resetDefaults()
        let probe = PromptProbe(blocking: true)
        let vm = AppLockViewModel(evaluator: { await probe.evaluate() }, availability: { true })
        var published = 0
        vm.onCoverChange = { _ in published += 1 }

        async let result = vm.requestEnable()
        await waitUntilPromptIsShown(probe)
        XCTAssertTrue(vm.isAuthenticating)

        vm.scenePhaseChanged(to: .inactive)
        XCTAssertEqual(vm.cover, .none)
        XCTAssertNil(vm.scenePhaseChanged(to: .active))
        vm.scenePhaseChanged(to: .inactive)
        vm.lock()
        XCTAssertFalse(vm.isLocked)
        XCTAssertEqual(vm.cover, .none)

        await probe.release(true)
        let outcome = await result
        XCTAssertEqual(outcome, .enabled)
        XCTAssertFalse(vm.isLocked)
        XCTAssertEqual(vm.cover, .none)
        XCTAssertNil(vm.scenePhaseChanged(to: .active))
        XCTAssertEqual(published, 0, "no mask or lock window change during or after activation")
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    // AC-31: disabling is immediate, needs no prompt, and releases the lock.
    @MainActor
    func test_Activation_AC_31_disableIsImmediateAndUnlocks() async {
        let probe = PromptProbe(result: false)
        let vm = await makeEnabled(probe)
        vm.scenePhaseChanged(to: .background)
        XCTAssertEqual(vm.cover, .lock)

        vm.disable()
        XCTAssertFalse(vm.isEnabled)
        XCTAssertFalse(keyIsOn)
        XCTAssertEqual(vm.cover, .none)
        vm.scenePhaseChanged(to: .active)
        vm.scenePhaseChanged(to: .background)
        XCTAssertEqual(vm.cover, .none)
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }

    // AC-32: the key is not written while the prompt is pending, so a kill
    // at that moment relaunches unlocked and off.
    @MainActor
    func test_Activation_AC_32_keyNotWrittenWhilePromptPending() async {
        resetDefaults()
        let probe = PromptProbe(blocking: true)
        let vm = AppLockViewModel(evaluator: { await probe.evaluate() }, availability: { true })

        async let result = vm.requestEnable()
        await waitUntilPromptIsShown(probe)
        XCTAssertFalse(keyIsOn)

        let relaunched = AppLockViewModel(evaluator: { true }, availability: { true })
        XCTAssertFalse(relaunched.isEnabled)
        XCTAssertFalse(relaunched.isLocked)
        XCTAssertEqual(relaunched.cover, .none)

        await probe.release(false)
        let outcome = await result
        XCTAssertEqual(outcome, .notAuthenticated)
        XCTAssertFalse(keyIsOn)
    }

    // AC-35: a second request or an `.active` during the prompt is a no-op.
    @MainActor
    func test_Activation_AC_35_secondRequestDuringPromptIsNoOp() async {
        resetDefaults()
        let probe = PromptProbe(blocking: true)
        let vm = AppLockViewModel(evaluator: { await probe.evaluate() }, availability: { true })

        async let first = vm.requestEnable()
        await waitUntilPromptIsShown(probe)

        let second = await vm.requestEnable()
        XCTAssertEqual(second, .inProgress)
        let direct = await vm.authenticate()
        XCTAssertFalse(direct)
        XCTAssertNil(vm.scenePhaseChanged(to: .active))

        await probe.release(true)
        let firstResult = await first
        XCTAssertEqual(firstResult, .enabled)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }

    // AC-36: no method of the service enables the lock without a successful
    // authentication (the structural half is `private(set) isEnabled` and
    // the absence of `setEnabled`).
    @MainActor
    func test_Activation_AC_36_noMethodEnablesWithoutAuthentication() async {
        for (available, evaluates) in [(false, true), (true, false)] {
            resetDefaults()
            let vm = AppLockViewModel(evaluator: { evaluates }, availability: { available })
            func assertOff(_ step: String) {
                XCTAssertFalse(vm.isEnabled, "available=\(available) after \(step)")
                XCTAssertFalse(keyIsOn, "available=\(available) after \(step)")
            }
            _ = await vm.requestEnable()
            assertOff("requestEnable")
            vm.lock()
            assertOff("lock")
            _ = await vm.authenticate()
            assertOff("authenticate")
            for phase in [ScenePhase.inactive, .background, .active] {
                vm.scenePhaseChanged(to: phase)
                assertOff("scenePhaseChanged(\(phase))")
            }
            vm.disable()
            assertOff("disable")
            _ = await vm.requestEnable()
            assertOff("requestEnable again")
        }
    }
}
