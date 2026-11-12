import SwiftUI

/// Change-password screen (gap G18).
///
/// Pushed from the Me hub's Security section, so it deliberately carries no
/// navigation stack of its own: `ProfileView` already owns one, and a second
/// would draw a second bar (the convention of `LanguageSettingsView` and
/// `ProfilePictureView`).
///
/// The screen does one thing — replace a secret — and everything around it is
/// context: the rules the server can refuse are shown next to the fields rather
/// than discovered by a failed submit, and an error leaves the entry in place,
/// because the user is fixing a typo and not retyping a form.
///
/// Nothing here is persisted and no field is logged: the three passwords live
/// in `ChangePasswordViewModel` for as long as the screen does.
struct ChangePasswordView: View {
    @Bindable var vm: ChangePasswordViewModel
    /// Called once the server accepted the change. Only the auth session owns
    /// `shouldChangePassword`, and this screen does not know about it.
    let onPasswordChanged: () -> Void

    @PVReduceMotion private var reduceMotion

    @State private var isCurrentRevealed = false
    @State private var isNewRevealed = false
    @State private var isConfirmRevealed = false

    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case current
        case new
        case confirm
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: PVSpacing.s8) {
                    Group {
                        if isCurrentRevealed {
                            TextField("Current Password", text: $vm.currentPassword)
                        } else {
                            SecureField("Current Password", text: $vm.currentPassword)
                        }
                    }
                    .accessibilityIdentifier("currentPasswordField")
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .current)
                    .submitLabel(.next)
                    .onSubmit { focused = .new }
                    RevealButton(isRevealed: $isCurrentRevealed)
                }
            } header: {
                Text("Current")
            }

            Section {
                HStack(spacing: PVSpacing.s8) {
                    Group {
                        if isNewRevealed {
                            TextField("New Password", text: $vm.newPassword)
                        } else {
                            SecureField("New Password", text: $vm.newPassword)
                        }
                    }
                    .accessibilityIdentifier("newPasswordField")
                    .textContentType(.newPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .new)
                    .submitLabel(.next)
                    .onSubmit { focused = .confirm }
                    RevealButton(isRevealed: $isNewRevealed)
                }

                HStack(spacing: PVSpacing.s8) {
                    Group {
                        if isConfirmRevealed {
                            TextField("Confirm New Password", text: $vm.confirmPassword)
                        } else {
                            SecureField("Confirm New Password", text: $vm.confirmPassword)
                        }
                    }
                    .accessibilityIdentifier("confirmPasswordField")
                    .textContentType(.newPassword)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused, equals: .confirm)
                    .submitLabel(.done)
                    .onSubmit { send() }
                    RevealButton(isRevealed: $isConfirmRevealed)
                }

                requirementHints
            } header: {
                Text("New")
            }

            Section {
                Toggle("Sign out on other devices", isOn: $vm.invalidateSessions)
                    .accessibilityIdentifier("invalidateSessionsToggle")
            } header: {
                Text("Sessions")
            } footer: {
                Text("Other devices will need to sign in again with the new password. This device stays signed in.")
            }

            Section {
                Button("Change Password") {
                    send()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(!vm.canSubmit)
                .accessibilityIdentifier("changePasswordSubmit")

                if vm.isSubmitting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }

                if let message = vm.errorMessage {
                    InlineErrorBadge(message: message)
                        .transition(.opacity)
                }

                if vm.didSucceed {
                    Label("Your password has been changed.", systemImage: "checkmark.circle.fill")
                        .font(.pvSubhead)
                        .foregroundStyle(Color.immichSuccess)
                        .transition(PVMotion.appearance(.opacityAndMove(.top), reduceMotion: reduceMotion).anyTransition)
                }
            } footer: {
                Text("If you forget this password, an administrator has to reset it from the Immich web interface.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.bgPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ImmichAppBar(title: "Change Password") }
        }
        .immichAppBarTitleHeader("Change Password")
        // Editing a field answers the message that was about the previous
        // entry, and a fresh visit starts from a blank form either way.
        .onChange(of: vm.currentPassword) { _, _ in vm.clearError() }
        .onChange(of: vm.newPassword) { _, _ in vm.clearError() }
        .onChange(of: vm.confirmPassword) { _, _ in vm.clearError() }
        .animation(PVMotion.movement(PVMotion.standard, reduceMotion: reduceMotion), value: vm.errorMessage)
        .animation(PVMotion.movement(PVMotion.standard, reduceMotion: reduceMotion), value: vm.didSucceed)
        .task { vm.resetForm() }
    }

    /// The three rules the server can refuse, shown next to the fields the
    /// moment one is broken. Each line reads a ViewModel rule — the view never
    /// recomputes one.
    @ViewBuilder
    private var requirementHints: some View {
        if vm.newPasswordTooShort {
            hint("At least 8 characters.")
        }
        if vm.confirmationMismatch {
            hint("The two passwords do not match.")
        }
        if vm.newPasswordUnchanged {
            hint("The new password is the same as the current one.")
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.pvCaption)
            .foregroundStyle(Color.immichError)
    }

    /// The single write path: the button and the keyboard's Done key both come
    /// through here, and both refuse a form the server would only reject.
    private func send() {
        guard vm.canSubmit else { return }
        Task {
            if let response = await vm.submit() {
                onPasswordChanged()
                _ = response
            }
        }
    }
}

/// Eye button that switches ONE field between `SecureField` and `TextField`.
///
/// Its own element, not a decoration of the row: a password field is announced
/// as secure text, so the reveal has to be reachable (and labelled) on its own.
private struct RevealButton: View {
    @PVReduceMotion private var reduceMotion
    @Binding var isRevealed: Bool

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            Image(systemName: isRevealed ? "eye.slash" : "eye")
                .foregroundStyle(Color.textSecondaryPV)
                .contentTransition(PVMotion.contentChange(.symbolEffect(.replace), reduceMotion: reduceMotion))
        }
        .buttonStyle(.plain)
        // A 44 pt target, not a 17 pt glyph.
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
    }
}
