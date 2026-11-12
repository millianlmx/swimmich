import SwiftUI

/// The view models behind the Library section's screens. `AuthenticatedRoot`
/// owns them; each one serves exactly one screen, as it did in the Me sheet
/// (`stacks` is shared with the Photos tab, as before).
struct LibraryDestinations {
    let recentTaken: RecentAssetsViewModel
    let recentAdded: RecentAssetsViewModel
    let trash: TrashViewModel
    let people: PeopleViewModel
    let tags: TagsViewModel
    let stacks: StacksViewModel
    let partners: PartnersViewModel
    let offline: OfflineDownloadViewModel
    let folders: FolderViewModel
    let localLibrary: LocalLibraryViewModel
    let duplicates: DuplicatesViewModel
    let lockedFolder: LockedFolderViewModel
}

/// "Library" (L-12): the 12 content collections, one touch from the Albums tab.
/// Stateless — each tile pushes a screen onto the tab's `NavigationStack`, which
/// is why none of those screens declares a stack of its own.
struct LibraryCollectionsSection: View {
    let destinations: LibraryDestinations

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s12) {
            Text("Library")
                .font(.pvHeadline)
                .foregroundStyle(Color.textPrimaryPV)
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: columns, spacing: PVSpacing.s12) {
                ForEach(LibraryCollection.allCases, id: \.rowIdentifier) { collection in
                    NavigationLink {
                        destination(for: collection)
                    } label: {
                        Label(collection.title, systemImage: collection.systemImage)
                            .font(.pvSubhead)
                            .foregroundStyle(Color.textPrimaryPV)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, PVSpacing.s12)
                            .padding(.vertical, PVSpacing.s8)
                            .background(
                                Color.bgSecondary,
                                in: RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(collection.rowIdentifier)
                }
            }
        }
        .padding(.horizontal, PVSpacing.s16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("albumsLibrarySection")
    }

    @ViewBuilder
    private func destination(for collection: LibraryCollection) -> some View {
        switch collection {
        case .recentTaken: RecentAssetsView(vm: destinations.recentTaken)
        case .recentAdded: RecentAssetsView(vm: destinations.recentAdded)
        case .people: PeopleView(vm: destinations.people)
        case .tags: TagsView(vm: destinations.tags)
        case .folders: FolderView(vm: destinations.folders, node: nil)
        case .stacks: StackView(vm: destinations.stacks)
        case .partners: PartnersView(vm: destinations.partners)
        case .localLibrary: LocalLibraryView(vm: destinations.localLibrary)
        case .offlineStorage: OfflineAssetsView(vm: destinations.offline)
        case .duplicates: DuplicatesView(vm: destinations.duplicates)
        case .trash: TrashView(vm: destinations.trash)
        case .lockedFolder: LockedFolderView(vm: destinations.lockedFolder)
        }
    }
}
