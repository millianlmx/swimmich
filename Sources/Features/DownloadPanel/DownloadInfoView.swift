import SwiftUI

/// The download queue in detail (gap G10): one row per file, with the actions
/// the row allows.
///
/// Presented in a sheet by `RootView`, so it declares **no** stack of its own
/// — the presenting sheet owns it, and a second one would draw a second
/// navigation bar (the `LanguageSettingsView` rule). "Done" only closes the
/// screen: the queue keeps running, which is the whole point of the feature.
struct DownloadInfoView: View {
    @Bindable var vm: DownloadQueueViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// The offline cache's mirror, so a row can say "you already have this
    /// one" without this screen writing to the cache.
    @Environment(OfflineAssetIndex.self) private var offlineIndex: OfflineAssetIndex?

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s16) {
                if let message = vm.errorMessage {
                    InlineErrorBadge(message: message)
                        .accessibilityIdentifier("downloadInfoError")
                }

                if vm.items.isEmpty {
                    emptyState
                } else {
                    summary
                    sections
                }
            }
            .padding(PVSpacing.s16)
        }
        .background(Color.bgPrimary)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ImmichAppBar(title: "Downloads")
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear completed") { vm.clearCompleted() }
                    // Cancelled rows are cleared with the finished ones (the
                    // VM explains why), so they count towards the button.
                    .disabled(vm.completedCount + vm.cancelledCount == 0)
                    .accessibilityIdentifier("downloadInfoClearCompleted")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("downloadInfoDone")
            }
        }
        .onAppear { vm.refreshFileAvailability() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            vm.refreshFileAvailability()
        }
    }

    // MARK: - Header

    private var summary: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            Text("\(vm.completedCount) of \(vm.totalCount)")
                .font(.pvNumeric)
                .accessibilityIdentifier("downloadInfoSummary")
            Text(vm.formattedAggregateSize)
                .font(.pvSubhead)
                .foregroundStyle(Color.textSecondaryPV)
            // Removed rather than shown indeterminate when nothing announced
            // a length: the counts stay exact either way.
            if let fraction = vm.aggregateProgress {
                ProgressView(value: fraction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PVSpacing.s16)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No downloads yet",
            systemImage: "arrow.down.circle",
            description: Text("Download a photo to see it here.")
        )
    }

    // MARK: - Sections

    @ViewBuilder
    private var sections: some View {
        section("Downloading", status: .running)
        section("Queued", status: .queued)
        section("Failed", status: .failed)
        section("Cancelled", status: .cancelled)
        section("Completed", status: .completed)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, status: DownloadStatus) -> some View {
        let rows = vm.items.filter { $0.status == status }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: PVSpacing.s8) {
                Text(title)
                    .font(.pvSubhead)
                    .foregroundStyle(Color.textSecondaryPV)
                ForEach(rows) { item in
                    row(item)
                }
            }
        }
    }

    // MARK: - Row

    private func row(_ item: DownloadItem) -> some View {
        HStack(alignment: .center, spacing: PVSpacing.s12) {
            Image(systemName: item.isArchive ? "doc.zipper" : "photo")
                .font(.pvHeadline)
                .foregroundStyle(Color.textSecondaryPV)
                .frame(width: 24)
                .contentTransition(.symbolEffect(.replace))

            // The identifier sits on the row's text block, never on the row:
            // an identifier on a container replaces its descendants', which
            // would put Cancel and Retry out of reach.
            VStack(alignment: .leading, spacing: PVSpacing.s4) {
                Text(item.fileName)
                    .font(.pvSubhead)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: PVSpacing.s8) {
                    Text(item.formattedSize)
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                    if let fraction = item.progress {
                        ProgressView(value: fraction)
                            .frame(maxWidth: .infinity)
                    } else if item.status == .running {
                        // No announced length: indeterminate, never a frozen 0 %.
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if offlineIndex?.isCached(item.assetId) == true {
                    PVStatusBadge(
                        text: String(localized: "Available offline"),
                        color: .immichSuccess,
                        symbol: "arrow.down.circle.fill"
                    )
                }

                if let message = item.errorMessage {
                    InlineErrorBadge(message: message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("downloadInfoRow_\(item.assetId)")

            action(for: item)
        }
        .padding(PVSpacing.s12)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
    }

    @ViewBuilder
    private func action(for item: DownloadItem) -> some View {
        switch item.status {
        case .running, .queued:
            Button("Cancel") { vm.cancel(assetId: item.assetId) }
                .buttonStyle(PVSubtleButtonStyle())
                .accessibilityIdentifier("downloadInfoCancel_\(item.assetId)")
        case .failed, .cancelled:
            // A cancelled row is offered a retry too: it is the only way back
            // from a stopped download.
            Button("Retry") { vm.retry(assetId: item.assetId) }
                .buttonStyle(PVSubtleButtonStyle())
                .accessibilityIdentifier("downloadInfoRetry_\(item.assetId)")
        case .completed:
            // The file belongs to the user (it lives in Documents/Downloads,
            // visible in Files): shown only while it is still on disk.
            if vm.shareableURL(for: item.id) != nil {
                Button("Share") { share(item) }
                    .buttonStyle(PVSubtleButtonStyle())
                    .accessibilityIdentifier("downloadInfoShare_\(item.assetId)")
            }
        }
    }

    /// Re-checks the file at the touch: a file removed since the last render
    /// presents nothing, and the button goes away. No completion is passed —
    /// `ActivityPresenter`'s callers delete the file in theirs, and this one is
    /// the user's.
    private func share(_ item: DownloadItem) {
        if let url = vm.shareableURL(for: item.id) {
            ActivityPresenter.present(items: [url])
        } else {
            vm.refreshFileAvailability()
        }
    }
}
