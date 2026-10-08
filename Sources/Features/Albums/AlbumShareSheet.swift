import SwiftUI

/// Album "Shared With" sheet — who can access the album and with which role.
///
/// People card (Photos-style, system grouped list):
/// - the album owner (signed-in user) as the first, fixed row
/// - granted collaborators: role menu (Viewer / Editor) + swipe-to-remove
/// - an "Invite People" row that pushes a directory picker
///
/// Mutations are immediate (no Save): each action calls the server and reverts
/// on failure (see `AlbumShareViewModel`).
struct AlbumShareSheet: View {
    @Bindable var vm: AlbumShareViewModel

    @Environment(AuthViewModel.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var pendingRevokeUser: UserResponseDto?

    var body: some View {
        NavigationStack {
            Group {
                if vm.isBusy && vm.users.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.users.isEmpty && vm.loadErrorMessage != nil {
                    errorState
                } else {
                    peopleList
                }
            }
            .navigationTitle("Shared With")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await vm.load() }
            .alert("Error", isPresented: Binding(
                get: { vm.actionErrorMessage != nil },
                set: { if !$0 { vm.actionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.actionErrorMessage ?? "")
            }
            .confirmationDialog(
                "Remove \(pendingRevokeUser?.name ?? "") from this album?",
                isPresented: Binding(
                    get: { pendingRevokeUser != nil },
                    set: { if !$0 { pendingRevokeUser = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let user = pendingRevokeUser {
                        Task { await vm.revoke(userId: user.id) }
                    }
                    pendingRevokeUser = nil
                }
                Button("Cancel", role: .cancel) { pendingRevokeUser = nil }
            } message: {
                Text("They will no longer be able to view or edit this album.")
            }
        }
    }

    private var errorState: some View {
        ContentUnavailableView {
            Label("Couldn't Load Users", systemImage: "person.2.slash")
        } description: {
            Text(vm.loadErrorMessage ?? "")
        } actions: {
            Button("Try Again") { Task { await vm.load() } }
        }
    }

    // MARK: - People card

    private var peopleList: some View {
        List {
            if !vm.users.isEmpty, let message = vm.loadErrorMessage {
                Section {
                    InlineErrorBadge(message: message, retry: { Task { await vm.load() } })
                        .listRowBackground(Color.clear)
                }
            }
            if let owner = vm.owner {
                Section {
                    ownerRow(owner)
                } header: {
                    Text("People")
                }
            }
            // One card per collaborator, tightly spaced: a swipe covers exactly
            // its own card (no card-mother corner transition mid-swipe).
            ForEach(vm.collaborators, id: \.id) { user in
                Section {
                    collaboratorRow(user)
                }
                .listSectionSpacing(.compact)
            }
            Section {
                inviteRow
            } footer: {
                if vm.loadErrorMessage == nil {
                    Text("People you share with can view this album. Editors can also add and remove photos.")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func ownerRow(_ user: UserResponseDto) -> some View {
        HStack(spacing: PVSpacing.s12) {
            UserAvatarCircle(user: user, baseURL: auth.baseURL, token: auth.accessToken)
            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                Text(user.name)
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                Text("(You)")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
            }
            Spacer()
            Text("Owner")
                .font(.pvCaption.weight(.semibold))
                .foregroundStyle(Color.textSecondaryPV)
                .padding(.horizontal, PVSpacing.s8)
                .padding(.vertical, PVSpacing.s4)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(Capsule())
        }
    }

    private func collaboratorRow(_ user: UserResponseDto) -> some View {
        HStack(spacing: PVSpacing.s12) {
            UserAvatarCircle(user: user, baseURL: auth.baseURL, token: auth.accessToken)
            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                Text(user.name)
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
            }
            Spacer()
            roleMenu(for: user)
                .font(.pvCaption)
                .foregroundStyle(Color.accentColor)
                .disabled(vm.busyUserIds.contains(user.id))
        }
        .swipeActions(edge: .trailing) {
            // Forced red: a global accent tint (ImmichPrimary) overrides the
            // destructive role's default red on iOS 26 — same class of bug as
            // the album detail "Delete Album" menu label.
            Button(role: .destructive) {
                pendingRevokeUser = user
            } label: {
                Label("Remove", systemImage: "person.badge.minus")
            }
            .tint(.red)
        }
    }

    private var inviteRow: some View {
        NavigationLink {
            AlbumInvitePeopleView(vm: vm)
        } label: {
            Label("Invite People", systemImage: "person.badge.plus")
                .font(.pvBody)
                .foregroundStyle(Color.accentColor)
        }
    }

    private func roleMenu(for user: UserResponseDto) -> some View {
        Menu {
            Button("Can View") {
                Task { await vm.setRole(.viewer, for: user.id) }
            }
            Button("Can Edit") {
                Task { await vm.setRole(.editor, for: user.id) }
            }
        } label: {
            Label(
                vm.role(for: user.id) == .editor ? "Editor" : "Viewer",
                systemImage: "chevron.up.chevron.down"
            )
            .labelStyle(.titleAndIcon)
        }
    }
}

/// Directory picker pushed from the people card: invite any non-collaborator
/// instance user with a role. Grants are immediate; granted rows leave the
/// list (they reappear in the card behind).
private struct AlbumInvitePeopleView: View {
    @Bindable var vm: AlbumShareViewModel

    @Environment(AuthViewModel.self) private var auth

    var body: some View {
        Group {
            if vm.inviteCandidates.isEmpty {
                ContentUnavailableView {
                    Label(
                        vm.isDirectoryHidden ? "User Directory Hidden" : "No More Users to Invite",
                        systemImage: "person.2"
                    )
                } description: {
                    Text(
                        vm.isDirectoryHidden
                            ? "Only the server admin can list users. Existing collaborators can still be managed."
                            : "This server has no other users to invite."
                    )
                }
            } else {
                List {
                    Section {
                        ForEach(vm.inviteCandidates, id: \.id) { user in
                            candidateRow(user)
                        }
                    } footer: {
                        Text("Invited people can view the album. Editors can also add and remove photos.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Invite People")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: Binding(
            get: { vm.actionErrorMessage != nil },
            set: { if !$0 { vm.actionErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.actionErrorMessage ?? "")
        }
    }

    private func candidateRow(_ user: UserResponseDto) -> some View {
        HStack(spacing: PVSpacing.s12) {
            UserAvatarCircle(user: user, baseURL: auth.baseURL, token: auth.accessToken)
            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                Text(user.name)
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                Text(user.email)
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
            }
            Spacer()
            Menu {
                Button("Invite as Viewer") {
                    Task { await vm.grant(user, role: .viewer) }
                }
                Button("Invite as Editor") {
                    Task { await vm.grant(user, role: .editor) }
                }
            } label: {
                Label("Invite", systemImage: "person.badge.plus")
                    .labelStyle(.iconOnly)
            }
            .disabled(vm.busyUserIds.contains(user.id))
        }
    }
}
