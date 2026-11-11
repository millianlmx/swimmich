import SwiftUI

/// Creates a memory from a photo selection.
///
/// The server's `POST /api/memories` body is `{ assetIds, data: { year },
/// memoryAt, type }` — a memory is a **date**, a type and a set of assets.
/// There is no name, description or title field anywhere in the memory API, so
/// this sheet collects a date and a selection, nothing else; the picker itself
/// is the shared `AssetMultiSelectGrid`.
///
/// `type` is sent as `on_this_day`: the server knows `on_this_day` and
/// `birthday` (v3.3+), and this app only ever creates `on_this_day`.
struct CreateMemorySheet: View {
    @Bindable var vm: MemoriesViewModel
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: PVSpacing.s0) {
                DatePicker("Memory date", selection: $vm.memoryDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .padding(.horizontal, PVSpacing.s16)
                    .padding(.vertical, PVSpacing.s8)
                    .accessibilityIdentifier("memoryDatePicker")

                AssetMultiSelectGrid(
                    assets: vm.recentAssets,
                    selectedIds: vm.selectedIds,
                    isLoading: vm.isLoadingAssets,
                    canLoadMore: vm.canLoadMoreAssets,
                    errorMessage: vm.errorMessage,
                    baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
                    token: auth.accessToken,
                    selectionHint: "Pick at least 1 photo. Its date sets the memory's year.",
                    emptyMessage: "Your library has no photos to build a memory from.",
                    onLoadMore: { await vm.loadMoreAssets() },
                    onToggle: { vm.toggleSelection(id: $0) }
                )
            }
            .navigationTitle("New Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await vm.createMemory() }
                    }
                    .disabled(vm.selectedIds.isEmpty || vm.isCreating)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("confirmCreateMemory")
                }
            }
        }
        .task { await vm.beginPicking() }
    }
}

/// Adds photos to an existing memory (`PUT /api/memories/{id}/assets`).
///
/// The memory's own assets are hidden from the grid rather than merely
/// unchecked: the route unions the ids it is given, so re-sending a member is a
/// needless round-trip.
struct AddPhotosToMemorySheet: View {
    let memoryId: String
    let existingAssetIds: Set<String>

    @Bindable var vm: MemoriesViewModel
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AssetMultiSelectGrid(
                assets: vm.recentAssets,
                selectedIds: vm.selectedIds,
                isLoading: vm.isLoadingAssets,
                canLoadMore: vm.canLoadMoreAssets,
                errorMessage: vm.errorMessage,
                baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
                token: auth.accessToken,
                excluding: existingAssetIds,
                selectionHint: "Pick at least 1 photo to add to this memory.",
                emptyMessage: "Every photo in your library is already in this memory.",
                onLoadMore: { await vm.loadMoreAssets() },
                onToggle: { vm.toggleSelection(id: $0) }
            )
            .navigationTitle("Add Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await add() }
                    }
                    .disabled(vm.selectedIds.isEmpty)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("confirmAddPhotosToMemory")
                }
            }
        }
        .task { await vm.beginPicking() }
    }

    /// Only dismisses on success: a failure has to stay on screen, with its
    /// message and the user's selection intact.
    private func add() async {
        let added = await vm.addAssets(toMemoryId: memoryId, assetIds: vm.orderedSelection)
        guard added else { return }
        dismiss()
    }
}
