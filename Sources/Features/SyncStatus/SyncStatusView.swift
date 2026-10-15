import SwiftUI

/// Sync status screen — raised by the `SyncStatusButton` every tab's bar
/// carries, and presented in a sheet by `RootView`. The sheet owns the
/// navigation stack (this view declares none of its own: a second one would draw
/// two navigation bars), and "Done" only closes the screen — a run it started
/// keeps going.
///
/// Every figure on screen is a projection of the ledger, of the current run or
/// of the offline index, all read through `SyncStatusViewModel`: the screen
/// shows state, it never computes it. Nothing here talks to the network — a
/// cached asset is a fact about this device, and the server has no endpoint
/// that would report a backup's progress anyway.
struct SyncStatusView: View {
    @Bindable var vm: SyncStatusViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var showResetLedgerConfirm = false
    @State private var showClearOfflineConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s16) {
                if vm.isEmpty {
                    emptyState
                } else {
                    countsCard
                    activityCard
                }

                if vm.isRunning {
                    progressCard
                }

                errors

                actionsCard

                if !vm.failures.isEmpty {
                    failuresCard
                }
            }
            .padding(PVSpacing.s16)
        }
        .background(Color.bgPrimary)
        .navigationTitle("Sync Status")
        .navigationBarTitleDisplayMode(.inline)
        // The only way out: the screen is a sheet now, and its destructive
        // actions are behind confirmation dialogs a swipe-down would dismiss
        // mid-question.
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("syncStatusDone")
            }
        }
        .task { await vm.refresh() }
        .refreshable { await vm.refresh() }
        .confirmationDialog(
            "Reset tracked assets?",
            isPresented: $showResetLedgerConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset tracking", role: .destructive) { vm.resetLedger() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next backup will re-check every photo.")
        }
        .confirmationDialog(
            "Clear offline cache?",
            isPresented: $showClearOfflineConfirm,
            titleVisibility: .visible
        ) {
            Button("Purge offline cache", role: .destructive) {
                Task { await vm.clearOfflineCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded files will need to be downloaded again.")
        }
    }

    // MARK: - Counters

    /// The ledger and the current run in eight tiles: what is tracked, what is
    /// still moving, what the server already had, what failed, what is pinned.
    private var countsCard: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: PVSpacing.s8),
                GridItem(.flexible(), spacing: PVSpacing.s8),
            ],
            spacing: PVSpacing.s8
        ) {
            StatTile(
                title: "Tracked",
                value: Text(vm.trackedCount, format: .number),
                systemImage: "tray.full",
                identifier: "syncStatusTrackedValue"
            )
            StatTile(
                title: "Waiting",
                value: Text(vm.pendingCount, format: .number),
                systemImage: "clock",
                badge: deferralBadge,
                identifier: "syncStatusPendingValue"
            )
            StatTile(
                title: "Ready to upload",
                value: Text(vm.stagedCount, format: .number),
                systemImage: "arrow.up.circle",
                identifier: "syncStatusStagedValue"
            )
            StatTile(
                title: "Uploaded",
                value: Text(vm.uploadedCount, format: .number),
                systemImage: "checkmark.circle",
                identifier: "syncStatusUploadedValue"
            )
            StatTile(
                title: "Already on server",
                value: Text(vm.alreadyOnServerCount, format: .number),
                systemImage: "server.rack",
                identifier: "syncStatusAlreadyOnServerValue"
            )
            StatTile(
                title: "Failed",
                value: Text(vm.failedCount, format: .number),
                systemImage: "exclamationmark.triangle",
                identifier: "syncStatusFailedValue"
            )
            StatTile(
                title: "Offline",
                value: Text(vm.offlineCount, format: .number),
                systemImage: "arrow.down.circle",
                identifier: "syncStatusOfflineValue"
            )
            StatTile(
                title: "Offline size",
                value: Text(vm.formattedOfflineBytes()),
                systemImage: "internaldrive",
                identifier: "syncStatusOfflineBytesValue"
            )
        }
    }

    /// Names the cause when the run held assets back: "waiting" alone would not
    /// tell the user whether to plug in or to wait for iCloud.
    private var deferralBadge: TileBadge? {
        if vm.waitingForWiFi {
            return TileBadge(text: String(localized: "Waiting"), color: .immichWarning, symbol: "wifi")
        }
        if vm.waitingForICloud {
            return TileBadge(
                text: String(localized: "Waiting"),
                color: .immichWarning,
                symbol: "icloud.and.arrow.down"
            )
        }
        return nil
    }

    // MARK: - Dates

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            HStack(spacing: PVSpacing.s8) {
                LabeledContent("Last run", value: vm.formattedLastRun())
                    .accessibilityIdentifier("syncStatusLastRunValue")

                if let run = vm.lastRun {
                    if run.success {
                        PVStatusBadge(
                            text: String(localized: "Backup complete"),
                            color: .immichSuccess,
                            symbol: "checkmark.circle"
                        )
                    } else {
                        PVStatusBadge(
                            text: String(localized: "Backup finished with errors"),
                            color: .immichError,
                            symbol: "exclamationmark.triangle"
                        )
                    }
                }
            }

            LabeledContent("Last server check", value: vm.formattedLastServerCheck())
                .accessibilityIdentifier("syncStatusLastServerCheckValue")
        }
        .padding(PVSpacing.s12)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
    }

    // MARK: - Live run

    /// Determinate on purpose: `progressFraction` counts staged work half a
    /// step, so the bar moves through the export/hash pass instead of sitting
    /// at zero — an indeterminate spinner would throw that information away.
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            ProgressView(value: vm.progressFraction)
                .accessibilityIdentifier("syncStatusProgress")

            HStack(spacing: PVSpacing.s8) {
                if let name = vm.currentFileName {
                    Text(name)
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Text(vm.progressFraction, format: .percent)
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
                    .contentTransition(.numericText())
            }
        }
        .padding(PVSpacing.s12)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
        .transition(.opacity)
    }

    // MARK: - Errors

    @ViewBuilder
    private var errors: some View {
        if let message = vm.runErrorMessage {
            InlineErrorBadge(message: message)
        }
        if let message = vm.offlineErrorMessage {
            InlineErrorBadge(message: message) {
                Task { await vm.refresh() }
            }
        }
    }

    // MARK: - Actions

    private var actionsCard: some View {
        VStack(spacing: PVSpacing.s8) {
            if vm.isRunning {
                Button {
                    vm.cancelRun()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isCancelling)
                .accessibilityIdentifier("syncStatusCancel")
            } else {
                Button {
                    Task { await vm.runNow() }
                } label: {
                    Label("Run now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("syncStatusRunNow")
            }

            Button {
                Task { await vm.reconcileNow() }
            } label: {
                Label("Check server", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.isRunning)
            .accessibilityIdentifier("syncStatusReconcile")

            Button(role: .destructive) {
                showResetLedgerConfirm = true
            } label: {
                Label("Reset tracking", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.isRunning)
            .accessibilityIdentifier("syncStatusResetLedger")

            Button(role: .destructive) {
                showClearOfflineConfirm = true
            } label: {
                Label("Purge offline cache", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(vm.isRunning || vm.offlineCount == 0)
            .accessibilityIdentifier("syncStatusClearOffline")
        }
    }

    // MARK: - Failures

    /// Read-only list: opening one asset's state belongs to the per-asset run
    /// detail, so this screen only names what failed and why.
    private var failuresCard: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            Text("Failed")
                .font(.pvHeadline)

            ForEach(Array(vm.failures.enumerated()), id: \.element.id) { index, failure in
                VStack(alignment: .leading, spacing: PVSpacing.s2) {
                    Text(failure.name)
                        .font(.pvSubhead)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(failure.reason)
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("syncStatusFailureRow_\(index)")
            }
        }
        .padding(PVSpacing.s12)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing to sync yet",
            systemImage: "arrow.triangle.2.circlepath",
            description: Text("Back up your library to see its status here.")
        )
        .accessibilityIdentifier("syncStatusEmptyState")
    }
}

// MARK: - Tile

/// A label + a big value. The value is already formatted by the view model
/// (counts by `FormatStyle`, bytes by the download view model), so two screens
/// can never disagree about how the same number reads.
private struct StatTile: View {
    let title: LocalizedStringKey
    let value: Text
    let systemImage: String
    var badge: TileBadge?
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s4) {
            Label(title, systemImage: systemImage)
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)

            value
                .font(.pvNumeric)
                .foregroundStyle(Color.textPrimaryPV)
                .contentTransition(.numericText())

            if let badge {
                PVStatusBadge(text: badge.text, color: badge.color, symbol: badge.symbol)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PVSpacing.s12)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.md, style: .continuous))
        // One element per tile: VoiceOver reads "Tracked, 12" instead of two
        // unrelated fragments, and the identifier stays on the element a UI
        // test can actually reach.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// A pill carried by a tile (the tile is already one accessibility element, so
/// the badge rides along with it).
private struct TileBadge {
    let text: String
    let color: Color
    let symbol: String
}
