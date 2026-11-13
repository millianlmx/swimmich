import SwiftUI

/// The navigation bar of the result grid while it is selecting (L-23b): Cancel
/// on the leading side, the timeline's batch actions on the trailing side, with
/// the timeline's identifiers (`addToAlbumButton`, `archiveButton`, …) so one
/// vocabulary names them on both screens. Every action is the timeline's own
/// request (`SearchViewModel` forwards to the same engine); the two that need
/// the view — the delete confirmation and the album sheet — are closures.
struct SearchSelectionToolbar: ToolbarContent {
    let vm: SearchViewModel
    let userId: String?
    let onConfirmDelete: () -> Void
    let onAddToAlbum: () -> Void
    let onDownload: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                vm.exitSelectionMode()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("searchSelectionCancelButton")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            let empty = vm.selectedIds.isEmpty

            Button {
                Task { await vm.favoriteSelected(currentUserId: userId) }
            } label: {
                Label("Favorite", systemImage: "heart")
                    .labelStyle(.iconOnly)
            }
            .disabled(empty)
            .accessibilityIdentifier("favoriteSelectedButton")

            Button(role: .destructive) {
                // Nothing sendable: no confirmation (nothing would be deleted);
                // the "Partner photos skipped" notice shows alone.
                if vm.ownerScopedSelection(currentUserId: userId).ids.isEmpty {
                    Task { await vm.deleteSelected(currentUserId: userId) }
                } else {
                    onConfirmDelete()
                }
            } label: {
                Label("Delete", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .disabled(empty)
            .accessibilityIdentifier("deleteSelectedButton")

            Button(action: onAddToAlbum) {
                Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                    .labelStyle(.iconOnly)
            }
            .disabled(empty)
            .accessibilityIdentifier("addToAlbumButton")

            if vm.selectionOffersUnarchive {
                Button {
                    Task { await vm.unarchiveSelected() }
                } label: {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .disabled(empty)
                .accessibilityIdentifier("unarchiveButton")
            } else {
                Button {
                    Task { await vm.archiveSelected(currentUserId: userId) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                        .labelStyle(.iconOnly)
                }
                .disabled(empty)
                .accessibilityIdentifier("archiveButton")
            }

            Button {
                Task { await vm.moveSelectedToLockedFolder(currentUserId: userId) }
            } label: {
                Label("Move to Locked Folder", systemImage: "lock")
                    .labelStyle(.iconOnly)
            }
            .disabled(empty)
            .accessibilityIdentifier("moveToLockedFolderButton")

            Button {
                Task { await vm.stackSelected(currentUserId: userId) }
            } label: {
                Label("Stack", systemImage: "square.stack.3d.up")
                    .labelStyle(.iconOnly)
            }
            .disabled(vm.selectedIds.count < 2)
            .accessibilityIdentifier("stackButton")

            Button(action: onDownload) {
                Label("Download", systemImage: "arrow.down.circle")
                    .labelStyle(.iconOnly)
            }
            .disabled(empty)
            .accessibilityIdentifier("downloadSelectionButton")
        }
    }
}

/// What the batch actions present over the results: the delete confirmation,
/// the refusal / partner-notice alerts (as the timeline words them), the album
/// sheet, and the selection haptics.
struct SearchSelectionPresentations: ViewModifier {
    let vm: SearchViewModel
    let userId: String?
    @Binding var pendingDelete: Bool
    @Binding var presentAlbumPicker: Bool

    func body(content: Content) -> some View {
        content
            .appSensoryFeedback(.selection, trigger: vm.selectionMode)
            .appSensoryFeedback(.selection, trigger: vm.selectedIds.count)
            .alert("Delete \(vm.ownerScopedSelection(currentUserId: userId).ids.count) assets?", isPresented: $pendingDelete) {
                Button("Delete", role: .destructive) {
                    Task { await vm.deleteSelected(currentUserId: userId) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let skipped = vm.ownerScopedSelection(currentUserId: userId).skipped
                if skipped > 0 {
                    Text("\(skipped) photos belong to a partner and will not be deleted. The others are removed from your library. Action cannot be undone.")
                } else {
                    Text("This removes them from your library. Action cannot be undone.")
                }
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { vm.actionErrorMessage != nil },
                set: { if !$0 { vm.actionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: vm.actionErrorMessage ?? "")
            }
            .alert("Partner photos skipped", isPresented: Binding(
                get: { vm.skippedPartnerCount != nil },
                set: { if !$0 { vm.skippedPartnerCount = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(vm.skippedPartnerCount ?? 0) photos belong to a partner and were not changed.")
            }
            .sheet(isPresented: $presentAlbumPicker) {
                AddToAlbumPickerSheet(selectedAssetIds: vm.selectedIds) {
                    vm.exitSelectionMode()
                }
            }
    }
}
