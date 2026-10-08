import SwiftUI

/// Shared-link management sheet for an album (AC-512, AC-513).
/// Create new link (optional password, custom slug, expiry) + list/revoke
/// existing links + copy URL.
///
/// `SharedLinkResponseDto.password` is the server-returned password string —
/// it is NEVER displayed in the UI (VM-J security). We only show a lock icon
/// when the link is password-protected.
struct SharedLinkSheet: View {
    @Bindable var vm: AlbumDetailViewModel
    @Environment(AuthViewModel.self) private var auth

    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var usePassword = false
    @State private var password = ""
    @State private var slug = ""
    @State private var expiresAt: Date?
    @State private var pendingRevokeId: String?
    @State private var showRevokeConfirm = false
    @State private var editLinkItem: EditLinkItem?

    /// `externalDomain` when the server advertises one, the server URL
    /// otherwise — via the shared builder, so this sheet cannot drift from the
    /// Shared tab.
    private var sharedLinkBase: SharedLinkURL {
        SharedLinkURL(
            serverURL: auth.baseURL ?? URL(string: "https://example.com")!,
            externalDomain: auth.serverConfig?.externalDomain ?? ""
        )
    }

    var body: some View {
        NavigationStack {
            List {
                createSection
                if !vm.sharedLinks.isEmpty {
                    existingSection
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Shared Links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await vm.loadSharedLinks() }
            .sheet(item: $editLinkItem) { item in
                EditSharedLinkSheet(link: item.link) { dto in
                    await vm.updateSharedLink(id: item.link.id, dto: dto)
                }
                .presentationDetents([.medium, .large])
            }
            .alert("Revoke this shared link?", isPresented: $showRevokeConfirm) {
                Button("Revoke", role: .destructive) {
                    if let id = pendingRevokeId {
                        Task { await vm.revokeSharedLink(id: id) }
                    }
                    withAnimation(PVMotion.snappy) {
                        pendingRevokeId = nil
                        showRevokeConfirm = false
                    }
                }
                Button("Cancel", role: .cancel) {
                    withAnimation(PVMotion.snappy) {
                        pendingRevokeId = nil
                        showRevokeConfirm = false
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { vm.actionErrorMessage != nil },
                set: { if !$0 { vm.actionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.actionErrorMessage ?? "")
            }
        }
    }

    /// Hairline between two rows of the "New Link" card.
    ///
    /// Drawn explicitly instead of with `Divider()`: SwiftUI silently dropped a
    /// `Divider()` placed after the password `Toggle` in this very VStack (the
    /// rendered card had 3 rules for 4 in the code), so the card's rhythm cannot
    /// be handed to a `Divider()`. Same reasoning as `LoginScreen.orRule`.
    private var cardRule: some View {
        Rectangle()
            .fill(Color.separatorPV)
            .frame(height: 1)
    }

    private var createSection: some View {
        Section {
            // Card of rows with a hairline between each — the house pattern
            // (`ServerInfoCard`, `PVInputGroup`): the horizontal padding lives on
            // this VStack and the vertical padding on each row, so every rule is
            // inset to the row content rather than spanning the card edge to edge.
            // Rows use `s12` vertically, the padding `InfoRow` uses, so the card
            // breathes like the other cards in the app.
            VStack(spacing: PVSpacing.s0) {
                TextField("Description (optional)", text: $description)
                    .padding(.vertical, PVSpacing.s12)

                cardRule

                Toggle("Password protect", isOn: $usePassword)
                    .padding(.vertical, PVSpacing.s12)
                if usePassword {
                    cardRule
                    SecureField("Password", text: $password)
                        .padding(.vertical, PVSpacing.s12)
                }

                cardRule

                HStack(spacing: 0) {
                    if !slug.isEmpty {
                        Text("/s/")
                            .foregroundStyle(Color.textSecondaryPV)
                            .accessibilityHidden(true)
                    }
                    TextField("Custom URL", text: $slug)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("sharedLinkSlugField")
                }
                .padding(.vertical, PVSpacing.s12)

                cardRule

                SharedLinkExpiryPicker(date: $expiresAt)
                    .padding(.vertical, PVSpacing.s12)

                cardRule

                Button {
                    Task {
                        await vm.createSharedLink(
                            password: usePassword ? password : nil,
                            description: description.isEmpty ? nil : description,
                            slug: slug,
                            expiresAt: expiresAt
                        )
                        description = ""
                        password = ""
                        usePassword = false
                        slug = ""
                        expiresAt = nil
                    }
                } label: {
                    Label("Create Link", systemImage: "square.and.arrow.up")
                }
                .disabled(vm.isLoading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, PVSpacing.s16)
            }
            .padding(.horizontal, PVSpacing.s16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
            .listRowBackground(Color.clear)
            // The List draws two different rules around this row, and both read
            // as a stray line under the card (measured on a rendered sheet: the
            // row separator lands ~2.5pt below the card's bottom edge and spans
            // exactly the card's width, because it inherits the row insets).
            //   - `.listRowSeparator` — the hairline at the bottom of the row;
            //   - `.listSectionSeparator` — the line at the section boundary,
            //     plus the one under the section header, above the card.
            // The card carries its own rules; the list adds nothing
            // (`SharedLinkRow` hides its own for the same reason).
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: PVSpacing.s4,
                leading: PVSpacing.s16,
                bottom: PVSpacing.s4,
                trailing: PVSpacing.s16
            ))
        } header: {
            Text("New Link")
        }
    }

    private var existingSection: some View {
        Section("Existing Links") {
            ForEach(vm.sharedLinks, id: \.id) { link in
                SharedLinkRow(
                    link: link,
                    sharedLinkBase: sharedLinkBase,
                    isPendingRevoke: pendingRevokeId == link.id,
                    onRevoke: { pendingRevokeId = link.id },
                    cardBackground: Color(uiColor: .systemBackground)
                )
                .contextMenu {
                    Button {
                        editLinkItem = EditLinkItem(link: link)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingRevokeId = link.id
                        showRevokeConfirm = true
                    } label: {
                        Label("Revoke", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Revoke", systemImage: "trash", role: .destructive) {
                        withAnimation(PVMotion.snappy) {
                            pendingRevokeId = link.id
                        }
                        // Present the confirmation after the row has finished
                        // sliding out, so the popup never has to snap the row
                        // back from an open swipe state.
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            guard pendingRevokeId == link.id else { return }
                            showRevokeConfirm = true
                        }
                    }
                }
                .tint(.red)
                .listSectionSeparator(.hidden)
            }
        }
    }
}

#if DEBUG
// Layout review surface for this sheet — it is otherwise reachable only through
// a live album detail flow. Renders the "New Link" card plus one existing link
// directly (not inside a `.sheet`): that is the faithful context, and it is the
// one whose pixels were measured when tuning the card's rules and spacing.
#Preview("Shared link sheet") {
    let vm = AlbumDetailViewModel(client: DependencyContainer.shared.client, albumId: "preview")
    vm.sharedLinks = [
        SharedLinkResponseDto(
            id: "link-1", description: "Trip", password: nil, userId: "owner", key: "a2V5",
            type: .album, createdAt: "2026-01-01T00:00:00.000Z", expiresAt: nil,
            assets: [], album: nil, allowUpload: false, allowDownload: true,
            showMetadata: true, slug: "trip-2026"
        )
    ]
    return SharedLinkSheet(vm: vm)
        .environment(DependencyContainer.shared.makeAuthViewModel())
}
#endif
