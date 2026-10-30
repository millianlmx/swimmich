import SwiftUI

/// Asset Troubleshoot (gap G24) — the whole truth about one asset: what the
/// server holds, what the device kept, whether the backup ledger knows it, and
/// whether the server already has this checksum.
///
/// Reached from the info panel of a photo (`PhotoInfoPanel`), never from the
/// settings hub: the page is parameterized by the asset it describes, so a hub
/// row without one would open an empty screen. That sheet is its own
/// presentation, which is why this file — alone among the AppUtilities screens
/// — is wrapped in a `NavigationStack` by its host.
struct AssetTroubleshootView: View {
    @Bindable var vm: AssetTroubleshootViewModel
    let assetID: String

    var body: some View {
        List {
            if let error = vm.errorMessage {
                Section {
                    InlineErrorBadge(message: error) { Task { await vm.load(assetID: assetID) } }
                }
            }

            remoteSection
            localSection
            matchingSection
        }
        .navigationTitle("Asset Troubleshoot")
        .navigationBarTitleDisplayMode(.inline)
        // `id:` so a swipe to another photo, which reuses this screen's
        // position, re-reads the asset it now shows instead of keeping the
        // previous one's answers.
        .task(id: assetID) { await vm.load(assetID: assetID) }
    }

    // MARK: - Sections

    @ViewBuilder
    private var remoteSection: some View {
        Section {
            if let detail = vm.detail {
                row("ID", detail.id)
                row("Checksum", detail.checksum)
                    .accessibilityIdentifier("assetTroubleshootChecksum")
                row("Type", detail.type)
                row("Original name", detail.originalFileName)
                row("Original path", detail.originalPath)
                row("Owner ID", detail.ownerId)
                row("Library ID", detail.libraryId ?? "")
                row("Created", detail.createdAt)
                row("Updated", detail.updatedAt)
                row("File created", detail.fileCreatedAt)
                row("File modified", detail.fileModifiedAt)
                row("Dimensions", dimensions(detail))
                row("Duration", detail.duration.map { "\($0) ms" } ?? "")
                row("Live Photo ID", detail.livePhotoVideoId ?? "")
                row("Duplicate ID", detail.duplicateId ?? "")
                row("Visibility", detail.visibility)
                row("Favorite", AssetTroubleshootViewModel.flag(detail.isFavorite))
                row("Archived", AssetTroubleshootViewModel.flag(detail.isArchived))
                row("Trashed", AssetTroubleshootViewModel.flag(detail.isTrashed))
                row("Offline", AssetTroubleshootViewModel.flag(detail.isOffline))
                row("Edited", AssetTroubleshootViewModel.flag(detail.isEdited))
            } else if vm.isLoading {
                ProgressView()
            }
        } header: {
            Text("Remote asset")
        }
    }

    @ViewBuilder
    private var localSection: some View {
        Section {
            if let cached = vm.cached {
                row("File name", cached.fileName)
                row("Display name", cached.displayName)
                row("Cached at", vm.formattedCachedAt())
                row("Size", vm.formattedCachedSize())
            } else {
                LabeledContent("Offline", value: String(localized: "No"))
            }

            if vm.backupState != .unknown {
                HStack {
                    backupBadge
                    Spacer()
                }
            }
        } header: {
            Text("Local")
        }
    }

    /// The upstream `matching_assets` block, asked of the server: iOS keeps no
    /// local asset table to search by checksum, so "who else holds this file"
    /// is exactly the question `bulk-upload-check` answers. A `reject` names the
    /// server's own copy; an `accept` means the server has none.
    @ViewBuilder
    private var matchingSection: some View {
        Section {
            if let duplicate = vm.duplicateRemoteAssetID {
                row("Server copy", duplicate)
            } else if vm.detail != nil {
                LabeledContent("Server copy", value: String(localized: "Not on the server yet"))
            }
        } header: {
            Text("Matching assets")
        }
    }

    /// The ledger's verdict, or nothing at all before it has one.
    @ViewBuilder
    private var backupBadge: some View {
        switch vm.backupState {
        case .backedUp:
            PVStatusBadge(text: String(localized: "Backed up"), color: .immichSuccess, symbol: "checkmark.circle.fill")
        case .notTracked:
            PVStatusBadge(text: String(localized: "Not tracked"), color: .textSecondaryPV, symbol: "questionmark.circle")
        case .unknown:
            EmptyView()
        }
    }

    // MARK: - Rows

    /// One fact. An id is useless unless it can be pasted into a ticket, so
    /// every row copies itself on a long press.
    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(label, value: value.isEmpty ? "—" : value)
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = value
                }
            }
    }

    private func dimensions(_ detail: AssetResponseDto) -> String {
        [detail.width, detail.height]
            .compactMap { $0 }
            .map(String.init)
            .joined(separator: " × ")
    }
}
