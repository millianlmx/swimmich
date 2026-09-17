import SwiftUI

/// Offline storage screen (issue #18) — pushed from `ProfileView`'s Management
/// section, so it declares **no** `NavigationStack` of its own (StackView /
/// TagsView pattern; the hub sheet already owns one).
///
/// Everything shown here is read from disk: the grid renders each cached
/// original from its local file, which is also what makes this screen the
/// proof that the cache works when the server is unreachable.
struct OfflineAssetsView: View {
    @Bindable var vm: OfflineDownloadViewModel
    @Environment(AuthViewModel.self) private var auth

    @State private var page: OfflinePage?
    @State private var showClearAllConfirm = false

    private var baseURL: URL { auth.baseURL ?? URL(string: "https://example.com")! }

    private var assets: [AssetReactItem] { vm.filteredAssets.map(\.reactItem) }

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s16) {
                storageUsageCard

                if let error = vm.errorMessage {
                    InlineErrorBadge(message: error)
                        .accessibilityIdentifier("offlineError")
                }

                if !vm.cachedAssets.isEmpty {
                    searchField
                }

                if vm.cachedAssets.isEmpty {
                    emptyState
                } else if assets.isEmpty {
                    noResultsState
                } else {
                    assetGrid
                    clearAllButton
                }
            }
            .padding(PVSpacing.s16)
        }
        .background(Color.bgPrimary)
        .navigationTitle("Offline Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .refreshable { await vm.load() }
        .confirmationDialog(
            "Remove all offline photos?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All Offline Photos", role: .destructive) {
                Task { await vm.clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(vm.formattedUsage(vm.cacheUsage)) will be freed. Downloaded files will need to be downloaded again.")
        }
        .fullScreenCover(item: $page) { page in
            PhotoViewer(
                assets: assets,
                index: page.index,
                baseURL: baseURL,
                token: auth.accessToken
            )
        }
    }

    // MARK: - Storage

    private var storageUsageCard: some View {
        HStack(spacing: PVSpacing.s16) {
            VStack(alignment: .leading, spacing: PVSpacing.s4) {
                Text("Offline Storage")
                    .font(.pvHeadline)
                Text("\(vm.formattedUsage(vm.cacheUsage)) used")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
                    .accessibilityIdentifier("offlineUsageText")
                Text(subtitleForBudget)
                    .font(.pvCaption)
                    .foregroundStyle(Color.textTertiaryPV)
            }

            Spacer(minLength: 0)

            storageRing
        }
        .padding(PVSpacing.s16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
        // No identifier on this container: an accessibility identifier placed on
        // a container REPLACES its descendants', which would make the usage text
        // and the ring unreachable to a UI test.
    }

    /// Says how many files are held and, when the budget is meaningful, how
    /// much of it is used — the two numbers the user acts on.
    private var subtitleForBudget: String {
        let files = vm.cachedAssets.count == 1
            ? String(localized: "1 file")
            : String(localized: "\(vm.cachedAssets.count) files")
        guard let fraction = vm.usageFraction else {
            return String(localized: "\(files) • No size limit")
        }
        let limit = vm.formattedUsage(vm.maxCacheSize)
        if fraction >= 1 {
            return String(localized: "\(files) • Full (\(limit) limit)")
        }
        return String(localized: "\(files) • of \(limit)")
    }

    @ViewBuilder
    private var storageRing: some View {
        ZStack {
            Circle()
                .stroke(Color.separatorPV, lineWidth: 8)
            if let fraction = vm.usageFraction {
                Circle()
                    .trim(from: 0, to: max(0.001, fraction))
                    .stroke(ringColor.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(PVMotion.snappy, value: fraction)
            }
            Text(usagePercentLabel)
                .font(.pvCaption.weight(.semibold))
                .monospacedDigit()
        }
        .frame(width: 64, height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("offlineUsageRing")
        .accessibilityLabel(offlineRingAccessibilityLabel)
    }

    /// A non-empty cache that rounds to `0%` is reported as `<1%` — printing
    /// "0%" next to a file that is visibly there reads as a bug.
    private var usagePercentLabel: String {
        guard let fraction = vm.usageFraction else { return "—" }
        if fraction > 0 && fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private var ringColor: Color {
        guard let fraction = vm.usageFraction else { return .immichPrimary }
        if fraction >= 0.9 { return .immichError }
        if fraction >= 0.8 { return .immichWarning }
        return .immichPrimary
    }

    private var offlineRingAccessibilityLabel: String {
        guard let fraction = vm.usageFraction else {
            return String(localized: "No size limit set")
        }
        return String(localized: "\(Int((fraction * 100).rounded())) percent of the offline storage budget used")
    }

    // MARK: - Grid

    private var searchField: some View {
        TextField("Search offline photos", text: $vm.searchQuery)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .padding(PVSpacing.s12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PVRadius.control, style: .continuous))
            .accessibilityIdentifier("offlineSearchField")
    }

    private var assetGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3),
            spacing: PVSpacing.s2
        ) {
            ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
                OfflineAssetCell(
                    asset: asset,
                    baseURL: baseURL,
                    token: auth.accessToken,
                    localFileURL: vm.index.localURL(for: asset.id),
                    onTap: { page = OfflinePage(index: index) },
                    onRemove: { Task { await vm.removeFromOffline(asset.id) } }
                )
            }
        }
    }

    private var clearAllButton: some View {
        Button(role: .destructive) {
            showClearAllConfirm = true
        } label: {
            Label("Clear All Offline Photos", systemImage: "trash")
                .frame(maxWidth: .infinity)
                .padding(PVSpacing.s12)
        }
        .buttonStyle(PVSubtleButtonStyle())
        .disabled(vm.cachedAssets.isEmpty)
        .accessibilityIdentifier("clearAllOffline")
    }

    // MARK: - Empty states

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No offline photos", systemImage: "arrow.down.circle")
        } description: {
            Text("Download photos to view them without an internet connection.")
        }
        .accessibilityIdentifier("offlineEmptyState")
    }

    private var noResultsState: some View {
        ContentUnavailableView {
            Label("No matches", systemImage: "magnifyingglass")
        } description: {
            Text("No offline photo matches that search.")
        }
        .accessibilityIdentifier("offlineNoResults")
    }
}

/// Identifiable wrapper so `.fullScreenCover(item:)` can open the viewer on the
/// cached list at a given position.
private struct OfflinePage: Identifiable {
    let index: Int
    var id: Int { index }
}

/// A cached asset tile. The image comes from the local file (`localFileURL`),
/// so this cell renders with the server unreachable — the grid is not just a
/// list of what *would* be available.
private struct OfflineAssetCell: View {
    let asset: AssetReactItem
    let baseURL: URL
    let token: String?
    let localFileURL: URL?
    var onTap: () -> Void = {}
    var onRemove: () -> Void = {}

    var body: some View {
        // The identifier sits on the IMAGE layer, never on the whole cell:
        // an identifier on a container replaces its descendants' identifiers in
        // the accessibility tree, which would make `offlineCachedBadge`
        // unreachable exactly when a test needs it.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AuthenticatedAsyncImage(
                    url: asset.thumbnailURL(base: baseURL, size: .thumbnail),
                    token: token,
                    localFileURL: localFileURL
                )
                .accessibilityIdentifier("offlineAsset_\(asset.id)")
            }
            .overlay(alignment: .bottomLeading) { videoBadge }
            .overlay(alignment: .topTrailing) { cachedBadge }
            .clipShape(RoundedRectangle(cornerRadius: PVRadius.xs, style: .continuous))
            .contentShape(Rectangle())
            // The tap stays on the cell's own gesture: wrapping an
            // `AssetThumbnailCell`-style tile in a `Button` swallows it.
            .onTapGesture(perform: onTap)
            .contextMenu {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove from Offline", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private var cachedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2.5)
            .padding(6)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("offlineCachedBadge")
            .accessibilityLabel("Available offline")
    }

    @ViewBuilder
    private var videoBadge: some View {
        if asset.isVideo {
            let durationText: String? = {
                guard let d = asset.duration, d > 0 else { return nil }
                return AssetThumbnailCell.formattedDuration(d)
            }()

            Group {
                if let durationText {
                    Label(durationText, systemImage: "play.fill")
                } else {
                    Image(systemName: "play.fill").font(.system(size: 8)) // DS-exempt: badge micro-glyph §8.6
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white) // DS-exempt: badge contrast
            .padding(.horizontal, 6)
            .padding(.vertical, 3) // DS-exempt: badge micro-padding
            .background(Color.black.opacity(0.4), in: Capsule())
            .padding(5)
        }
    }
}
