import SwiftUI

/// "Free Up Space" — cutoff and keep filters, the scan, and the numbers the
/// review screen is built on.
///
/// Pushed from the "Me" hub, so no `NavigationStack` is declared here: the hub
/// owns the stack, and a second one would put two navigation bars on screen
/// (the trap `LanguageSettingsView` hit).
///
/// Nothing on this screen deletes anything. The destructive call lives behind
/// the review's confirmation dialog, on a list the user has looked at.
struct FreeUpSpaceView: View {
    @Bindable var vm: FreeUpSpaceViewModel
    @State private var showSuccess = false

    var body: some View {
        Form {
            cutoffSection
            keepSection
            scanSection
            resultSection
        }
        .navigationTitle("Free Up Space")
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.loadAlbums() }
        .onChange(of: vm.lastDeletedCount) { _, count in
            guard count != nil else { return }
            // The deletion consumed the review: those assets are out of the
            // library, so the recap must not be able to offer them again
            // (upstream `CleanupNotifier.reset()` — the filters themselves stay).
            vm.resetScan()
            showSuccess = true
        }
        .onAppear {
            // Belt and braces for the same recap: the deletion lands while the
            // review screen is still on top, and an alert asked for in that tick
            // can be lost to the pop it triggers.
            if vm.lastDeletedCount != nil { showSuccess = true }
        }
        .alert("Space freed", isPresented: $showSuccess) {
            Button("OK", role: .cancel) { vm.acknowledgeDeletion() }
        } message: {
            // Deliberately "moved", not "reclaimed": the originals sit in the
            // system Recently Deleted album for ~30 days, which the app cannot
            // empty. Promising free space here would be a lie for a month.
            Text("\(vm.lastDeletedCount ?? 0) items moved to the system Recently Deleted album. Emptying it is what actually reclaims the space, and they stay available in Immich.")
        }
    }

    // MARK: - Cutoff

    private var cutoffSection: some View {
        Section {
            DatePicker(
                "Cutoff date",
                selection: cutoffBinding,
                in: ...Date.now,
                displayedComponents: .date
            )
            .accessibilityIdentifier("cleanupCutoffDatePicker")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PVSpacing.s8) {
                    ForEach(Self.presets) { preset in
                        CutoffPresetChip(
                            title: preset.title,
                            isSelected: isSelected(preset),
                            action: { vm.setCutoff(preset.date) }
                        )
                        .accessibilityIdentifier(preset.identifier)
                    }
                }
                .padding(.vertical, PVSpacing.s4)
            }
        } header: {
            Text("Cutoff")
        } footer: {
            Text("Only photos and videos on or before this date are considered.")
        }
    }

    /// The date picker needs a non-optional date. A `nil` cutoff shows today,
    /// and choosing a date is what actually arms the scan (upstream: without a
    /// date `scanAssets()` returns immediately).
    private var cutoffBinding: Binding<Date> {
        Binding(
            get: { vm.settings.cutoffDate ?? .now },
            set: { vm.setCutoff($0) }
        )
    }

    private struct CutoffPreset: Identifiable {
        let identifier: String
        let title: LocalizedStringKey
        let days: Int

        var id: String { identifier }
        var date: Date? { Calendar.current.date(byAdding: .day, value: -days, to: Date()) }
    }

    /// Upstream's `_DatePresetCard`, reduced to its six shortcuts — the exact
    /// date stays editable above.
    private static let presets = [
        CutoffPreset(identifier: "cleanupCutoffPreset_30d", title: "30 days", days: 30),
        CutoffPreset(identifier: "cleanupCutoffPreset_60d", title: "60 days", days: 60),
        CutoffPreset(identifier: "cleanupCutoffPreset_90d", title: "90 days", days: 90),
        CutoffPreset(identifier: "cleanupCutoffPreset_1y", title: "1 year", days: 365),
        CutoffPreset(identifier: "cleanupCutoffPreset_2y", title: "2 years", days: 730),
        CutoffPreset(identifier: "cleanupCutoffPreset_3y", title: "3 years", days: 1095),
    ]

    /// A preset is "selected" when the cutoff lands on the same day it would
    /// set, so the chips stay truthful when the date is edited by hand.
    private func isSelected(_ preset: CutoffPreset) -> Bool {
        guard let cutoff = vm.settings.cutoffDate, let date = preset.date else { return false }
        return Calendar.current.isDate(cutoff, inSameDayAs: date)
    }

    // MARK: - Keep

    private var keepSection: some View {
        Section {
            Toggle("Keep favorites", isOn: Binding(
                get: { vm.settings.keepFavorites },
                set: { vm.setKeepFavorites($0) }
            ))
            .accessibilityIdentifier("cleanupKeepFavoritesToggle")

            Picker("Keep on device", selection: Binding(
                get: { vm.settings.keepMediaType },
                set: { vm.setKeepMediaType($0) }
            )) {
                ForEach(CleanupKeepMediaType.allCases, id: \.self) { type in
                    Text(type.title).tag(type)
                }
            }
            .accessibilityIdentifier("cleanupKeepMediaTypePicker")

            // The picker's semantic is "what stays", the opposite of Upload's
            // "albums to back up" — the label carries the difference.
            NavigationLink {
                AlbumPickerView(
                    title: "Keep albums",
                    albums: vm.albums,
                    selection: Binding(
                        get: { vm.settings.keepAlbumIDs },
                        set: { vm.setKeepAlbums($0) }
                    )
                )
            } label: {
                LabeledContent("Keep albums", value: "\(vm.settings.keepAlbumIDs.count)")
            }
            .accessibilityIdentifier("cleanupKeepAlbumsRow")
        } header: {
            Text("Keep")
        } footer: {
            Text(vm.keepSummary)
        }
    }

    // MARK: - Scan

    private var scanSection: some View {
        Section {
            Button("Scan") {
                Task { await vm.scan() }
            }
            .buttonStyle(PVPrimaryButtonStyle())
            .disabled(!vm.canScan)
            .accessibilityIdentifier("cleanupScanButton")

            if vm.isScanning {
                HStack(spacing: PVSpacing.s8) {
                    ProgressView()
                    Text("Scanning your library…")
                        .font(.pvSubhead)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("cleanupScanProgress")
            }

            if let message = vm.errorMessage {
                InlineErrorBadge(message: message, retry: { Task { await vm.scan() } })
            }
        } footer: {
            if vm.settings.cutoffDate == nil {
                Text("Choose a cutoff date to start scanning.")
            } else {
                Text("Photos backed up before Swimmich started recording checksums can't be verified against the server, so they are never offered here.")
            }
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultSection: some View {
        if vm.scannedCount > 0 {
            Section {
                numberRow("Scanned", value: vm.scannedCount, identifier: "cleanupScannedValue")
                numberRow("To delete", value: vm.candidates.count, identifier: "cleanupToDeleteValue")
                byteRow("Reclaimable", bytes: vm.reclaimableBytes, identifier: "cleanupReclaimableValue")
                numberRow("Already gone from the server", value: vm.skippedNotOnServer, identifier: "cleanupNotOnServerValue")
                numberRow("Kept in iCloud Shared Albums", value: vm.skippedInSharedAlbum, identifier: "cleanupSharedAlbumValue")

                if vm.hasNothingToFreeUp {
                    ContentUnavailableView {
                        Label("Nothing to free up", systemImage: "checkmark.circle")
                    } description: {
                        Text("No backed-up original before the cutoff matches the filters you kept.")
                    }
                } else {
                    NavigationLink {
                        CleanupReviewView(vm: vm)
                    } label: {
                        Label("Review \(vm.candidates.count) items", systemImage: "photo.stack")
                    }
                    .accessibilityIdentifier("cleanupReviewRow")
                }
            } header: {
                Text("Review")
            } footer: {
                Text("Removed items go to the system Recently Deleted album, which only you can empty — that is what reclaims the space. They stay available in Immich. Items in an iCloud Shared Album are never offered, because iOS cannot remove them from the album.")
            }
        }
    }

    private func numberRow(_ title: LocalizedStringKey, value: Int, identifier: String) -> some View {
        LabeledContent {
            Text("\(value)")
                .font(.pvNumeric)
                .contentTransition(.numericText())
        } label: {
            Text(title)
        }
        .accessibilityIdentifier(identifier)
    }

    private func byteRow(_ title: LocalizedStringKey, bytes: Int64, identifier: String) -> some View {
        LabeledContent {
            Text(StorageStatsViewModel.format(bytes))
                .font(.pvNumeric)
                .contentTransition(.numericText())
        } label: {
            Text(title)
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Date shortcut pill. Private to this screen: it is the only place that offers
/// relative cutoffs, and its "selected" state is a date comparison rather than
/// a stored flag.
private struct CutoffPresetChip: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.pvSubhead)
                .foregroundStyle(isSelected ? Color.white : Color.textPrimaryPV)
                .padding(.horizontal, PVSpacing.s16)
                .frame(minHeight: 44)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.immichPrimary : Color.bgSecondary)
                )
        }
        .buttonStyle(.plain)
        .animation(PVMotion.snappy, value: isSelected)
    }
}
