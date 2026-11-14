import SwiftUI

/// Download Info (gap G24) — what the offline cache actually holds.
///
/// The mirror image of `download-panel`'s screen: that one shows transfers that
/// are happening, this one shows files that have already landed. They are never
/// the same question, so they are never the same screen.
///
/// Pushed from `ProfileView`'s Advanced section, which owns the hub's navigation
/// container — no `NavigationStack` here.
struct DownloadInventoryView: View {
    @Bindable var vm: DownloadInfoViewModel

    @State private var confirmPurge = false

    var body: some View {
        List {
            switch vm.renderState {
            case .loading:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .pvLoadingIndicator("downloadInfoLoading")
                        .listRowBackground(Color.clear)
                }
            case .error(let message):
                Section {
                    PVErrorStateView(
                        title: "Couldn't read downloaded files",
                        message: message,
                        identifierPrefix: "downloadInfo",
                        retry: { Task { await vm.load() } }
                    )
                    .listRowBackground(Color.clear)
                }
            case .empty:
                Section {
                    ContentUnavailableView(
                        "No downloaded files",
                        systemImage: "arrow.down.doc",
                        description: Text("Assets you keep offline will be listed here.")
                    )
                    .accessibilityIdentifier("downloadInfoEmptyState")
                    .listRowBackground(Color.clear)
                }
            case .data(let status):
                switch status {
                case .idle:
                    EmptyView()
                case .reloading:
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .pvLoadingIndicator("downloadInfoLoading")
                    }
                case .failed(let message):
                    Section {
                        InlineErrorBadge(message: message, retry: { Task { await vm.load() } })
                            .accessibilityIdentifier("downloadInfoRefreshError")
                    }
                }

                Section {
                    LabeledContent("Files", value: "\(vm.fileCount)")
                    LabeledContent("Total size", value: vm.formattedTotalSize())
                }

                Section {
                    ForEach(vm.files, id: \.id) { info in
                        row(info)
                    }

                    Button("Clear all", role: .destructive) { confirmPurge = true }
                        .accessibilityIdentifier("downloadInfoPurgeButton")
                }
            }
        }
        .navigationTitle("Download Info")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove all downloaded files?",
            isPresented: $confirmPurge,
            titleVisibility: .visible
        ) {
            Button("Clear all", role: .destructive) { Task { await vm.clearAll() } }
                .accessibilityIdentifier("downloadInfoPurgeConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files will need to be downloaded again.")
        }
        .offlinePurgeResultAlert(vm.purgeResult, dismiss: { vm.dismissPurgeResult() })
        .task { await vm.load() }
        .refreshable { await vm.refresh() }
    }

    /// One cached file: what it is, which file it is on disk, when it landed,
    /// and what it weighs — the four questions the screen exists to answer.
    private func row(_ info: CachedAssetInfo) -> some View {
        HStack(spacing: PVSpacing.s8) {
            VStack(alignment: .leading, spacing: PVSpacing.s4) {
                Text(info.displayName)
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                Text(vm.subtitle(for: info))
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
            }
            Spacer()
            Text(vm.formattedSize(info))
                .font(.pvNumeric)
                .foregroundStyle(Color.textSecondaryPV)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("downloadInfoRow_\(info.id)")
    }
}
