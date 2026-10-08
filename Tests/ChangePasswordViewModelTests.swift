import XCTest
@testable import ImmichSwiftUI

/// Change-password screen (gap G18).
///
/// Every case drives the real `ChangePasswordViewModel` against
/// `MockImmichClient`: what is asserted is what the user sees and what the
/// server would receive, never how the ViewModel keeps its own state.
@MainActor
final class ChangePasswordViewModelTests: XCTestCase {

    private func makeVM(_ mock: MockImmichClient) -> ChangePasswordViewModel {
        ChangePasswordViewModel(client: mock)
    }

    /// A form the server would accept, so a case only has to break the single
    /// rule it is about.
    private func fillValid(_ vm: ChangePasswordViewModel) {
        vm.currentPassword = "current-secret"
        vm.newPassword = "brand-new-secret"
        vm.confirmPassword = "brand-new-secret"
    }

    // MARK: - Local validation, before any network call

    func test_canSubmit_requiresCurrentPassword() {
        let vm = makeVM(MockImmichClient())
        vm.newPassword = "brand-new-secret"
        vm.confirmPassword = "brand-new-secret"

        XCTAssertFalse(vm.canSubmit, "the server requires the current password, so an empty field cannot be sent")

        vm.currentPassword = "current-secret"
        XCTAssertTrue(vm.canSubmit)
    }

    func test_canSubmit_rejectsShortNewPassword() {
        let vm = makeVM(MockImmichClient())
        vm.currentPassword = "current-secret"
        vm.newPassword = "short12" // 7 characters
        vm.confirmPassword = "short12"

        XCTAssertTrue(vm.newPasswordTooShort)
        XCTAssertFalse(vm.canSubmit, "the server's floor is minLength: 8")
    }

    func test_canSubmit_rejectsMismatchedConfirmation() {
        let vm = makeVM(MockImmichClient())
        vm.currentPassword = "current-secret"
        vm.newPassword = "brand-new-secret"
        vm.confirmPassword = "brand-new-secrte"

        XCTAssertTrue(vm.confirmationMismatch)
        XCTAssertFalse(vm.canSubmit)
    }

    func test_canSubmit_rejectsUnchangedPassword() {
        let vm = makeVM(MockImmichClient())
        vm.currentPassword = "same-secret-1"
        vm.newPassword = "same-secret-1"
        vm.confirmPassword = "same-secret-1"

        XCTAssertTrue(vm.newPasswordUnchanged)
        XCTAssertFalse(vm.canSubmit, "re-sending the current password changes nothing")
    }

    // MARK: - What reaches the server

    func test_submit_sendsThreeDtoFieldsAndInvalidateFlag() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock)
        fillValid(vm)
        vm.invalidateSessions = false

        _ = await vm.submit()

        XCTAssertEqual(mock.requestCount, 1)
        XCTAssertEqual(mock.lastChangePasswordBody?.password, "current-secret")
        XCTAssertEqual(mock.lastChangePasswordBody?.newPassword, "brand-new-secret")
        XCTAssertEqual(mock.lastChangePasswordBody?.invalidateSessions, false)
    }

    func test_submit_signsOutOtherDevicesByDefault() async {
        let mock = MockImmichClient()
        let vm = makeVM(mock)
        fillValid(vm)

        _ = await vm.submit()

        XCTAssertEqual(mock.lastChangePasswordBody?.invalidateSessions, true, "the question is asked, and answered yes until the user says otherwise")
    }

    // MARK: - Success and failure

    func test_submit_clearsFieldsAndReportsSuccess() async {
        let mock = MockImmichClient()
        mock.changePasswordResponse = UserAdminResponseDto(
            id: "me", name: "Me", email: "me@example.com", profileImagePath: nil,
            avatarColor: nil, profileChangedAt: nil, shouldChangePassword: false
        )
        let vm = makeVM(mock)
        fillValid(vm)

        let response = await vm.submit()

        XCTAssertEqual(response?.shouldChangePassword, false, "the caller gets the server's own confirmation back")
        XCTAssertTrue(vm.didSucceed)
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.currentPassword.isEmpty, "an accepted secret must not stay in the form")
        XCTAssertTrue(vm.newPassword.isEmpty)
        XCTAssertTrue(vm.confirmPassword.isEmpty)
        XCTAssertFalse(vm.canSubmit)
    }

    func test_submit_keepsFieldsAndSurfacesErrorOnWrongCurrentPassword() async {
        let mock = MockImmichClient()
        // Exactly what this route answers for a wrong current password: a 400,
        // not a 401 (`auth.service.ts:133`), so the session survives the typo.
        mock.changePasswordError = APIError.serverError(400, #"{"message":"Wrong password","error":"Bad Request"}"#)
        let vm = makeVM(mock)
        fillValid(vm)

        let response = await vm.submit()

        XCTAssertNil(response)
        XCTAssertEqual(vm.errorMessage, localizedString("That password is not right."))
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertFalse(vm.didSucceed)
        XCTAssertEqual(vm.currentPassword, "current-secret", "a typo costs one character, not the whole form")
        XCTAssertEqual(vm.newPassword, "brand-new-secret")
        XCTAssertEqual(vm.confirmPassword, "brand-new-secret")
        XCTAssertTrue(vm.canSubmit)
    }

    func test_submit_reportsANetworkFailureAsItself() async {
        let mock = MockImmichClient()
        let offline = APIError.network(URLError(.notConnectedToInternet))
        mock.changePasswordError = offline
        let vm = makeVM(mock)
        fillValid(vm)

        _ = await vm.submit()

        XCTAssertEqual(vm.errorMessage, UserFacingError.offlineMessage, "an unreachable server is not a wrong password")
        XCTAssertNotEqual(vm.errorMessage, localizedString("That password is not right."))
        XCTAssertEqual(vm.currentPassword, "current-secret")
    }

    func test_submit_isNotReentrantWhileInFlight() async {
        let mock = MockImmichClient()
        // Holds the first submit inside the client so the second one
        // deterministically meets the in-flight guard (without a gate the mock
        // can answer before the second call even starts).
        mock.changePasswordGate = { try? await Task.sleep(nanoseconds: 200_000_000) }
        let vm = makeVM(mock)
        fillValid(vm)

        let first = Task { await vm.submit() }
        // Let the first submit reach the client and park on the gate.
        while mock.lastChangePasswordBody == nil { await Task.yield() }

        let second = await vm.submit()
        let firstResponse = await first.value

        XCTAssertNil(second, "a second submit while one is in flight is refused")
        XCTAssertNotNil(firstResponse)
        XCTAssertEqual(mock.requestCount, 1)
    }
}
