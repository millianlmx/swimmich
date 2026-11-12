import SwiftUI

/// The photos of one tag (L-03) — pushed from `TagsView`, no `NavigationStack`
/// of its own (`ProfileView` owns the stack). A gallery: no selection, no
/// context menu; the viewer opens on a touch.
struct TagAssetsView: View {
    @State var vm: TagAssetsViewModel
    @Environment(AuthViewModel.self) private var auth
    @State private var viewerItem: PhotoViewerItem?

    /// The timeline's grid convention: three flexible columns, 2 pt apart.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3)

    private var baseURL: URL { auth.baseURL ?? URL(string: "https://example.com")! }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: vm.tagName))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.bgPrimary)
            .task { if !vm.hasLoaded { await vm.load() } }
            .photoViewer(
                item: $viewerItem,
                baseURL: baseURL,
                token: auth.accessToken,
                onDelete: { vm.remove(assetId: $0.id) }
            )
    }

    @ViewBuilder
    private var content: some View {
        if case .loading = vm.renderState {
            // First read, or a "Try Again" with nothing to show.
            PVSkeletonGrid(rows: 4, columnCount: columns.count)
                .padding(.horizontal, PVSpacing.s4)
                .pvLoadingIndicator("tagAssetsLoading")
        } else {
            scrollContent
        }
    }

    /// One `ScrollView` carries the error, the empty state and the grid, with
    /// `.refreshable`: a state change never cancels the pull in flight.
    private var scrollContent: some View {
        ScrollView {
            switch vm.renderState {
            case .loading:
                EmptyView()
            case .error(let message):
                PVErrorStateView(
                    title: "Couldn't load photos",
                    message: message,
                    identifierPrefix: "tagAssets",
                    retry: { Task { await vm.load() } }
                )
                .containerRelativeFrame(.vertical)
            case .empty:
                ContentUnavailableView(
                    "No photos with this tag",
                    systemImage: "tag",
                    description: Text("Photos you add to this tag appear here.")
                )
                .accessibilityIdentifier("tagAssetsEmptyState")
                .containerRelativeFrame(.vertical)
            case .data(let status):
                reloadStatus(status)
                grid
            }
        }
        .accessibilityIdentifier("tagAssetsGrid")
        .refreshable { await vm.refresh() }
    }

    /// "Try Again" with photos on screen: the indicator stands in for the
    /// banner while the read runs; a failed refresh keeps the photos under it.
    @ViewBuilder
    private func reloadStatus(_ status: DataStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .reloading:
            ProgressView()
                .padding(.vertical, PVSpacing.s8)
                .pvLoadingIndicator("tagAssetsLoading")
        case .failed(let message):
            InlineErrorBadge(message: message, retry: { Task { await vm.load() } })
                .padding(PVSpacing.s16)
                .accessibilityIdentifier("tagAssetsRefreshError")
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                    AssetThumbnailCell(
                        asset: item,
                        baseURL: baseURL,
                        token: auth.accessToken,
                        onTap: { viewerItem = PhotoViewerItem(assets: vm.items, index: index) },
                        contextMenuEnabled: false
                    )
                }
            }
            .padding(.horizontal, PVSpacing.s4)

            if let message = vm.loadMoreErrorMessage {
                InlineErrorBadge(message: message, retry: { Task { await vm.loadMore() } })
                    .padding(PVSpacing.s16)
                    .accessibilityIdentifier("tagAssetsLoadMoreError")
            } else if vm.hasMore {
                ProgressView()
                    .padding(.vertical, PVSpacing.s16)
                    .accessibilityIdentifier("tagAssetsLoadMore")
                    .onAppear { Task { await vm.loadMore() } }
            }
        }
    }
}
