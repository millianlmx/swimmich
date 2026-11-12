import SwiftUI

/// Partner sharing screen (P3, issue #14). Pushed from the Albums tab's Library
/// section (L-12) — TrashView/TagsView pattern, no own `NavigationStack`.
///
/// Two sections, two responsibilities, and they are **not** interchangeable:
///
/// - **Shared with me** — people who share their library with me. The switch
///   controls whether their photos appear in my timeline (`PUT
///   /api/partners/{id}`, which the server pairs as `{sharedById: id,
///   sharedWithId: me}`).
/// - **Sharing** — people I added. The only action is to stop (`DELETE
///   /api/partners/{id}` → `{sharedById: me, sharedWithId: id}`).
///
/// Rendering both actions on every row would be a lie: each request only
/// matches one of the two directions.
struct PartnersView: View {
    @Bindable var vm: PartnersViewModel

    @Environment(AuthViewModel.self) private var auth

    @State private var partnerPendingRemoval: PartnerResponseDto?
    @State private var showPartnerRemoveConfirm = false
    @State private var presentingInvite = false
    @State private var openedPartner: PartnerLibraryRoute?

    var body: some View {
        Form {
            // An action (stop sharing, switch) that failed keeps its own message,
            // apart from the read states below.
            if let message = vm.errorMessage {
                Section {
                    InlineErrorBadge(message: message)
                        .accessibilityIdentifier("partnersActionError")
                }
            }
            switch vm.renderState {
            case .loading:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .pvLoadingIndicator("partnersLoading")
                        .listRowBackground(Color.clear)
                }
            case .error(let message):
                Section {
                    PVErrorStateView(
                        title: "Couldn't load partners",
                        message: message,
                        identifierPrefix: "partners",
                        retry: { Task { await vm.load() } }
                    )
                    .listRowBackground(Color.clear)
                }
            case .empty:
                Section {
                    ContentUnavailableView {
                        Label("No partners yet", systemImage: "person.2")
                    } description: {
                        Text("Partners who share their library with you, and people you share yours with, appear here.")
                    }
                    .accessibilityIdentifier("partnersEmptyState")
                    .listRowBackground(Color.clear)
                }
            case .data(let status):
                reloadStatus(status)
                incomingSection
                outgoingSection
            }
        }
        .navigationTitle("Partners")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    presentingInvite = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .accessibilityLabel("Invite a partner")
                .accessibilityIdentifier("invitePartner")
            }
        }
        .task { await vm.load() }
        .refreshable { await vm.refresh() }
        .navigationDestination(item: $openedPartner) { route in
            PartnerLibraryView(
                vm: DependencyContainer.shared.makePartnerLibraryViewModel(
                    partnerId: route.partnerId,
                    partnerName: route.name
                )
            )
        }
        .sheet(isPresented: $presentingInvite) {
            InvitePartnerSheet(vm: vm, currentUserId: auth.userId ?? "")
        }
        .confirmationDialog(
            "Stop sharing with this partner?",
            isPresented: $showPartnerRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop sharing", role: .destructive) {
                guard let partner = partnerPendingRemoval else { return }
                Task {
                    await vm.remove(partnerId: partner.id)
                    withAnimation(PVMotion.snappy) { partnerPendingRemoval = nil }
                }
            }
            .accessibilityIdentifier("confirmStopSharing")
            Button("Cancel", role: .cancel) {
                withAnimation(PVMotion.snappy) { partnerPendingRemoval = nil }
            }
        } message: {
            Text("They lose access to your library. Your photos stay on the server, and your own timeline is unaffected.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("partnersScreen")
    }

    // MARK: - Sections

    /// Head of the sections when the last read failed (banner) or a "Try Again"
    /// from that banner is in flight (indicator in its place).
    @ViewBuilder
    private func reloadStatus(_ status: DataStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .reloading:
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .pvLoadingIndicator("partnersLoading")
            }
        case .failed(let message):
            Section {
                InlineErrorBadge(message: message, retry: { Task { await vm.load() } })
                    .accessibilityIdentifier("partnersRefreshError")
            }
        }
    }

    @ViewBuilder
    private var incomingSection: some View {
        Section {
            if vm.sharedWithMe.isEmpty {
                Text("Nobody is sharing their library with you yet.")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
            } else {
                ForEach(vm.sharedWithMe, id: \.id) { partner in
                    PartnerRow(partner: partner, mode: .incoming, onToggle: { enabled in
                        Task { await vm.setInTimeline(partnerId: partner.id, enabled: enabled) }
                    }, onOpenLibrary: openLibraryAction(for: partner, direction: .sharedWith))
                }
            }
        } header: {
            Text("Shared with me")
        } footer: {
            Text("Their photos can appear alongside yours in the timeline. The switch decides that per partner.")
        }
    }

    @ViewBuilder
    private var outgoingSection: some View {
        Section {
            if vm.sharing.isEmpty {
                Text("You are not sharing your library with anyone yet.")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
            } else {
                ForEach(vm.sharing, id: \.id) { partner in
                    PartnerRow(partner: partner, mode: .outgoing, onRemove: {
                        withAnimation(PVMotion.snappy) { partnerPendingRemoval = partner }
                        showPartnerRemoveConfirm = true
                    }, onOpenLibrary: openLibraryAction(for: partner, direction: .sharedBy))
                }
            }
        } header: {
            Text("Sharing")
        } footer: {
            Text("People you share your library with. Sharing is one-way: to see their photos, they have to add you as well.")
        }
    }

    /// The row's way into the partner's library — decided by the view model,
    /// `nil` for a row that opens nothing.
    private func openLibraryAction(for partner: PartnerResponseDto, direction: PartnerDirection) -> (() -> Void)? {
        vm.libraryRoute(for: partner, direction: direction).map { route in { openedPartner = route } }
    }
}
