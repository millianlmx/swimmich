import SwiftUI

/// Multi-select grid of the newest photos, paged through
/// `POST /api/search/metadata`.
///
/// Shared by the stack sheets (`CreateStackSheet`, `AddToStackSheet`) and the
/// memory sheets (`CreateMemorySheet`, `AddPhotosToMemorySheet`): the picking
/// surface is identical — only the state it reads and the sheet's CTA differ —
/// so there is one grid to keep right instead of one drifting copy per feature.
///
/// Owns no state: it renders what it is handed and reports taps back. The host
/// sheet is responsible for having opened the flow (`beginPicking`).
struct AssetMultiSelectGrid: View {
    let assets: [AssetReactItem]
    let selectedIds: Set<String>
    let isLoading: Bool
    /// False once the server reported no next page — the end of the library.
    let canLoadMore: Bool
    let errorMessage: String?
    let baseURL: URL
    let token: String?

    /// Members to leave out of the grid (a stack's existing photos, a memory's
    /// current ones). Kept out of the selection rather than merely unchecked:
    /// sending a member the collection already holds is a needless round-trip.
    var excluding: Set<String> = []

    /// The rule the sheet's CTA enforces, spelled out so a disabled button is
    /// explained rather than mysterious.
    let selectionHint: LocalizedStringKey

    /// Shown when the library has nothing left to offer.
    let emptyMessage: LocalizedStringKey

    let onLoadMore: () async -> Void
    let onToggle: (String) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3)

    /// What the grid actually renders — the picker's pages minus the excluded
    /// members. Empty while pages keep turning up nothing new is handled by
    /// `emptyState`, not by a dead-end empty state.
    private var visibleAssets: [AssetReactItem] {
        assets.filter { !excluding.contains($0.id) }
    }

    var body: some View {
        Group {
            if isLoading && assets.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleAssets.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    /// Nothing to show yet. Only a dead end once the library is exhausted —
    /// otherwise a page was entirely made of already-included photos, and the
    /// next page is on its way.
    @ViewBuilder
    private var emptyState: some View {
        if canLoadMore {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: assets.count) { await onLoadMore() }
        } else {
            ContentUnavailableView {
                Label("Nothing to add", systemImage: "photo.on.rectangle.angled")
            } description: {
                // `errorMessage` is server text (already localized upstream
                // when it is ours), `emptyMessage` is a key: they cannot share a
                // `??` because their types differ.
                if let errorMessage {
                    Text(errorMessage)
                } else {
                    Text(emptyMessage)
                }
            }
        }
    }

    private var grid: some View {
        ScrollView {
            selectionSummary

            LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                ForEach(visibleAssets) { asset in
                    // The tap goes through the cell's own `onTap`: wrapping it in
                    // a `Button` does not work, because `AssetThumbnailCell`
                    // attaches a descendant `onTapGesture` that wins over the
                    // button's action and would swallow every tap.
                    AssetThumbnailCell(
                        asset: asset,
                        baseURL: baseURL,
                        token: token,
                        selectionMode: true,
                        isSelected: selectedIds.contains(asset.id),
                        onTap: { onToggle(asset.id) }
                    )
                    .accessibilityIdentifier("pickerAsset_\(asset.id)")
                    .onAppear {
                        // Prefetch the next page a screenful early so the grid
                        // never dead-ends on a spinner.
                        if asset.id == visibleAssets.last?.id, canLoadMore {
                            Task { await onLoadMore() }
                        }
                    }
                }
            }
            .padding(.horizontal, PVSpacing.s4)

            if isLoading {
                ProgressView()
                    .padding(.vertical, PVSpacing.s16)
            }
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s2) {
            Text("\(selectedIds.count) selected")
                .font(.pvSubhead.weight(.semibold))
                .foregroundStyle(Color.textPrimaryPV)
            Text(selectionHint)
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PVSpacing.s16)
        .padding(.vertical, PVSpacing.s8)
    }
}
