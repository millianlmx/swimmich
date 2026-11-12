import SwiftUI

/// The library of one partner who shares with the user (L-08) — pushed from
/// `PartnersView`, no `NavigationStack` of its own (`ProfileView` owns the
/// stack). A gallery: no selection, no context menu, nothing destructive; the
/// viewer opens on a touch and only offers what the server allows on another
/// account's photo.
///
/// "Group By" and "Columns" are read from the preferences the timeline
/// writes (upstream hands the global `groupBy` to every timeline screen); this
/// screen never writes them, and has no pinch and no date scrubber.
struct PartnerLibraryView: View {
    @State var vm: PartnerLibraryViewModel
    @Environment(AuthViewModel.self) private var auth
    @Environment(AppSettingsStore.self) private var appSettings
    @State private var viewerItem: PhotoViewerItem?

    private var baseURL: URL { auth.baseURL ?? URL(string: "https://example.com")! }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: appSettings.tilesPerRow)
    }

    var body: some View {
        content
            .navigationTitle(Text(verbatim: vm.partnerName))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.bgPrimary)
            .task { if !vm.hasLoaded && !vm.isLoading { await vm.load() } }
            .photoViewer(item: $viewerItem, baseURL: baseURL, token: auth.accessToken)
    }

    /// Nothing to show yet and a request is on its way (or none was made yet).
    private var showsSkeleton: Bool {
        vm.items.isEmpty
            && ((vm.isLoading && !vm.isRefreshing) || (!vm.hasLoaded && vm.errorMessage == nil))
    }

    @ViewBuilder
    private var content: some View {
        if showsSkeleton {
            // One accessibility element: VoiceOver reads it, XCUITest finds it.
            PVSkeletonGrid(rows: 4, columnCount: appSettings.tilesPerRow)
                .padding(.horizontal, PVSpacing.s4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Loading…"))
                .accessibilityIdentifier("partnerLibraryLoading")
        } else {
            // One ScrollView through the error, empty and grid states: a state
            // change must not cancel the task of a pull-to-refresh in flight.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: vm.partnerName)
                        .font(.pvTitle)
                        .foregroundStyle(Color.textPrimaryPV)
                        .padding(.horizontal, PVSpacing.s16)
                        .padding(.vertical, PVSpacing.s8)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("partnerLibraryTitle")
                    scrollContent
                }
            }
            .accessibilityIdentifier("partnerLibraryGrid")
            .refreshable { await vm.refresh() }
        }
    }

    @ViewBuilder
    private var scrollContent: some View {
        if let message = vm.errorMessage, vm.items.isEmpty {
            errorState(message)
        } else if vm.items.isEmpty {
            ContentUnavailableView(
                "No photos",
                systemImage: "photo.on.rectangle",
                description: Text("Photos \(vm.partnerName) adds to their library appear here.")
            )
            .containerRelativeFrame(.vertical)
            .accessibilityIdentifier("partnerLibraryEmptyState")
        } else {
            grid
        }
    }

    /// The identifier goes on the message `Text`, never on the stack: an
    /// identifier on a container would hide the retry button's.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: PVSpacing.s16) {
            Text("Couldn't load photos")
                .font(.pvBody)
                .foregroundStyle(Color.textPrimaryPV)
            Text(verbatim: message)
                .font(.pvBody)
                .foregroundStyle(Color.textSecondaryPV)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("partnerLibraryError")
            Button("Try Again") { Task { await vm.load() } }
                .buttonStyle(PVPrimaryButtonStyle())
                .accessibilityIdentifier("partnerLibraryErrorRetry")
        }
        .frame(maxWidth: .infinity)
        .padding(PVSpacing.s24)
        .containerRelativeFrame(.vertical)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            reloadStatus
            sectionStack
        }
    }

    @ViewBuilder
    private var reloadStatus: some View {
        if vm.isLoading && !vm.isRefreshing {
            // "Try Again" from the badge: the photos stay, this stands in for it.
            ProgressView()
                .padding(.vertical, PVSpacing.s8)
                .accessibilityIdentifier("partnerLibraryRefreshing")
        } else if let message = vm.errorMessage {
            InlineErrorBadge(message: message, retry: { Task { await vm.load() } })
                .padding(PVSpacing.s16)
                .accessibilityIdentifier("partnerLibraryRefreshError")
        }
    }

    private var sectionStack: some View {
        LazyVStack(alignment: .leading, spacing: PVSpacing.s8) {
            ForEach(vm.sections(groupBy: appSettings.groupBy)) { section in
                switch section {
                case .monthHeader(let month, let display):
                    Text(verbatim: display)
                        .font(.pvHeadline)
                        .foregroundStyle(Color.textPrimaryPV)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("partnerLibraryMonthHeader_\(month)")
                case .dayGroup(let day, let items):
                    Text(verbatim: DateHeaderFormatter.displayString(for: day))
                        .font(.pvSubhead.weight(.semibold))
                        .foregroundStyle(Color.textSecondaryPV)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("partnerLibraryDayHeader_\(day)")
                    tiles(items)
                case .monthGroup(_, let items), .flat(let items):
                    tiles(items)
                }
            }

            if let message = vm.loadMoreErrorMessage {
                InlineErrorBadge(message: message, retry: { Task { await vm.loadMore() } })
                    .padding(PVSpacing.s16)
                    .accessibilityIdentifier("partnerLibraryLoadMoreError")
            } else if vm.hasMore {
                // `.id` recreates the sentinel after each page, so `onAppear`
                // fires again when a short page leaves it on screen.
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PVSpacing.s16)
                    .id(vm.loadedBucketCount)
                    .accessibilityIdentifier("partnerLibraryLoadMore")
                    .onAppear { Task { await vm.loadMore() } }
            }
        }
        .padding(.horizontal, PVSpacing.s4)
    }

    private func tiles(_ items: [AssetReactItem]) -> some View {
        LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
            ForEach(items) { item in
                AssetThumbnailCell(
                    asset: item,
                    baseURL: baseURL,
                    token: auth.accessToken,
                    onTap: { open(item) },
                    contextMenuEnabled: false
                )
            }
        }
    }

    private func open(_ item: AssetReactItem) {
        guard let index = vm.items.firstIndex(where: { $0.id == item.id }) else { return }
        viewerItem = PhotoViewerItem(assets: vm.items, index: index)
    }
}
