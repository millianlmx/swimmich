import Foundation

/// The 12 content collections of the Albums tab's Library section (L-12), in
/// display order. They used to be rows of the Me sheet; each one is a pushed
/// screen, so each is one touch from the Albums tab.
///
/// Favorites and Archive are not here (they are filters of the Photos tab), nor
/// Places (the Search tab's Explore mode).
enum LibraryCollection: CaseIterable {
    case recentTaken
    case recentAdded
    case people
    case tags
    case folders
    case stacks
    case partners
    case localLibrary
    case offlineStorage
    case duplicates
    case trash
    case lockedFolder

    /// Literals, not `LocalizedStringResource(variable)`: the catalog extraction
    /// must claim each key, or the audit calls it dead.
    var title: LocalizedStringResource {
        switch self {
        case .recentTaken: "Recently Taken"
        case .recentAdded: "Recently Added"
        case .people: "People"
        case .tags: "Tags"
        case .folders: "Folders"
        case .stacks: "Stacks"
        case .partners: "Partners"
        case .localLibrary: "On this device"
        case .offlineStorage: "Offline Storage"
        case .duplicates: "Duplicates"
        case .trash: "Trash"
        case .lockedFolder: "Locked Folder"
        }
    }

    var systemImage: String {
        switch self {
        case .recentTaken: "clock.arrow.circlepath"
        case .recentAdded: "arrow.up.circle"
        case .people: "person.2"
        case .tags: "tag"
        case .folders: "folder"
        case .stacks: "square.stack.3d.down.right"
        case .partners: "person.badge.plus"
        case .localLibrary: "iphone"
        case .offlineStorage: "arrow.down.circle"
        case .duplicates: "rectangle.on.rectangle.angled"
        case .trash: "trash"
        case .lockedFolder: "lock"
        }
    }

    /// The identifier each entry carried as a row of the Me sheet, kept so the
    /// scenarios that open a collection keep their handle.
    var rowIdentifier: String {
        switch self {
        case .recentTaken: "recentTakenRow"
        case .recentAdded: "recentAddedRow"
        case .people: "peopleRow"
        case .tags: "tagsRow"
        case .folders: "foldersRow"
        case .stacks: "stacksRow"
        case .partners: "partnersRow"
        case .localLibrary: "localLibraryRow"
        case .offlineStorage: "offlineStorageRow"
        case .duplicates: "duplicatesRow"
        case .trash: "trashRow"
        case .lockedFolder: "lockedFolderRow"
        }
    }
}
