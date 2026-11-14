import Photos
import SwiftUI
import UIKit

/// "On this device" — the local library inventory, pushed from the Albums tab's
/// Library section (L-12) (it reads the *device*, not the server).
///
/// No `NavigationStack` of its own on purpose: the Albums tab already carries the
/// one this screen is pushed into, and a second stack would draw two navigation
/// bars (the `LanguageSettingsView` trap). Same contract as `OfflineAssetsView`.
struct LocalLibraryView: View {
    @PVReduceMotion private var reduceMotion
    @Bindable var vm: LocalLibraryViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s16) {
                summaryCard
                albumsSection
                gridSection
            }
            .padding(PVSpacing.s16)
        }
        .background(Color.bgPrimary)
        .navigationTitle("On this device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ImmichAppBar(title: "On this device") }
        }
        .immichAppBarTitleHeader("On this device")
        .safeAreaInset(edge: .bottom) { selectionBar }
        .task { await reload() }
        .refreshable { await reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localLibraryScreen")
    }

    /// Re-reads the device and the server. The album the user is scoped to is
    /// kept — a refresh must not silently move the grid back to the whole
    /// library — while the selection and the verdict are dropped by
    /// `loadAssets` (a verdict describes the assets it was asked about).
    private func reload() async {
        vm.loadAlbums()
        await vm.loadAssets(albumID: vm.selectedAlbumID)
        await vm.loadRemoteSummary()
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(spacing: PVSpacing.s8) {
            PVAdaptiveStack(hAlignment: .top, spacing: PVSpacing.s8) {
                SummaryColumn(
                    title: "This device",
                    symbol: "iphone",
                    summary: vm.localSummary,
                    identifier: "localLibrarySummary"
                )
                ServerStorageColumn(storage: vm.storage) {
                    Task { await vm.loadRemoteSummary() }
                }
            }
            if let error = vm.errorMessage {
                // Non-blocking, and only the check's or the upload's: the server
                // column carries its own unavailable state.
                InlineErrorBadge(message: error)
            }
        }
        .padding(PVSpacing.s16)
        .background(Color.bgSecondary, in: RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
    }

    // MARK: - Albums

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s4) {
            Text("Albums")
                .font(.pvHeadline)
                .accessibilityIdentifier("localAlbumRow")

            AlbumRow(
                title: Text("All photos"),
                symbol: "photo.on.rectangle.angled",
                count: vm.localSummary.total,
                isSelected: vm.selectedAlbumID == nil
            ) {
                Task { await vm.loadAssets(albumID: nil) }
            }

            ForEach(vm.albums) { album in
                AlbumRow(
                    // `verbatim`: an album name is the user's, not a key — an
                    // album of theirs called "Photos" must not be translated.
                    title: Text(verbatim: album.name),
                    symbol: album.isSmart ? "sparkles" : "rectangle.stack",
                    count: album.count,
                    isSelected: vm.selectedAlbumID == album.id
                ) {
                    // Re-tapping the album already shown falls back to the whole
                    // library, the same toggle the cells use.
                    Task { await vm.loadAssets(albumID: vm.selectedAlbumID == album.id ? nil : album.id) }
                }
                .accessibilityIdentifier("localAlbumRow-\(album.name)")
            }
        }
    }

    // MARK: - Grid

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            Text(vm.selectedAlbumName ?? String(localized: "On this device"))
                .font(.pvHeadline)
                .accessibilityIdentifier("localAssetGrid")

            // Four states, never confused: no access, still enumerating, nothing
            // on the device, and the library itself.
            if !vm.canReadLibrary {
                accessRequiredState
            } else if vm.phase == .enumerating || !vm.didLoad {
                PVSkeletonGrid(rows: 3, columnCount: 3)
            } else if vm.isEmpty {
                ContentUnavailableView {
                    Label("Nothing here yet", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Photos on this device will show up here.")
                }
            } else {
                LocalAssetGrid(
                    assets: vm.assets,
                    selectedIDs: vm.selectedIDs,
                    localOnlyIDs: vm.localOnlyIDs,
                    verdictAvailable: vm.hasVerdict,
                    onToggle: { vm.toggle($0) },
                    loadThumbnail: { asset in await vm.loadThumbnail(for: asset) }
                )
            }
        }
    }

    /// Photos access is the one state that must never render as an empty grid:
    /// "no permission" and "no photos" are otherwise the same picture.
    private var accessRequiredState: some View {
        ContentUnavailableView {
            Label("Photo library access is off", systemImage: "lock")
        } description: {
            Text("Swimmich needs access to this device's photos to list them.")
        } actions: {
            if vm.authorization == .notDetermined {
                Button("Allow access") { Task { await vm.requestAccess() } }
                    .buttonStyle(PVPrimaryButtonStyle())
            } else {
                // iOS will not ask twice — Settings is the only way forward.
                Button("Open Settings") { openPhotoSettings() }
                    .buttonStyle(PVPrimaryButtonStyle())
            }
        }
    }

    private func openPhotoSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    // MARK: - Selection bar

    /// Absent while nothing is selected: a bar reading "0 selected" is chrome for
    /// a state the user is not in.
    @ViewBuilder
    private var selectionBar: some View {
        if vm.hasSelection {
            VStack(spacing: PVSpacing.s8) {
                PVAdaptiveStack(spacing: PVSpacing.s12) {
                    Text("\(vm.selectionCount) selected")
                        .font(.pvHeadline)
                    if vm.hasVerdict {
                        Text("\(vm.localOnlyCount) not on server")
                            .font(.pvCaption)
                            .foregroundStyle(Color.immichWarning)
                            .accessibilityIdentifier("localOnlyValue")
                        if vm.pendingEditCount > 0 {
                            Text("\(vm.pendingEditCount) edits not backed up")
                                .font(.pvCaption)
                                .foregroundStyle(Color.immichWarning)
                                .accessibilityIdentifier("localEditPendingValue")
                        }
                        Text("\(vm.savedCount) on server")
                            .font(.pvCaption)
                            .foregroundStyle(Color.immichSuccess)
                            .accessibilityIdentifier("savedValue")
                    }
                    Spacer(minLength: 0)
                }

                if let progress = vm.uploadProgress {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .tint(Color.immichPrimary)
                    Text("\(progress.done) of \(progress.total)")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }

                PVAdaptiveStack(spacing: PVSpacing.s8) {
                    Button("Cancel") { vm.clearSelection() }
                        .buttonStyle(PVSubtleButtonStyle())

                    // The busy state rides on the button that started the work,
                    // never on an alert, and the label stays readable while the
                    // request runs.
                    Button {
                        Task { await vm.checkSelection() }
                    } label: {
                        HStack(spacing: PVSpacing.s4) {
                            if vm.phase == .checking { ProgressView().tint(Color.textPrimaryPV) }
                            Text("Check")
                        }
                    }
                    .buttonStyle(PVSubtleButtonStyle())
                    .disabled(vm.phase != .idle)
                    .accessibilityIdentifier("checkSelectionButton")

                    Button {
                        Task { await vm.uploadSelection() }
                    } label: {
                        HStack(spacing: PVSpacing.s4) {
                            if vm.phase == .uploading { ProgressView().tint(.white) }
                            Text("Upload")
                        }
                    }
                    .buttonStyle(PVPrimaryButtonStyle())
                    .disabled(!vm.canUpload || vm.phase != .idle)
                    .accessibilityIdentifier("uploadSelectionButton")
                }
            }
            .padding(PVSpacing.s12)
            .frame(maxWidth: .infinity)
            .background(Color.bgSecondary)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.separatorPV).frame(height: 1)
            }
            .transition(.opacity)
            .animation(PVMotion.movement(PVMotion.standard, reduceMotion: reduceMotion), value: vm.hasSelection)
        }
    }
}

/// The device column of the summary: what the photo library holds. It carries no
/// byte count — measuring one means reading every resource of every asset.
private struct SummaryColumn: View {
    @PVReduceMotion private var reduceMotion
    let title: LocalizedStringKey
    let symbol: String
    let summary: LocalLibraryViewModel.MediaSummary
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s4) {
            Label(title, systemImage: symbol)
                .font(.pvHeadline)
                .foregroundStyle(Color.textSecondaryPV)
            Text("\(summary.total)")
                .font(.pvNumeric)
                .contentTransition(PVMotion.contentChange(.numericText(), reduceMotion: reduceMotion))
                .accessibilityIdentifier(identifier)
            Text("\(summary.photos) photos · \(summary.videos) videos")
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The server column of the summary: the *account's* storage. Each half of
/// `StorageStatsViewModel` shows its value, "Unavailable" with Try Again, or
/// nothing yet — never a zero it did not read. `retry` re-reads those two
/// reads only, never a check or an upload.
private struct ServerStorageColumn: View {
    @PVReduceMotion private var reduceMotion
    let storage: StorageStatsViewModel
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s4) {
            Label("Your server", systemImage: "externaldrive.badge.icloud")
                .font(.pvHeadline)
                .foregroundStyle(Color.textSecondaryPV)
            Text(total)
                .font(.pvNumeric)
                .contentTransition(PVMotion.contentChange(.numericText(), reduceMotion: reduceMotion))
                .accessibilityIdentifier("localLibraryRemoteSummary")
            if case .loaded(let counts) = storage.counts {
                Text("\(counts.photos) photos · \(counts.videos) videos")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
                    .accessibilityIdentifier("localLibraryServerCounts")
            }
            if case .unavailable(let message) = storage.counts {
                InlineErrorBadge(message: message, retry: retry)
                    .accessibilityIdentifier("localLibraryServerCountsError")
            }
            usageRows
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .labeledContentStyle(.pvAdaptive)
    }

    private var total: String {
        switch storage.counts {
        case .loaded(let counts): "\(counts.total)"
        case .unavailable: String(localized: "Unavailable")
        case .notLoaded: "—"
        }
    }

    @ViewBuilder
    private var usageRows: some View {
        switch storage.usage {
        case .loaded(let usage):
            LabeledContent("Usage", value: StorageStatsViewModel.format(usage.usedBytes))
                .font(.pvCaption)
                .accessibilityIdentifier("localLibraryServerUsage")
            LabeledContent(
                "Quota",
                value: usage.quotaBytes.map(StorageStatsViewModel.format) ?? String(localized: "Unlimited")
            )
            .font(.pvCaption)
            .accessibilityIdentifier("localLibraryServerQuota")
        case .unavailable(let message):
            LabeledContent("Usage", value: String(localized: "Unavailable"))
                .font(.pvCaption)
                .accessibilityIdentifier("localLibraryServerUsage")
            LabeledContent("Quota", value: String(localized: "Unavailable"))
                .font(.pvCaption)
                .accessibilityIdentifier("localLibraryServerQuota")
            InlineErrorBadge(message: message, retry: retry)
                .accessibilityIdentifier("localLibraryServerUsageError")
        case .notLoaded:
            EmptyView()
        }
    }
}

/// One album line: symbol, name, asset count, and a filled background while it
/// is the grid's scope.
private struct AlbumRow: View {
    let title: Text
    let symbol: String
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: PVSpacing.s8) {
                Image(systemName: symbol)
                    .foregroundStyle(isSelected ? Color.immichPrimary : Color.textSecondaryPV)
                title
                    .font(.pvSubhead)
                    .foregroundStyle(Color.textPrimaryPV)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
            }
            .padding(.vertical, PVSpacing.s8)
            .padding(.horizontal, PVSpacing.s12)
            .background(
                RoundedRectangle(cornerRadius: PVRadius.sm, style: .continuous)
                    .fill(isSelected ? Color.immichPrimary.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
