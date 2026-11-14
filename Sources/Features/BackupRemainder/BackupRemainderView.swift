import SwiftUI
import UIKit

/// The photos and videos a complete backup pass would still send: thumbnail,
/// name, date and user albums. The list empties as the run sends them. Rows
/// are read-only — they open nothing.
///
/// Pushed from `BackupSettingsView`, itself pushed from `ProfileView`, which
/// already carries the `NavigationStack` — hence none here.
struct BackupRemainderView: View {
    @PVReduceMotion private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Bindable var vm: BackupRemainderViewModel

    var body: some View {
        List {
            switch vm.state {
            case let .noAccess(canAsk):
                singleRow { accessRequiredState(canAsk: canAsk) }
            case .loading:
                singleRow {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .pvLoadingIndicator("backupRemainderLoading")
                }
            case .allBackedUp:
                singleRow {
                    ContentUnavailableView {
                        Label("Everything is backed up", systemImage: "checkmark.icloud")
                    } description: {
                        Text("Every photo and video in your backup selection is on the server.")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("backupRemainderEmptyState")
                }
            case .emptyScope:
                singleRow {
                    ContentUnavailableView {
                        Label("Nothing to back up", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Your backup selection holds no photo or video.")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("backupRemainderEmptyScopeState")
                }
            case .list:
                ForEach(vm.items) { item in
                    BackupRemainderRow(item: item, vm: vm)
                        .listRowBackground(Color.bgSecondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .animation(
            PVMotion.movement(PVMotion.standard, reduceMotion: reduceMotion),
            value: vm.items.count
        )
        .refreshable { await vm.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backupRemainderScreen")
        .background(Color.bgPrimary)
        .task { await vm.load() }
        .navigationTitle("Remaining to back up")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ImmichAppBar(title: "Remaining to back up")
            }
            if vm.showsReloadIndicator {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView()
                        .controlSize(.small)
                        .pvLoadingIndicator("backupRemainderReloading")
                }
            }
        }
        .immichAppBarTitleHeader("Remaining to back up")
    }

    /// The `List` stays the same container in every state, so `.refreshable`
    /// never changes owner: states other than the rows are one clear row.
    private func singleRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    /// "No permission" must never render as an empty list.
    private func accessRequiredState(canAsk: Bool) -> some View {
        ContentUnavailableView {
            Label("Photo library access is off", systemImage: "lock")
        } description: {
            Text("Swimmich needs access to this device's photos to list them.")
        } actions: {
            if canAsk {
                Button("Allow access") { Task { await vm.requestAccess() } }
                    .buttonStyle(PVPrimaryButtonStyle())
                    .accessibilityIdentifier("backupRemainderAllowAccessButton")
            } else {
                // iOS will not ask twice — Settings is the only way forward.
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(PVPrimaryButtonStyle())
                .accessibilityIdentifier("backupRemainderOpenSettingsButton")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("backupRemainderAccessState")
    }
}

/// One row: a 64 pt thumbnail asked from Photos for this visible row only,
/// then name, date, albums and the "video" / "edit" marks. One VoiceOver
/// element, no button trait: the row opens nothing.
private struct BackupRemainderRow: View {
    let item: BackupRemainderItem
    let vm: BackupRemainderViewModel

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        PVAdaptiveStack(hAlignment: .top, spacing: PVSpacing.s12) {
            thumbnail
            VStack(alignment: .leading, spacing: PVSpacing.s4) {
                Text(item.fileName)
                    .font(.pvBody)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = item.createdAt {
                    Text(BackupRemainderViewModel.dateText(date))
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                if let albums = BackupRemainderViewModel.albumsText(item.albumNames) {
                    Text(albums)
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.kind == .video {
                    Label("Video", systemImage: "video.fill")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                if item.isEditOnly {
                    Label("Edited version", systemImage: "wand.and.stars")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BackupRemainderViewModel.accessibilityLabel(for: item))
        .accessibilityIdentifier("remainderAsset_\(item.id)")
    }

    private var thumbnail: some View {
        ZStack {
            Color.bgPrimary
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: item.kind == .video ? "video" : "photo")
                    .foregroundStyle(Color.textSecondaryPV)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.sm, style: .continuous))
        .task(id: item.id) {
            image = await vm.thumbnail(for: item.id, side: 64, scale: displayScale)
        }
    }
}
