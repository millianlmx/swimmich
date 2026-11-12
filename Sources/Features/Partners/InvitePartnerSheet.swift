import SwiftUI

/// Invite sheet: pick a user from the instance directory.
///
/// `POST /api/partners` takes a **user id**, not an email
/// (`server/src/dtos/partner.dto.ts`), so the sheet is a directory picker —
/// there is no free-text invite. The candidate list is the directory minus me
/// minus everyone already in "Sharing".
///
/// `GET /api/users` only returns the current user to a non-admin when the
/// server has `publicUsers` disabled, hence the explicit empty state: an empty
/// list here is a server policy, not a missing feature.
struct InvitePartnerSheet: View {
    @Bindable var vm: PartnersViewModel
    /// Signed-in user id — excluded from the directory.
    let currentUserId: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var auth

    var body: some View {
        NavigationStack {
            Group {
                switch vm.inviteRenderState {
                case .loading:
                    ProgressView()
                        .pvLoadingIndicator("partnerInviteLoading")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .error(let message):
                    PVErrorStateView(
                        title: "Couldn't load users",
                        message: message,
                        identifierPrefix: "partnerInvite",
                        retry: { Task { await vm.loadCandidates(excludingUserId: currentUserId) } }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    ContentUnavailableView {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 56)) // DS-exempt: hero illustration §8.6
                            .foregroundStyle(Color.textTertiaryPV)
                        Text("No one to invite")
                            .font(.pvTitle)
                    } description: {
                        Text("This server does not expose its user list, or everyone on it is already a partner.")
                    }
                case .data:
                    List(vm.filteredCandidates, id: \.id) { user in
                        // Plain button style inside a List swallows the tap on
                        // iOS 26 (same class of defect as the stack picker's
                        // `Button` around `AssetThumbnailCell`), so the row keeps
                        // the default list-button style and sets its own text
                        // colors instead of inheriting the accent tint.
                        Button {
                            vm.selectCandidate(user)
                        } label: {
                            HStack(spacing: PVSpacing.s12) {
                                UserAvatarCircle(user: user, baseURL: auth.baseURL, token: auth.accessToken)
                                VStack(alignment: .leading, spacing: PVSpacing.s2) {
                                    Text(user.name)
                                        .font(.pvBody)
                                        .foregroundStyle(Color.textPrimaryPV)
                                    Text(user.email)
                                        .font(.pvCaption)
                                        .foregroundStyle(Color.textSecondaryPV)
                                        .accessibilityIdentifier("inviteCandidateEmail-\(user.id)")
                                }
                                Spacer(minLength: PVSpacing.s8)
                                if vm.selectedCandidateId == user.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.immichPrimary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("inviteCandidate-\(user.id)")
                    }
                    .listStyle(.plain)
                    .searchable(text: $vm.searchQuery, prompt: "Name or email")
                }
            }
            .navigationTitle("Invite partner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Invite") {
                        guard let id = vm.selectedCandidateId else { return }
                        Task {
                            if await vm.invite(userId: id) { dismiss() }
                        }
                    }
                    .disabled(!vm.canInvite)
                    .accessibilityIdentifier("confirmInvitePartner")
                }
            }
            .task { await vm.loadCandidates(excludingUserId: currentUserId) }
        }
    }
}
