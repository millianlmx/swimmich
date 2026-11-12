import SwiftUI

/// One of the two "recent" consult screens (gap G13) — pushed from the Albums
/// tab's Library section (L-12).
///
/// A **gallery**, not an editor: no selection, no context menu, no action on an
/// asset. Editing belongs to the Photos tab, whose grid carries those actions;
/// here the long press is deliberately inert.
///
/// It also declares no `NavigationStack` of its own: the Albums tab already owns
/// one, and a second stack would stack a second navigation bar (the trap
/// `LanguageSettingsView` paid for). Same contract as `OfflineAssetsView`.
struct RecentAssetsView: View {
    @State var vm: RecentAssetsViewModel
    @Environment(AuthViewModel.self) private var auth

    /// The timeline's grid convention: three flexible columns, 2 pt apart.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3)

    private var baseURL: URL { auth.baseURL ?? URL(string: "https://example.com")! }

    var body: some View {
        content
            .navigationTitle(vm.mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.bgPrimary)
            .task { await vm.load() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(vm.mode == .taken ? "recentTakenScreen" : "recentAddedScreen")
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        if vm.renderState == .loading {
            // Outside the scroll view: the container (and its `.refreshable`)
            // only exists once there is something to say besides "loading".
            PVSkeletonGrid(rows: 4, columnCount: columns.count)
                .padding(.horizontal, PVSpacing.s4)
                .pvLoadingIndicator("recentLoading")
        } else {
            scrollContent
        }
    }

    /// Empty state. The identifier sits on the `ContentUnavailableView` itself —
    /// nothing inside it needs an identifier of its own, so nothing can be
    /// shadowed by it.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(vm.mode.title, systemImage: vm.mode.systemImage)
        } description: {
            Text(vm.mode.emptyMessage)
        }
        .accessibilityIdentifier("recentEmptyState")
        .containerRelativeFrame(.vertical)
    }

    // MARK: - Grid

    /// The one scroll container: error, empty state and days, newest first.
    /// The footer sentinel fetches the next older day when it scrolls into
    /// view — there is no "load more" button.
    private var scrollContent: some View {
        ScrollView {
            LazyVStack(spacing: PVSpacing.s24, pinnedViews: [.sectionHeaders]) {
                switch vm.renderState {
                case .loading:
                    EmptyView()
                case .error(let message):
                    PVErrorStateView(
                        title: "Couldn't load photos",
                        message: message,
                        identifierPrefix: "recent",
                        retry: { Task { await vm.load() } }
                    )
                    .containerRelativeFrame(.vertical)
                case .empty:
                    emptyState
                case .data(let status):
                    switch status {
                    case .idle:
                        EmptyView()
                    case .reloading:
                        ProgressView()
                            .pvLoadingIndicator("recentLoading")
                    case .failed(let message):
                        InlineErrorBadge(message: message, retry: { Task { await vm.load() } })
                            .accessibilityIdentifier("recentRefreshError")
                    }
                    ForEach(vm.dayGroups) { group in
                        Section {
                            LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                                ForEach(group.items) { item in
                                    AssetThumbnailCell(
                                        asset: item,
                                        baseURL: baseURL,
                                        token: auth.accessToken,
                                        contextMenuEnabled: false
                                    )
                                }
                            }
                        } header: {
                            dayHeader(group.title)
                        }
                    }

                    if vm.hasMore {
                        ProgressView()
                            .padding(.vertical, PVSpacing.s16)
                            .accessibilityIdentifier("recentLoadMore")
                            .onAppear { Task { await vm.loadMore() } }
                    }
                }
            }
            .padding(.horizontal, PVSpacing.s4)
        }
        .accessibilityIdentifier("recentGrid")
        .refreshable { await vm.refresh() }
    }

    /// One-line pinned day band. The title is already formatted by the view
    /// model (`DateHeaderFormatter`) — no date formatting happens here.
    /// Opaque background: a pinned header otherwise lets the grid show through.
    private func dayHeader(_ title: String) -> some View {
        Text(title)
            .font(.pvHeadline)
            .foregroundStyle(Color.textPrimaryPV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, PVSpacing.s8)
            .background(Color.bgPrimary)
            .accessibilityAddTraits(.isHeader)
    }
}
