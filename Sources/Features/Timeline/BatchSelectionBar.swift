import SwiftUI

/// The selection bar of the photo grids, written once (L-23b): Cancel on the
/// leading side, the batch actions of the timeline on the trailing side,
/// and everything those actions raise — the delete confirmation, the
/// "edited version or original" question of a download, the refusal and
/// partner-notice alerts, the album sheet and the haptics. The timeline and the
/// search results both apply it, so an evolution of the bar (an action, an
/// identifier, an alert) lands on both screens; two copies had already diverged.
///
/// The bar calls the model's batch methods without logic of its own: the
/// requests, the owner rules and the read-only refusal are the model's (the
/// timeline's, which the search model forwards to). What stays with each screen
/// is the way into the selection (its Select button, its long press), the
/// navigation title and the grid itself.
struct BatchSelectionBar<Model: BatchSelectionModel>: ViewModifier {
    let model: Model
    let userId: String?
    let downloads: DownloadQueueViewModel
    /// True while a viewer covers the screen: the alerts wait for it to close.
    let alertsSuspended: Bool

    @State private var pendingDelete = false
    /// The selection waiting for the "edited version or original" answer (L-21).
    @State private var pendingDownload: [AssetReactItem]?
    @State private var presentAlbumPicker = false
    @State private var favoriteTick = 0
    @State private var deleteTick = 0
    @State private var creation: SelectionCreation?
    @Environment(AuthViewModel.self) private var auth

    func body(content: Content) -> some View {
        content
            .toolbar { selectionToolbar }
            .appSensoryFeedback(.selection, trigger: model.selectionMode)
            .appSensoryFeedback(.success, trigger: favoriteTick)
            .appSensoryFeedback(.warning, trigger: deleteTick)
            // L-21: the selection may hold photos edited on the server — which file does the user want?
            .alert(
                "Which version?",
                isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }),
                presenting: pendingDownload
            ) { selection in
                Button("Edited version") { download(selection, edited: true) }
                    .accessibilityIdentifier("downloadChoiceEdited")
                Button("Original") { download(selection, edited: false) }
                    .accessibilityIdentifier("downloadChoiceOriginal")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Photos with edits saved on the server come as edited or as uploaded.")
            }
            .alert("Delete \(model.ownerScopedSelection(currentUserId: userId).ids.count) assets?", isPresented: $pendingDelete) {
                Button("Delete", role: .destructive) {
                    Task {
                        await model.deleteSelected(currentUserId: userId)
                        deleteTick &+= 1
                    }
                }
                // Backed-up photos this device still holds: their copies too.
                if !model.deviceCopies(of: model.ownerScopedSelection(currentUserId: userId).ids).isEmpty {
                    Button("Delete from This Device Too", role: .destructive) {
                        Task {
                            await model.deleteSelectedEverywhere(currentUserId: userId)
                            deleteTick &+= 1
                        }
                    }
                    .accessibilityIdentifier("batchDeleteEverywhere")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let skipped = model.ownerScopedSelection(currentUserId: userId).skipped
                if skipped > 0 {
                    Text("\(skipped) photos belong to a partner and will not be deleted. The others are removed from your library. Action cannot be undone.")
                } else {
                    Text("This removes them from your library. Action cannot be undone.")
                }
            }
            // D3: surface model errors (favorite/delete/load failures, the read-only refusal) — never swallow silently.
            .alert("Something went wrong", isPresented: Binding(
                get: { model.actionErrorMessage != nil && !alertsSuspended },
                set: { if !$0 { model.actionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(verbatim: model.actionErrorMessage ?? "")
            }
            // Partner photos left out of a selection action (owner-only rights) — an
            // outcome, not a failure, hence its own title. Same viewer rule as above.
            .alert("Partner photos skipped", isPresented: Binding(
                get: { model.skippedPartnerCount != nil && !alertsSuspended },
                set: { if !$0 { model.skippedPartnerCount = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(model.skippedPartnerCount ?? 0) photos belong to a partner and were not changed.")
            }
            // AC-515 — Add to Album picker (shares AlbumsViewModel via environment, FM-3).
            .sheet(isPresented: $presentAlbumPicker) {
                AddToAlbumPickerSheet(selectedAssetIds: model.selectedIds) {
                    model.exitSelectionMode()
                }
            }
            .pvFullScreenCover(item: $creation) { creation in
                creation.view
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        if model.selectionMode {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.exitSelectionMode()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("selectionCancelButton")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                let empty = model.selectedIds.isEmpty

                Button {
                    Task {
                        await model.favoriteSelected(currentUserId: userId)
                        favoriteTick &+= 1
                    }
                } label: {
                    Label("Favorite", systemImage: "heart")
                        .labelStyle(.iconOnly)
                }
                .disabled(empty)
                .accessibilityIdentifier("favoriteSelectedButton")

                Button(role: .destructive) {
                    // Nothing sendable: no confirmation (nothing would be
                    // deleted); the "Partner photos skipped" notice shows alone.
                    if model.ownerScopedSelection(currentUserId: userId).ids.isEmpty {
                        Task {
                            await model.deleteSelected(currentUserId: userId)
                            deleteTick &+= 1
                        }
                    } else {
                        pendingDelete = true
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .disabled(empty)
                // Matched by identifier in `ReadOnlyModeUITests`: the label is
                // translated, and the scenario taps this one control to attempt a
                // write the read-only guard must refuse.
                .accessibilityIdentifier("deleteSelectedButton")

                // AC-515 — Add to Album. Opens picker sheet w/ selected assets.
                Button {
                    presentAlbumPicker = true
                } label: {
                    Label("Add to Album", systemImage: "rectangle.stack.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .disabled(empty)
                .accessibilityIdentifier("addToAlbumButton")

                // Archive / Unarchive selected assets — bulk visibility.
                if model.selectionOffersUnarchive {
                    Button {
                        Task { await model.unarchiveSelected() }
                    } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(empty)
                    .accessibilityIdentifier("unarchiveButton")
                } else {
                    Button {
                        Task { await model.archiveSelected(currentUserId: userId) }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(empty)
                    .accessibilityIdentifier("archiveButton")
                }

                // Locked folder (gap G12) — bulk visibility "locked". The
                // assets leave the grid here and are the folder's business
                // from now on.
                Button {
                    Task { await model.moveSelectedToLockedFolder(currentUserId: userId) }
                } label: {
                    Label("Move to Locked Folder", systemImage: "lock")
                        .labelStyle(.iconOnly)
                }
                .disabled(empty)
                .accessibilityIdentifier("moveToLockedFolderButton")

                // Stack selected assets (gap #1) — 2+ required.
                Button {
                    Task { await model.stackSelected(currentUserId: userId) }
                } label: {
                    Label("Stack", systemImage: "square.stack.3d.up")
                        .labelStyle(.iconOnly)
                }
                .disabled(model.selectedIds.count < 2)
                .accessibilityIdentifier("stackButton")

                // Download selected (gap G10) — a batch goes to the process-wide
                // queue, which announces it to the server before streaming
                // (the server refuses a batch it was never told about). The
                // selection is the grid's, in grid order. Whether a photo of it
                // is edited is not known here, so on a server that serves edits
                // the user is asked which version to take (L-21).
                Button {
                    Task {
                        let selection = model.selectedItems
                        if await downloads.offersEditedChoice(forSelectionOf: selection) {
                            pendingDownload = selection
                        } else {
                            await downloads.enqueue(assets: selection, edited: false)
                            model.exitSelectionMode()
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .labelStyle(.iconOnly)
                }
                .disabled(empty)
                .accessibilityIdentifier("downloadSelectionButton")

                // Color mosaic or photo dump of the selection. Photos still
                // only on this device have nothing on the server to look at
                // and are left out.
                SelectionCreateMenu(isDisabled: empty) { make in
                    creation = make(model.selectedItems, auth.baseURL, auth.accessToken)
                }
            }
        }
    }

    /// The answer to "edited version or original": the whole selection goes to the queue with that choice.
    private func download(_ selection: [AssetReactItem], edited: Bool) {
        Task {
            await downloads.enqueue(assets: selection, edited: edited)
            model.exitSelectionMode()
        }
    }
}

extension View {
    /// The shared selection bar (`BatchSelectionBar`): apply it inside the
    /// screen's `NavigationStack`, where the navigation bar takes its items.
    func batchSelectionBar<Model: BatchSelectionModel>(
        _ model: Model,
        userId: String?,
        downloads: DownloadQueueViewModel,
        alertsSuspended: Bool
    ) -> some View {
        modifier(BatchSelectionBar(model: model, userId: userId, downloads: downloads, alertsSuspended: alertsSuspended))
    }
}
