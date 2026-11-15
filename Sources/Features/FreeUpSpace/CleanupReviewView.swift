import SwiftUI

/// The review: what is about to leave the device, shown as the photos
/// themselves rather than as a count.
///
/// Pushed by `FreeUpSpaceView`, inside the hub's navigation stack — no
/// `NavigationStack` here either.
///
/// This screen never touches PhotoKit. It calls `deleteConfirmed()` on the view
/// model and lets the library layer do the deletion, so the destructive call
/// stays in `Sources/Services/` and the confirmation stays here.
struct CleanupReviewView: View {
    @Bindable var vm: FreeUpSpaceViewModel
    @Environment(\.dismiss) private var dismiss

    /// Presentation state belongs to the view, not the view model (same as
    /// `showResetTrackingConfirm` on the backup screen).
    @State private var showDeleteConfirm = false

    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: PVSpacing.s4), count: 3
    )

    var body: some View {
        VStack(spacing: PVSpacing.s0) {
            header
            grid
        }
        .background(Color.bgPrimary)
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { freeUpButton }
        // An alert, not a confirmationDialog: on iOS 26 a confirmationDialog is a popover that drops Cancel.
        .alert(
            "Delete \(vm.candidates.count) items from this device?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await vm.deleteConfirmed() != nil { dismiss() }
                }
            }
            .accessibilityIdentifier("cleanupReviewConfirm")

            Button("Cancel", role: .cancel) {}
        } message: {
            // What the system alert cannot say: the size, the cutoff that
            // selected these, and where the originals end up. Photos will still
            // ask its own "Allow deleting N items?" — this dialog is not a
            // second "are you sure", it is the missing context.
            Text("\(StorageStatsViewModel.format(vm.reclaimableBytes)) of originals taken on or before \(vm.settings.cutoffDate?.formatted(date: .abbreviated, time: .omitted) ?? ""). They go to the system Recently Deleted album and stay available in Immich: only the copy on this device is removed.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            LabeledContent("Reclaimable", value: StorageStatsViewModel.format(vm.reclaimableBytes))
                .font(.pvHeadline)
                .accessibilityIdentifier("cleanupReviewReclaimableValue")
            LabeledContent("To delete", value: "\(vm.candidates.count)")
                .accessibilityIdentifier("cleanupReviewCountValue")
        }
        .padding(PVSpacing.s16)
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(spacing: PVSpacing.s12, pinnedViews: .sectionHeaders) {
                ForEach(days) { group in
                    Section {
                        LazyVGrid(columns: Self.columns, spacing: PVSpacing.s4) {
                            ForEach(group.items) { candidate in
                                BackupThumbnailView(localIdentifier: candidate.id)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                                    // One element per cell: a 3-column grid of
                                    // hundreds of assets would otherwise be
                                    // read as image/button pairs one by one.
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(vm.accessibilityLabel(for: candidate))
                                    // The cell's identity, not just its look:
                                    // "the review offers exactly the asset the
                                    // server confirmed" is a claim about WHICH
                                    // asset, and `FreeUpSpaceUITests` asserts it
                                    // by this identifier.
                                    .accessibilityIdentifier("cleanupReviewCell_\(candidate.id)")
                            }
                        }
                        .padding(.horizontal, PVSpacing.s16)
                    } header: {
                        dayHeader(group)
                    }
                }
            }
        }
    }

    private struct DayGroup: Identifiable {
        let id: Date
        let items: [CleanupCandidate]
        let byteSize: Int64
    }

    /// Grouped by the day the asset was taken, newest first — the timeline's own
    /// grouping, so the review matches how the user remembers the library.
    private var days: [DayGroup] {
        Dictionary(grouping: vm.candidates) { Calendar.current.startOfDay(for: $0.creationDate) }
            .map { day, items in
                DayGroup(
                    id: day,
                    items: items.sorted { $0.creationDate > $1.creationDate },
                    byteSize: items.reduce(0) { $0 + $1.byteSize }
                )
            }
            .sorted { $0.id > $1.id }
    }

    private func dayHeader(_ group: DayGroup) -> some View {
        HStack(spacing: PVSpacing.s8) {
            Text(group.id.formatted(date: .abbreviated, time: .omitted))
                .font(.pvSubhead.weight(.semibold))
                .foregroundStyle(Color.textPrimaryPV)
            Spacer()
            Text("\(group.items.count) items")
                .font(.pvCaption)
                .foregroundStyle(.secondary)
            Text(StorageStatsViewModel.format(group.byteSize))
                .font(.pvCaption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, PVSpacing.s16)
        .padding(.vertical, PVSpacing.s8)
        .background(Color.bgSecondary)
    }

    private var freeUpButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label("Free up space", systemImage: "externaldrive.badge.minus")
                .frame(maxWidth: .infinity)
                .padding(PVSpacing.s12)
        }
        .buttonStyle(PVSubtleButtonStyle())
        .disabled(vm.candidates.isEmpty || vm.isDeleting)
        .accessibilityIdentifier("cleanupReviewFreeButton")
        .padding(PVSpacing.s16)
        .background(Color.bgPrimary)
    }
}
