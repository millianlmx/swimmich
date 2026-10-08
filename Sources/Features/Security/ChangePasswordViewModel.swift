import Foundation
import Observation

/// Screen state for the change-password form (gap G18).
///
/// The validation is local and runs before any network call: the server only
/// bounds the new password at `minLength: 8`, so an entry it would have to
/// refuse must never cost a round trip.
///
/// Nothing here outlives the screen and nothing here is written to disk: the
/// three fields hold the user's secret in memory, and the `shouldChangePassword`
/// flag belongs to `AuthViewModel`, which owns the session.
@MainActor
@Observable
final class ChangePasswordViewModel {
    private let client: any ImmichClient

    // MARK: - Input

    var currentPassword = ""
    var newPassword = ""
    var confirmPassword = ""
    /// The API defaults to `false`; this screen opens only to replace a secret,
    /// so the question is asked and opted out of rather than answered silently.
    var invalidateSessions = true

    // MARK: - Local rules
    //
    // Each one mirrors something the server can refuse. `8` is the lower bound
    // of `ChangePasswordDto.newPassword`.

    var newPasswordTooShort: Bool { !newPassword.isEmpty && newPassword.count < 8 }
    var confirmationMismatch: Bool { !confirmPassword.isEmpty && confirmPassword != newPassword }
    var newPasswordUnchanged: Bool { !newPassword.isEmpty && newPassword == currentPassword }

    // MARK: - Execution

    var isSubmitting = false
    var errorMessage: String?
    var didSucceed = false

    var canSubmit: Bool {
        !isSubmitting
            && !currentPassword.isEmpty
            && newPassword.count >= 8
            && newPassword == confirmPassword
            && newPassword != currentPassword
    }

    init(client: any ImmichClient) {
        self.client = client
    }

    /// Sends the change. Returns the server's updated user — the caller turns
    /// that into `AuthViewModel.notePasswordChanged()` — and `nil` on failure,
    /// leaving the three fields intact so a typo costs one character and not
    /// the whole form.
    func submit() async -> UserAdminResponseDto? {
        guard canSubmit else { return nil }
        isSubmitting = true
        didSucceed = false
        defer { isSubmitting = false }
        do {
            let response = try await client.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword,
                invalidateSessions: invalidateSessions
            )
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            didSucceed = true
            return response
        } catch {
            // A wrong current password is this route's 400
            // (`auth.service.ts:133`), never a 401: the session survives, so
            // this must not read as one. The transport only carries the raw
            // response body, and this is the one failure the user can act on —
            // it gets the catalog's own wording instead.
            if case .serverError(400, _) = APIError.from(error) {
                errorMessage = String(localized: "That password is not right.")
            } else {
                errorMessage = error.userFacingMessage
            }
            return nil
        }
    }

    /// Drops a server message as soon as the user edits a field: it described
    /// the entry that is no longer on screen.
    func clearError() {
        errorMessage = nil
    }

    /// Back to an untouched form. The screen calls it when it appears, so a
    /// previous visit leaves neither a message nor a success behind.
    func resetForm() {
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
        didSucceed = false
        errorMessage = nil
    }
}
