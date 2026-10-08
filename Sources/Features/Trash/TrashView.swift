import SwiftUI

/// Trash tab — Apple-Photos-grade "Recently Deleted" experience.
///
/// Mirrors the TimelineView grid conventions (spacing 0, cornerRadius 0,
/// `.padding(.horizontal, 4)` screen-edge inset) but keeps a separate
/// simplified feature surface: no selection mode, no favorite, no detail
/// navigation. Actions:
/// - Restore single (context menu) — non destructive, no confirmation.
/// - Delete Permanently single (context menu) — destructive, confirmation alert.
/// - Restore All (toolbar) — non destructive, no confirmation.
/// - Empty Trash (toolbar) — destructive, confirmation alert.
///
/// All actionable UI is `.disabled(vm.isLoading)` to mitigate FM-1/FM-2
/// (race restore→delete, double-tap, UI visible during slow empty). AC-316.
struct TrashView: View {
    @State var vm: TrashViewModel
    @Environment(AuthViewModel.self) private var auth

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 3)

    // UI-only haptic / alert state.
    @State private var lastRestoreTick = 0
    @State private var lastDeleteTick = 0
    @State private var pendingDeletePermanentID: String?
    @State private var pendingEmptyAll = false
    @State private var viewerItem: PhotoViewerItem? // Full-screen photo viewer

    init(vm: TrashViewModel) {
        _vm = State(initialValue: vm)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
            }
            .refreshable { await vm.refresh() }
            .safeAreaInset(edge: .top, spacing: 0) {
                trashLoadErrorBanner
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(Text(verbatim: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .toolbarBackground(.visible, for: .navigationBar)
            .appSensoryFeedback(.success, trigger: lastRestoreTick)
            .appSensoryFeedback(.warning, trigger: lastDeleteTick)
            .alert(
                "Delete Permanently?",
                isPresented: Binding(
                    get: { pendingDeletePermanentID != nil },
                    set: { if !$0 { pendingDeletePermanentID = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let id = pendingDeletePermanentID {
                        Task {
                            await vm.deletePermanently(id: id)
                            lastDeleteTick &+= 1
                        }
                    }
                    pendingDeletePermanentID = nil
                }
                Button("Cancel", role: .cancel) { pendingDeletePermanentID = nil }
            } message: {
                Text("This asset will be permanently deleted. Action cannot be undone.")
            }
            .alert("Empty Trash?", isPresented: $pendingEmptyAll) {
                Button("Empty Trash", role: .destructive) {
                    Task {
                        await vm.emptyTrash()
                        lastDeleteTick &+= 1
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All items in trash will be permanently deleted. Action cannot be undone.")
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { vm.actionErrorMessage != nil },
                set: { if !$0 { vm.actionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: vm.actionErrorMessage ?? "")
            }
        }
        .task {
            if vm.items.isEmpty {
                await vm.load()
            }
        }
        // Full-screen photo viewer (tap any photo → browse/zoom, Info-only).
        .photoViewer(
            item: $viewerItem,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken,
            onRestore: { asset in
                Task { await vm.restore(id: asset.id) }
            },
            onDeletePermanent: { asset in
                Task { await vm.deletePermanently(id: asset.id) }
            }
        )
    }

    /// Opens the Photos-style viewer at `item`, paging through trash order.
    private func openViewer(for item: AssetReactItem) {
        guard let idx = vm.items.firstIndex(where: { $0.id == item.id }) else { return }
        viewerItem = PhotoViewerItem(assets: vm.items, index: idx)
    }

    // MARK: - Content

    @ViewBuilder
    private var trashLoadErrorBanner: some View {
        if !vm.items.isEmpty, let message = vm.loadErrorMessage {
            InlineErrorBadge(message: message, retry: { Task { await vm.refresh() } })
                .padding(PVSpacing.s16)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.items.isEmpty {
            if vm.isLoading {
                ProgressView().padding(.top, 80)
            } else if vm.loadErrorMessage != nil {
                ContentUnavailableView {
                    Label("Couldn't load trash", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(verbatim: vm.loadErrorMessage ?? "")
                } actions: {
                    Button("Try Again") { Task { await vm.refresh() } }
                        .buttonStyle(PVPrimaryButtonStyle())
                }
                .padding(.top, 80)
            } else {
                ContentUnavailableView {
                    Label("Trash is Empty", systemImage: "trash.slash")
                } description: {
                    Text("Deleted photos and videos appear here for 30 days before being permanently removed.")
                }
                .padding(.top, 80)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                trashInfoBanner
                ForEach(vm.groupedByDay, id: \.day) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 0) {
                            ForEach(group.items) { item in
                                cellView(for: item)
                                    .task {
                                        if item.id == vm.items.last?.id {
                                            await vm.loadMore()
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, PVSpacing.s4)
                    } header: {
                        TrashSectionHeader(
                            label: DateHeaderFormatter.displayString(for: group.day)
                        )
                    }
                    .id(group.day)
                }
                if vm.canLoadMore {
                    ProgressView()
                        .padding(.vertical, PVSpacing.s12)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Pinned section header — mirrors TimelineView.TimelineSectionHeader
    /// (kept private there; duplicated here to stay self-contained).
    private struct TrashSectionHeader: View {
        let label: String

        var body: some View {
            Text(label)
                .font(.pvHeadline)
                .foregroundStyle(Color.textSecondaryPV)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PVSpacing.s24)
                .padding(.vertical, PVSpacing.s8)
                .background(.regularMaterial)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// 30-day info banner. Scrolls with the grid (not sticky). Cahier line 98.
    @ViewBuilder
    private var trashInfoBanner: some View {
        HStack(spacing: PVSpacing.s8) {
            Image(systemName: "trash")
                .foregroundStyle(Color.textSecondaryPV)
            Text("Items in trash are permanently deleted after 30 days.")
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
            Spacer()
        }
        .padding(.horizontal, PVSpacing.s12)
        .padding(.vertical, PVSpacing.s8)
    }

    // MARK: - Cell

    @ViewBuilder
    private func cellView(for item: AssetReactItem) -> some View {
        AssetThumbnailCell(
            asset: item,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken,
            onTap: {
                openViewer(for: item)
            },
            onRestore: {
                Task {
                    await vm.restore(id: item.id)
                    lastRestoreTick &+= 1
                }
            },
            onDeletePermanent: {
                pendingDeletePermanentID = item.id
            }
        )
        .disabled(vm.isLoading) // FM-1 / FM-2 / FM-3 mitigation (AC-316).
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ImmichAppBar(title: "Trash")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task {
                    await vm.restoreAll()
                    lastRestoreTick &+= 1
                }
            } label: {
                Label("Restore All", systemImage: "arrow.uturn.backward.circle")
            }
            .disabled(vm.isLoading || vm.items.isEmpty) // AC-316
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(role: .destructive) {
                pendingEmptyAll = true
            } label: {
                Label("Empty Trash", systemImage: "trash")
            }
            .disabled(vm.isLoading || vm.items.isEmpty) // AC-316
        }
    }
}
