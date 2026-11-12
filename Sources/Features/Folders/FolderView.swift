import SwiftUI

/// Folder view (gap G11) — the directory tree the server sees on its disk
/// (external libraries: `/mnt/media/Photos/…`), one level per push.
///
/// Pushed from the Albums tab's Library section (L-12), whose stack this screen
/// shares: it therefore declares none of its own (the OfflineAssetsView /
/// StackView rule), or the navigation bar would be doubled.
///
/// The server only ever returns the **direct** children of a folder
/// (`LIKE '%<path>/%' AND NOT LIKE '%<path>/%/%'`), so this screen lists one
/// level and pushes the next — it never unfolds the whole tree.
struct FolderView: View {
    @Bindable var vm: FolderViewModel
    /// `nil` = top level. One `vm` serves every level, so the per-path asset
    /// cache fills the parent back in on the way up without a request.
    ///
    /// A level is pushed as a **view** (`NavigationLink { FolderView(…) }`),
    /// like every other drill-down of the hub (StackView → StackDetailView).
    /// Pushing it *by value* looked right and really did load the folder — the
    /// stub logged `GET /api/view/folder?path=/Videos` — but the level never
    /// came on screen: the hub pushes this screen with a view-destination link,
    /// and SwiftUI keeps value destinations *below* view destinations inside
    /// one stack (Apple: "if you attempt to push a value while a
    /// view-destination link is on the stack, SwiftUI pops all view
    /// destinations and pushes the value's destination onto the stack"), so the
    /// root level ended up stacked back on top of the folder just opened and
    /// the tap read as "nothing happened" (measured: XCUITest, iPhone 17 /
    /// iOS 26.3, `.omp` scenario `FolderViewUITests`).
    let node: FolderNode?

    @Environment(AuthViewModel.self) private var auth
    @State private var viewerItem: PhotoViewerItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3)

    private var baseURL: URL { auth.baseURL ?? URL(string: "https://example.com")! }

    /// The folder this level reads. The top level has no folder: it only calls
    /// the server when the tree reported assets laid at the filesystem root,
    /// which `unique-paths` spells as the empty string.
    private var currentPath: String { node?.path ?? (vm.hasRootLevelAssets ? "/" : "") }

    var body: some View {
        content
            .background(Color.bgPrimary)
            .navigationTitle(node?.name ?? String(localized: "Folders"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { sortButton }
            }
            // `id` on the path: arriving on a level (push *or* pop) loads it.
            .task(id: node?.path ?? "/") { await load() }
            .photoViewer(
                item: $viewerItem,
                baseURL: baseURL,
                token: auth.accessToken,
                onDataChanged: {
                    Task { await refreshCurrent() }
                }
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(node.map { "folderScreen_\($0.path)" } ?? "foldersScreen")
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PVSpacing.s16) {
                pathBar
                level
            }
            .padding(.horizontal, PVSpacing.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Refresh touches the current folder only — never `unique-paths`.
        .refreshable { await refreshCurrent() }
    }

    /// The states are exclusive and ordered: tree first (nothing can render
    /// without it), then the current folder's load / error, then empty.
    @ViewBuilder
    private var level: some View {
        if vm.isBuildingTree && vm.root == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, PVSpacing.s48)
        } else if let treeError = vm.treeError {
            retryable(treeError) { await vm.retryTree() }
        } else if vm.isLoadingAssets(currentPath) && vm.sortedAssets(for: currentPath).isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, PVSpacing.s48)
        } else if let message = vm.errorMessage(currentPath) {
            retryable(message) { await vm.refresh(path: currentPath) }
        } else if vm.children(of: node).isEmpty && vm.sortedAssets(for: currentPath).isEmpty {
            // "Empty folder", never "No assets": the server filters on
            // `visibility = timeline`, so this folder may well hold files it
            // does not show (archived, locked) — and no parameter opens that.
            ContentUnavailableView(
                "Empty folder",
                systemImage: "folder",
                description: Text("This folder holds no sub-folder and no asset.")
            )
            .accessibilityIdentifier("foldersEmptyState")
        } else {
            folderRows
            assetGrid
        }
    }

    private func retryable(_ message: String, action: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: PVSpacing.s12) {
            InlineErrorBadge(message: message)
            Button("Retry") { Task { await action() } }
                .buttonStyle(PVPrimaryButtonStyle())
                .accessibilityIdentifier("foldersRetryButton")
        }
    }

    /// The upstream `FolderPath`: the absolute path, monospace, scrollable
    /// sideways because a deep external-library path is wider than the screen.
    /// Hidden at the top level, where there is no folder path to print.
    @ViewBuilder
    private var pathBar: some View {
        if let node, !node.path.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(node.path)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color.textSecondaryPV)
                    .lineLimit(1)
                    .accessibilityIdentifier("folderPathBar")
            }
        }
    }

    @ViewBuilder
    private var folderRows: some View {
        ForEach(vm.children(of: node)) { child in
            // A view-destination push, not `NavigationLink(value:)`: the value
            // form cannot push from inside a stack that already holds a view
            // destination (see `node`).
            NavigationLink {
                FolderView(vm: vm, node: child)
            } label: {
                FolderRow(node: child)
            }
            .accessibilityIdentifier("folderRow_\(child.path)")
        }
    }

    @ViewBuilder
    private var assetGrid: some View {
        LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
            ForEach(vm.sortedAssets(for: currentPath)) { item in
                AssetThumbnailCell(
                    asset: item,
                    baseURL: baseURL,
                    token: auth.accessToken,
                    onTap: { openViewer(for: item) }
                )
            }
        }
    }

    /// `arrow.up.arrow.down` is the iOS face of the upstream `Icons.swap_vert`.
    private var sortButton: some View {
        Button {
            vm.toggleAssetOrder()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("folderSortButton")
        .accessibilityLabel(
            vm.assetOrder == .descending
                ? String(localized: "Sort: Newest first")
                : String(localized: "Sort: Oldest first")
        )
    }

    // MARK: - Loading

    private func load() async {
        await vm.loadTree()
        guard !currentPath.isEmpty else { return }
        await vm.loadAssets(for: currentPath)
    }

    /// No path means the top level has no root-level assets: there is nothing to
    /// fetch, and `""` would ask the server for the disk root anyway.
    private func refreshCurrent() async {
        guard !currentPath.isEmpty else { return }
        await vm.refresh(path: currentPath)
    }

    /// The pager follows the **displayed** order, not the timeline — the
    /// upstream `TimelineOrigin.folder`.
    private func openViewer(for item: AssetReactItem) {
        let assets = vm.sortedAssets(for: currentPath)
        guard let index = assets.firstIndex(where: { $0.id == item.id }) else { return }
        viewerItem = PhotoViewerItem(assets: assets, index: index)
    }
}

/// One folder line: the upstream `LargeLeadingTile` in plain SwiftUI — folder
/// glyph, name, and the count of sub-folders already known from the tree
/// (`unique-paths` returns the whole directory, so the count never fills in
/// later).
private struct FolderRow: View {
    let node: FolderNode

    var body: some View {
        HStack(spacing: PVSpacing.s12) {
            Image(systemName: "folder")
                .font(.pvTitleXL)
                .foregroundStyle(Color.immichPrimary)
            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                Text(node.name)
                    .font(.pvHeadline)
                    .foregroundStyle(Color.textPrimaryPV)
                    .lineLimit(1)
                if node.hasChildren {
                    Text(String(localized: "\(node.children.count) folders"))
                        .font(.pvSubhead)
                        .foregroundStyle(Color.textSecondaryPV)
                }
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
