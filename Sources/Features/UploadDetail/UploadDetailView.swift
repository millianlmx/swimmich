import SwiftUI

/// What the last backup run did, asset by asset: what is in flight and how far
/// its iCloud download got, what was held back and why, what failed with its
/// size and a Retry that names that one asset.
///
/// It replaces the read-only `BackupFailuresSheet`: same name and reason, plus
/// the state, the size and the retry — in a page, because a sheet is handed a
/// *copy* of the failures array and so cannot follow assets still in flight.
///
/// Pushed from `BackupSettingsView`, itself pushed from `ProfileView`, which
/// already carries the `NavigationStack` — hence none here.
struct UploadDetailView: View {
    @PVReduceMotion private var reduceMotion
    @Bindable var vm: UploadDetailViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s16) {
                runHeader
                iCloudCard
                waitingSection
                uploadedSection
                failedSection
                if vm.isEmpty { emptyState }
            }
            .padding(PVSpacing.s16)
        }
        .refreshable { await vm.refresh() }
        .labeledContentStyle(.pvAdaptive)
        .background(Color.bgPrimary)
        .navigationTitle("Upload details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ImmichAppBar(title: "Upload details")
            }
        }
        .immichAppBarTitleHeader("Upload details")
    }

    // MARK: - Run header

    /// Global progress in compact form, the asset in flight projected into a
    /// state, and the only run control this screen owns: Stop, on the same
    /// `upload.cancelBackup()` the Backup screen calls.
    ///
    /// The state label is *not* the engine's `statusMessage`: that sentence
    /// belongs to the Backup screen, and repeating it here would print the same
    /// line twice.
    @ViewBuilder
    private var runHeader: some View {
        VStack(spacing: PVSpacing.s8) {
            if vm.isRunning {
                ProgressView(value: vm.progressFraction)
                    .tint(Color.immichPrimary)
                    .animation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion), value: vm.progressFraction)
                    .accessibilityIdentifier("uploadDetailProgress")
            }
            PVAdaptiveStack(hAlignment: .center, spacing: PVSpacing.s12) {
                if let id = vm.currentAssetID {
                    BackupThumbnailView(localIdentifier: id)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: PVRadius.sm, style: .continuous))
                }
                VStack(alignment: .leading, spacing: PVSpacing.s4) {
                    if vm.currentAssetID != nil {
                        Text(vm.currentStateLabel)
                            .font(.pvBody)
                        if let name = vm.currentFileName {
                            Text(name)
                                .font(.pvCaption)
                                .foregroundStyle(Color.textSecondaryPV)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("uploadDetailCurrentName")
                        }
                    } else if vm.isRunning {
                        // Between the scan and the first asset there is no
                        // current asset; saying so beats an empty row.
                        Label("Scanning your library…", systemImage: "magnifyingglass")
                            .font(.pvBody)
                            .foregroundStyle(Color.textSecondaryPV)
                    }
                    Text("\(vm.examinedCount) of \(vm.total)")
                        .font(.pvNumeric)
                        .foregroundStyle(Color.textSecondaryPV)
                        .contentTransition(PVMotion.contentChange(.numericText(), reduceMotion: reduceMotion))
                }
                Spacer(minLength: PVSpacing.s8)
            }
            if vm.isRunning { stopButton }
        }
    }

    private var stopButton: some View {
        Button {
            vm.cancel()
        } label: {
            Label(
                vm.isCancelling ? "Cancelling…" : "Stop",
                systemImage: vm.isCancelling ? "hourglass" : "stop.fill"
            )
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentTransition(PVMotion.contentChange(.symbolEffect(.replace), reduceMotion: reduceMotion))
        }
        .buttonStyle(.borderedProminent)
        .disabled(vm.isCancelling)
        .accessibilityIdentifier("uploadDetailCancelButton")
    }

    // MARK: - iCloud

    /// The one per-asset percentage that exists — an iCloud download reports a
    /// real fraction, where the upload protocol reports none. Hence a
    /// determined bar here and an indeterminate state for "Uploading".
    @ViewBuilder
    private var iCloudCard: some View {
        if let fraction = vm.currentICloudFraction {
            VStack(alignment: .leading, spacing: PVSpacing.s8) {
                Label("Downloading from iCloud", systemImage: "icloud.and.arrow.down")
                    .font(.pvSubhead.weight(.semibold))
                HStack(spacing: PVSpacing.s12) {
                    ProgressView(value: fraction)
                        .tint(Color.immichPrimary)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.pvNumeric)
                        .contentTransition(PVMotion.contentChange(.numericText(), reduceMotion: reduceMotion))
                }
            }
            .padding(PVSpacing.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.immichPrimary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous)
            )
            .accessibilityIdentifier("uploadDetailICloudCard")
        }
    }

    // MARK: - Sections

    /// Held back, not failed. One row per asset, and the promise that nothing
    /// has to be done about it: the next run picks it up.
    @ViewBuilder
    private var waitingSection: some View {
        if !vm.deferrals.isEmpty {
            VStack(alignment: .leading, spacing: PVSpacing.s8) {
                sectionTitle("Waiting")
                ForEach(vm.deferrals) { deferral in
                    UploadAssetRow(
                        thumbnailID: deferral.id,
                        name: deferral.name,
                        detail: UploadDetailViewModel.deferralLabel(deferral.reason),
                        detailColor: Color.immichWarning,
                        size: UploadDetailViewModel.formattedBytes(deferral.fileSize),
                        detailIcon: UploadDetailViewModel.deferralIcon(deferral.reason),
                        footnote: String(localized: "Retried automatically on the next run"),
                        rowIdentifier: "uploadDetailDeferralRow_\(deferral.id)",
                        nameIdentifier: "uploadDetailRowName_\(deferral.id)"
                    ) {
                        EmptyView()
                    }
                }
            }
        }
    }

    /// The successes, as a total. The engine keeps `uploadedCount` and the bytes
    /// of what it uploaded, not a row per uploaded asset — listing them would
    /// mean a per-asset record on a run of thousands.
    @ViewBuilder
    private var uploadedSection: some View {
        if vm.uploadedCount > 0 {
            VStack(spacing: PVSpacing.s8) {
                LabeledContent("Uploaded") {
                    Text("\(vm.uploadedCount)")
                        .font(.pvNumeric)
                        .contentTransition(PVMotion.contentChange(.numericText(), reduceMotion: reduceMotion))
                        .accessibilityIdentifier("uploadDetailUploadedValue")
                }
                LabeledContent("Size") {
                    Text(UploadDetailViewModel.formattedBytes(vm.uploadedBytes))
                        .font(.pvNumeric)
                        .accessibilityIdentifier("uploadDetailUploadedBytesValue")
                }
            }
            .padding(PVSpacing.s12)
            .frame(maxWidth: .infinity)
            .background(
                Color.bgSecondary,
                in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous)
            )
        }
    }

    /// The failures, each with its own reason, size and retry — the sheet's
    /// content plus everything the sheet couldn't offer. "Retry all" is one
    /// restricted run over exactly these assets, not a rescan of the library.
    @ViewBuilder
    private var failedSection: some View {
        if !vm.failures.isEmpty {
            VStack(alignment: .leading, spacing: PVSpacing.s8) {
                HStack {
                    sectionTitle("Failed")
                    Spacer()
                    Button {
                        Task { await vm.retryAllFailed() }
                    } label: {
                        // The frame sits inside the label so the tap target
                        // really is 44 pt tall — a frame around a button box
                        // does not extend its hit region.
                        Text("Retry all").frame(minHeight: 44)
                    }
                    .disabled(vm.isRunning)
                    .accessibilityIdentifier("uploadDetailRetryAllButton")
                }
                ForEach(vm.failures) { failure in
                    UploadAssetRow(
                        thumbnailID: failure.assetID,
                        name: failure.name,
                        detail: failure.reason,
                        detailColor: Color.immichError,
                        size: UploadDetailViewModel.formattedBytes(failure.fileSize),
                        rowIdentifier: "uploadDetailFailureRow_\(failure.assetID)",
                        nameIdentifier: "uploadDetailRowName_\(failure.assetID)"
                    ) {
                        Button {
                            Task { await vm.retry(id: failure.assetID) }
                        } label: {
                            Text("Retry").frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.isRunning)
                        .accessibilityIdentifier("uploadDetailRetryButton_\(failure.assetID)")
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing to upload",
            systemImage: "checkmark.circle",
            description: Text("The last backup left nothing to do.")
        )
        .accessibilityIdentifier("uploadDetailEmptyState")
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.pvSubhead.weight(.semibold))
            .foregroundStyle(Color.textPrimaryPV)
    }
}

/// One asset line: thumbnail, name, a state or failure line, the size — and, on
/// the right, whatever action the row offers (the failures' Retry; nothing on a
/// deferral). Local to this screen: no other screen renders a per-asset backup
/// row, and the design tokens come from the catalog, not from a new component.
struct UploadAssetRow<Trailing: View>: View {
    let thumbnailID: String?
    let name: String
    let detail: String
    let detailColor: Color
    let size: String
    /// Icon for the detail line (`Waiting for Wi-Fi` reads better with one);
    /// failures keep the reason as plain text.
    var detailIcon: String? = nil
    /// Extra line under the size — the deferrals' "retried automatically".
    var footnote: String? = nil
    /// Identifier of the row as a single accessibility element. It goes on the
    /// combined text block, never on the row container: an identifier on a
    /// container that holds a button shadows the button's own.
    var rowIdentifier: String? = nil
    /// Identifier of the file name's own `Text`.
    var nameIdentifier: String? = nil
    let trailing: () -> Trailing

    var body: some View {
        PVAdaptiveStack(hAlignment: .center, spacing: PVSpacing.s12) {
            HStack(spacing: PVSpacing.s12) {
                BackupThumbnailView(localIdentifier: thumbnailID)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: PVRadius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: PVSpacing.s4) {
                    Text(name)
                        .font(.pvBody)
                        .foregroundStyle(Color.textPrimaryPV)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(nameIdentifier ?? "")
                    detailLine
                    Text(size)
                        .font(.pvNumeric)
                        .foregroundStyle(Color.textSecondaryPV)
                    if let footnote {
                        Text(footnote)
                            .font(.pvCaption)
                            .foregroundStyle(Color.textSecondaryPV)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(rowIdentifier ?? "")
            }
            Spacer(minLength: PVSpacing.s8)
            trailing()
        }
        .padding(PVSpacing.s12)
        .background(
            Color.bgSecondary,
            in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous)
        )
    }

    @ViewBuilder
    private var detailLine: some View {
        if let detailIcon {
            Label(detail, systemImage: detailIcon)
                .font(.pvCaption)
                .foregroundStyle(detailColor)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(detail)
                .font(.pvCaption)
                .foregroundStyle(detailColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
