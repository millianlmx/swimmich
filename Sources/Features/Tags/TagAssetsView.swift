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
        if vm.isLoading && vm.items.isEmpty {
            PVSkeletonGrid(rows: 4, columnCount: columns.count)
                .padding(.horizontal, PVSpacing.s4)
                .accessibilityIdentifier("tagAssetsLoading")
        } else if let message = vm.errorMessage, vm.items.isEmpty {
            errorState(message)
        } else if vm.hasLoaded && vm.items.isEmpty {
            ContentUnavailableView(
                "No photos with this tag",
                systemImage: "tag",
                description: Text("Photos you add to this tag appear here.")
            )
            .accessibilityIdentifier("tagAssetsEmptyState")
        } else {
            grid
        }
    }

    /// The identifier goes on the message `Text`, never on the stack: an
    /// identifier on a container would hide the retry button's.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: PVSpacing.s16) {
            Label(title: { Text(verbatim: vm.tagName) }, icon: { Image(systemName: "tag") })
                .font(.pvSubhead)
                .foregroundStyle(Color.textPrimaryPV)
            Text("Couldn't load photos")
                .font(.pvBody)
                .foregroundStyle(Color.textPrimaryPV)
            Text(verbatim: message)
                .font(.pvBody)
                .foregroundStyle(Color.textSecondaryPV)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("tagAssetsError")
            Button("Try Again") { Task { await vm.load() } }
                .buttonStyle(PVPrimaryButtonStyle())
                .accessibilityIdentifier("tagAssetsErrorRetry")
        }
        .frame(maxWidth: .infinity)
        .padding(PVSpacing.s24)
    }

    private var grid: some View {
        ScrollView {
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
        .accessibilityIdentifier("tagAssetsGrid")
        .refreshable { await vm.load() }
    }
}
