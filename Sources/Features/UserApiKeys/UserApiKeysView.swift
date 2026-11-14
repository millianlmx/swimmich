import SwiftUI

/// "API Keys" (gap G20): the keys of the account that is signed in, reached from
/// the Me hub by every account — administrator or not. The admin console used to
/// own this list behind `if auth.isAdmin`, which is exactly the gap this screen
/// closes; it is now the only owner of the surface.
///
/// No `NavigationStack` of its own: the Me hub pushes it inside the stack it
/// already owns (OfflineAssetsView pattern).
struct UserApiKeysView: View {
    @Bindable var vm: UserApiKeysViewModel

    @State private var showCreate = false

    var body: some View {
        List {
            // Informative only — it says which key signs the calls that bear it,
            // and carries no gesture: rotation and revocation belong to the
            // "Your keys" rows, where the object is chosen.
            if let myKey = vm.myKey {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(myKey.name)
                            .font(.pvBody)
                            .foregroundStyle(Color.textPrimaryPV)
                        Text(vm.permissionsSummary(myKey))
                            .font(.pvCaption)
                            .foregroundStyle(Color.textTertiaryPV)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("apiKeysCurrentRow")
                } header: {
                    Text("Current session")
                }
            }

            Section {
                switch vm.renderState {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .pvLoadingIndicator("apiKeysLoading")
                        .listRowBackground(Color.clear)
                case .error(let message):
                    PVErrorStateView(
                        title: "Couldn't load API keys",
                        message: message,
                        identifierPrefix: "apiKeys",
                        retry: { Task { await vm.load() } }
                    )
                    .listRowBackground(Color.clear)
                case .empty:
                    ContentUnavailableView {
                        Label("No API keys yet", systemImage: "key.horizontal")
                    } description: {
                        Text("Keys you create let apps and scripts use your account.")
                    }
                    .accessibilityIdentifier("apiKeysEmptyState")
                    .listRowBackground(Color.clear)
                case .data(let status):
                    switch status {
                    case .idle:
                        EmptyView()
                    case .reloading:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .pvLoadingIndicator("apiKeysLoading")
                    case .failed(let message):
                        InlineErrorBadge(message: message, retry: { Task { await vm.load() } })
                            .accessibilityIdentifier("apiKeysRefreshError")
                    }
                    ForEach(vm.keys) { key in
                        keyRow(key)
                    }
                }
            } header: {
                Text("Your keys")
            }

            // An action's failure (create, rotate, delete) never takes the
            // screen over: the list stays usable and the message renders in
            // context.
            if let message = vm.errorMessage {
                Section {
                    InlineErrorBadge(message: message)
                }
            }
        }
        .navigationTitle("API Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .accessibilityIdentifier("apiKeysCreateButton")
            }
        }
        .task {
            await vm.load()
            await vm.loadMyKey()
        }
        .refreshable { await vm.refresh() }
        .sheet(isPresented: $showCreate) {
            APIKeyCreateView { name, permissions in
                await vm.create(name: name, permissions: permissions)
            }
        }
        // The ONE place a secret is ever shown, for a creation as much as for a
        // rotation: `pendingSecret` is cleared when this closes, and no other
        // surface keeps a copy.
        .alert("API Key Secret", isPresented: Binding(
            get: { vm.pendingSecret != nil },
            set: { if !$0 { vm.dismissSecret() } }
        )) {
            Button("Copy") { UIPasteboard.general.string = vm.pendingSecret }
                .accessibilityIdentifier("apiKeyCopySecretButton")
            Button("OK", role: .cancel) { vm.dismissSecret() }
        } message: {
            Text(vm.pendingSecret ?? "")
        }
        // An alert, not a confirmationDialog: on iOS 26 a confirmationDialog is a popover that drops Cancel.
        .alert(
            "Rotate key?",
            isPresented: Binding(
                get: { vm.rotationTarget != nil },
                set: { if !$0 { vm.rotationTarget = nil } }
            )
        ) {
            Button("Rotate") {
                if let key = vm.rotationTarget { Task { await vm.rotate(key) } }
            }
            .accessibilityIdentifier("apiKeyRotateConfirmButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current secret stops working immediately. The new secret is shown once.")
        }
        .alert(
            "Delete key?",
            isPresented: Binding(
                get: { vm.deletionTarget != nil },
                set: { if !$0 { vm.deletionTarget = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let key = vm.deletionTarget { Task { await vm.delete(key) } }
            }
            .accessibilityIdentifier("apiKeyDeleteConfirmButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps using this key will stop working.")
        }
    }

    /// One owned key: name, creation date and the scope it carries. Both
    /// gestures only *designate* the key — the mutation waits for the dialog.
    @ViewBuilder
    private func keyRow(_ key: ApiKeyResponseDto) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.name)
                .font(.pvBody)
                .foregroundStyle(Color.textPrimaryPV)
            Text(vm.formattedCreatedAt(key))
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
            Text(vm.permissionsSummary(key))
                .font(.pvCaption)
                .foregroundStyle(Color.textTertiaryPV)
        }
        .accessibilityElement(children: .combine)
        // Per key, and on the row itself rather than on a container: the
        // scenario has to SWIPE this row (the two mutations hang off swipe
        // actions), and a row found by its name would follow the locale.
        .accessibilityIdentifier("apiKeyRow_\(key.id)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                vm.deletionTarget = key
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("apiKeyDeleteAction_\(key.id)")
        }
        .swipeActions(edge: .leading) {
            Button {
                vm.rotationTarget = key
            } label: {
                Label("Rotate", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("apiKeyRotateAction_\(key.id)")
        }
    }
}
