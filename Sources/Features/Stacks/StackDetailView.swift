import SwiftUI

/// One stack, opened from the hub (`StackView`) or from a stacked tile in the
/// timeline. Shows the cover large, the rest below, and the mutations the
/// `/api/stacks` routes allow: change cover, drop a member, dissolve the stack.
/// Tapping any member opens the viewer on the members.
///
/// Pushed onto an existing `NavigationStack` — declares none of its own.
struct StackDetailView: View {
    /// Server id of the stack. Held rather than the DTO so the screen survives
    /// a reload of the list it was pushed from — and **mutable**, because
    /// adding photos re-creates the stack server-side and hands back a new id
    /// (see `StacksViewModel.addPhotos`); a fixed id would strand this screen on
    /// a stack that no longer exists.
    @State private var stackId: String
    @Bindable var vm: StacksViewModel

    @Environment(AuthViewModel.self) private var auth
    @State private var viewerItem: PhotoViewerItem?
    @State private var confirmingUnstack = false
    @State private var deletingMemberID: String?
    @State private var showingAddPhotos = false

    init(stackId: String, vm: StacksViewModel) {
        _stackId = State(initialValue: stackId)
        self.vm = vm
    }

    var body: some View {
        Group {
            switch vm.stackState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .pvLoadingIndicator("stackDetailLoading")
            default:
                stackList
            }
        }
        .navigationTitle("Stack")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadStack(id: stackId) }
        .sheet(isPresented: $showingAddPhotos) {
            if let stack = vm.selectedStack {
                AddToStackSheet(
                    stackId: stack.id,
                    primaryAssetId: stack.primaryAssetId,
                    existingAssetIds: Set(stack.assets.map(\.id)),
                    vm: vm
                ) { newID in
                    // The server re-created the stack: follow it.
                    stackId = newID
                }
            }
        }
        .confirmationDialog("Unstack these photos?", isPresented: $confirmingUnstack, titleVisibility: .visible) {
            Button("Unstack", role: .destructive) {
                Task { await vm.deleteStack(id: stackId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every photo stays in your timeline — only the grouping is removed.")
        }
        .photoViewer(
            item: $viewerItem,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stackDetailScreen")
    }

    private var stackList: some View {
        List {
            switch vm.stackState {
            case .loading:
                EmptyView()
            case .error(let message):
                unavailable(message)
            case .empty:
                // Read, and gone: unstacked, or never there.
                unavailable(String(localized: "This stack is no longer available."))
            case .data(let status):
                switch status {
                case .idle:
                    EmptyView()
                case .reloading:
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .pvLoadingIndicator("stackDetailLoading")
                    }
                case .failed(let message):
                    Section {
                        InlineErrorBadge(message: message, retry: { Task { await vm.loadStack(id: stackId, force: true) } })
                            .accessibilityIdentifier("stackDetailRefreshError")
                    }
                }
                if let stack = vm.selectedStack, stack.id == stackId {
                    content(stack)
                }
            }
        }
        .refreshable { await vm.refreshStack(id: stackId) }
    }

    @ViewBuilder
    private func unavailable(_ message: String) -> some View {
        Section {
            PVErrorStateView(
                title: "Couldn't load stack",
                message: message,
                identifierPrefix: "stackDetail",
                retry: { Task { await vm.loadStack(id: stackId, force: true) } }
            )
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func content(_ stack: StackResponseDto) -> some View {
        Section {
            if let primary = stack.assets.first(where: { $0.id == stack.primaryAssetId }) ?? stack.assets.first {
                memberRow(primary, in: stack, isPrimary: true)
            }
        } header: {
            Text("Cover")
        } footer: {
            Text("The cover is what your timeline shows for this stack.")
        }

        let others = stack.assets.filter { $0.id != stack.primaryAssetId }
        if !others.isEmpty {
            Section("Other photos") {
                ForEach(others, id: \.id) { member in
                    memberRow(member, in: stack, isPrimary: false)
                }
            }
        }

        Section {
            Button {
                showingAddPhotos = true
            } label: {
                Label("Add photos", systemImage: "plus")
            }
            .accessibilityIdentifier("addPhotosToStack")
        } footer: {
            Text("Adding re-creates the stack on the server, so this stack gets a new id. A photo that already belongs to another stack moves into this one.")
        }

        Section {
            Button(role: .destructive) {
                confirmingUnstack = true
            } label: {
                Label("Unstack", systemImage: "square.stack.3d.up.slash")
            }
        }
    }

    /// One stack member: thumbnail + name + cover marker, with the per-member
    /// actions in a context menu (same affordances as the viewer's StackSheet)
    /// and a swipe-to-remove on non-cover members.
    @ViewBuilder
    private func memberRow(_ member: AssetResponseDto, in stack: StackResponseDto, isPrimary: Bool) -> some View {
        Button {
            openViewer(on: member, in: stack)
        } label: {
            HStack(spacing: PVSpacing.s12) {
                AuthenticatedAsyncImage(
                    url: ImmichAssetURL.thumbnail(assetId: member.id, thumbhash: member.thumbhash ?? "", baseURL: baseURL),
                    token: auth.accessToken
                )
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: PVRadius.sm, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(member.originalFileName)
                        .font(.pvBody)
                        .foregroundStyle(Color.textPrimaryPV)
                    if isPrimary {
                        Text("Cover")
                            .font(.pvCaption)
                            .foregroundStyle(Color.textSecondaryPV)
                    }
                }

                Spacer()

                if isPrimary {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color.immichPrimary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stackMember_\(member.id)")
        .swipeActions(edge: .trailing) {
            if !isPrimary {
                Button(role: .destructive) {
                    deletingMemberID = member.id
                    Task {
                        await vm.removeAssetFromStack(stackId: stack.id, assetId: member.id)
                        deletingMemberID = nil
                    }
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
            }
        }
        .contextMenu {
            if !isPrimary {
                Button {
                    Task { await vm.updatePrimary(stackId: stack.id, assetId: member.id) }
                } label: {
                    Label("Make cover", systemImage: "star")
                }
                Button(role: .destructive) {
                    Task { await vm.removeAssetFromStack(stackId: stack.id, assetId: member.id) }
                } label: {
                    Label("Remove from stack", systemImage: "square.stack.3d.up.slash")
                }
            }
        }
        .disabled(deletingMemberID == member.id)
    }

    /// Opens the viewer on the stack's members, so paging stays inside the
    /// stack instead of falling through to the whole timeline.
    private func openViewer(on member: AssetResponseDto, in stack: StackResponseDto) {
        let members = stack.assets.map(AssetReactItem.init(from:))
        guard let index = members.firstIndex(where: { $0.id == member.id }) else { return }
        viewerItem = PhotoViewerItem(assets: members, index: index)
    }

    private var baseURL: URL {
        auth.baseURL ?? URL(string: "https://example.com")!
    }
}
