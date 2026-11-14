import Foundation
import LocalAuthentication
import SwiftUI

/// What the dedicated lock window shows on top of the whole scene.
/// `.mask` is the privacy cover (app switcher, Control Center); `.lock` asks
/// for authentication.
enum AppLockCover: Equatable {
    case none, mask, lock
}

/// Outcome of `AppLockViewModel.requestEnable()`.
/// `.unavailable`: the device cannot authenticate (explain why).
/// `.notAuthenticated`: the user failed or cancelled (stay silent).
/// `.inProgress`: a prompt is already on screen.
enum AppLockActivationResult: Equatable {
    case enabled, unavailable, notAuthenticated, inProgress
}

/// Why an authentication attempt left the app locked (AC-63, AC-803).
enum AppLockFailure: Equatable {
    case notRecognized, cancelled, lockedOut, passcodeNotSet, other
}

extension AppLockFailure {
    /// Text shown under the lock title (catalog keys, en/fr/de/es/it).
    var reason: LocalizedStringResource {
        switch self {
        case .notRecognized: "You weren't recognized. Try again."
        case .cancelled: "Face ID didn't recognize you, or the request was cancelled. Try again."
        case .lockedOut: "Face ID or Touch ID is locked after too many attempts. Unlock your iPhone with its passcode, then try again."
        case .passcodeNotSet: "This iPhone has no passcode, so Swimmich can't confirm it's you. Set a passcode in Settings, then try again."
        case .other: "Authentication didn't succeed. Try again."
        }
    }
}

/// Result of one authentication attempt. `.interrupted`: the system or the app
/// cancelled the prompt (backgrounding), which is not a failure to report.
enum AppLockEvaluation: Equatable {
    case success, failed(AppLockFailure), interrupted

    /// Pure mapping of an `evaluatePolicy` reply (or a `canEvaluatePolicy` error).
    static func from(success: Bool, error: Error?) -> AppLockEvaluation {
        if success { return .success }
        guard let laError = error as? LAError else { return .failed(.other) }
        switch laError.code {
        case .authenticationFailed: return .failed(.notRecognized)
        case .userCancel, .userFallback: return .failed(.cancelled)
        case .biometryLockout: return .failed(.lockedOut)
        case .passcodeNotSet: return .failed(.passcodeNotSet)
        case .systemCancel, .appCancel: return .interrupted
        default: return .failed(.other)
        }
    }
}

/// Concrete app-lock state. Wraps LocalAuthentication with an injectable
/// evaluator so unit tests never touch LAContext.
///
/// Source of truth for `isEnabled` lives in UserDefaults (key
/// `app_lock_enabled`), written only by a successful `requestEnable()` and by
/// `disable()`; `ProfileView` binds its toggle to `isEnabled`. `isLocked` /
/// `isAuthenticating` are in-memory `@Observable` state.
///
/// Lifecycle: `scenePhaseChanged(to:)` is the single entry point (idempotent:
/// UIKit scene notifications and SwiftUI's `scenePhase` both feed it).
/// `onCoverChange` fires synchronously on every `cover` change so the lock
/// window is in place before iOS captures the app-switcher snapshot.
@Observable
@MainActor
final class AppLockViewModel: AppLockService {
    nonisolated static let enabledKey = "app_lock_enabled"

    private(set) var isEnabled: Bool
    var isLocked: Bool = false
    var isAuthenticating: Bool = false
    private(set) var isPrivacyMasked = false
    /// Why the last authentication failed; nil at launch, after a success, after
    /// a system interruption and whenever the app locks again (AC-63).
    private(set) var failure: AppLockFailure?

    /// Title of the lock screen's single button: "Try Again" once a reason shows.
    var unlockButtonTitle: LocalizedStringResource {
        failure == nil ? "Unlock" : "Try Again"
    }

    /// Single subscriber: the lock window controller.
    @ObservationIgnored var onCoverChange: ((AppLockCover) -> Void)?
    @ObservationIgnored private var publishedCover: AppLockCover = .none
    /// A prompt is expected on the next `.active` (cold launch, return from
    /// `.background`). Never set by a bare `.inactive` round trip.
    @ObservationIgnored private var promptOnNextActive: Bool
    @ObservationIgnored private var lastPhase: ScenePhase?

    private let evaluator: @Sendable () async -> AppLockEvaluation
    private let availability: @Sendable () -> Bool

    var cover: AppLockCover {
        guard isEnabled else { return .none }
        if isLocked { return .lock }
        return isPrivacyMasked ? .mask : .none
    }

    init(
        evaluator: @Sendable @escaping () async -> AppLockEvaluation = AppLockViewModel.systemAuthenticator,
        availability: @Sendable @escaping () -> Bool = AppLockViewModel.systemAvailability
    ) {
        self.evaluator = evaluator
        self.availability = availability
        // AC-113: fresh launch must be locked when the feature is enabled,
        // otherwise force-quit bypasses the gate.
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        self.isEnabled = enabled
        self.isLocked = enabled
        self.promptOnNextActive = enabled
        self.publishedCover = cover
    }

    /// The only way to turn the lock on. Order matters and nothing awaits
    /// before the evaluator runs, so two quick calls cannot both reach it.
    /// The key is written only after a successful authentication: a kill
    /// during the prompt relaunches unlocked and off.
    func requestEnable() async -> AppLockActivationResult {
        guard !isEnabled else { return .enabled }
        guard !isAuthenticating else { return .inProgress }
        guard availability() else { return .unavailable }
        // `authenticate()` holds `isAuthenticating` for the whole prompt
        // (FM-1), so the `.inactive` it causes neither masks nor locks.
        let activated = await authenticate()
        // A failed activation never shows a reason: the lock screen is not up.
        failure = nil
        guard activated else { return .notAuthenticated }
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        isEnabled = true
        // The user just authenticated: no lock until the next `.background`.
        isLocked = false
        isPrivacyMasked = false
        promptOnNextActive = false
        publishCover()
        return .enabled
    }

    /// Immediate, no authentication (B-30).
    func disable() {
        isEnabled = false
        failure = nil
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        // FM-2: turning the feature off must also release any active lock,
        // otherwise the user stays trapped behind the overlay.
        isLocked = false
        isPrivacyMasked = false
        promptOnNextActive = false
        publishCover()
    }

    func lock() {
        // FM-1: never re-lock while a biometric prompt is already in flight
        // (LAContext flips scenePhase to .inactive during evaluation).
        guard !isAuthenticating else { return }
        guard isEnabled else { return }
        failure = nil
        isLocked = true
        promptOnNextActive = true
        publishCover()
    }

    @discardableResult
    func authenticate() async -> Bool {
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let outcome = await evaluator()
        switch outcome {
        case .success:
            isLocked = false
            failure = nil
        case .failed(let reason):
            failure = reason
        case .interrupted:
            // The system cancelled the prompt (app backgrounded): no reason, the
            // next `.active` prompts again.
            failure = nil
        }
        publishCover()
        return outcome == .success
    }

    /// Returns the prompt task when this transition must start one.
    @discardableResult
    func scenePhaseChanged(to phase: ScenePhase) -> Task<Bool, Never>? {
        guard phase != lastPhase else { return nil }
        lastPhase = phase
        switch phase {
        case .background:
            isPrivacyMasked = isEnabled
            lock()
            if isEnabled && isLocked { promptOnNextActive = true }
            publishCover()
            return nil
        case .inactive:
            isPrivacyMasked = isEnabled
            publishCover()
            return nil
        case .active:
            isPrivacyMasked = false
            let shouldPrompt = promptOnNextActive && isEnabled && isLocked && !isAuthenticating
            promptOnNextActive = false
            publishCover()
            return shouldPrompt ? Task { await self.authenticate() } : nil
        @unknown default:
            return nil
        }
    }

    private func publishCover() {
        let current = cover
        guard current != publishedCover else { return }
        publishedCover = current
        onCoverChange?(current)
    }

    /// Reason shown in the system Face ID / passcode prompt.
    nonisolated static let unlockReason: LocalizedStringResource = "Unlock Swimmich"

    /// Production authenticator: Face ID / Touch ID with passcode fallback via
    /// `.deviceOwnerAuthentication` (AC-106). The policy includes the device
    /// passcode, so a device with a passcode but no enrolled biometry still
    /// prompts (falls back to the passcode screen). The outcome says why an
    /// attempt failed (AC-63); `systemAvailability` tells "cannot authenticate"
    /// apart before an activation.
    static let systemAuthenticator: @Sendable () async -> AppLockEvaluation = {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            return AppLockEvaluation.from(success: false, error: policyError)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<AppLockEvaluation, Never>) in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: AppLockViewModel.unlockReason)
            ) { success, error in
                continuation.resume(returning: AppLockEvaluation.from(success: success, error: error))
            }
        }
    }

    /// Boolean form for callers that only need "did it succeed"
    /// (`LockedFolderViewModel`'s PIN replay).
    static let systemEvaluator: @Sendable () async -> Bool = {
        await systemAuthenticator() == .success
    }

    /// Production availability probe: can this device authenticate its owner
    /// at all? Called on every activation request, never cached.
    static let systemAvailability: @Sendable () -> Bool = {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }
}
