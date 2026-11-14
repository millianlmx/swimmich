import Foundation

/// What the shared selection bar (`BatchSelectionBar`) drives: the timeline's
/// model, and the search model that forwards to its private timeline engine.
/// `@MainActor` matches both conformers, which are UI-layer `@Observable`
/// view models; the bar reads and calls them from the view.
@MainActor
protocol BatchSelectionModel: AnyObject {
    var selectionMode: Bool { get }
    var selectedIds: Set<String> { get }
    /// The selection in grid order (what a download enqueues).
    var selectedItems: [AssetReactItem] { get }
    var selectionOffersUnarchive: Bool { get }
    var actionErrorMessage: String? { get set }
    var skippedPartnerCount: Int? { get set }
    func exitSelectionMode()
    func ownerScopedSelection(currentUserId: String?) -> (ids: [String], skipped: Int)
    func favoriteSelected(currentUserId: String?) async
    func deleteSelected(currentUserId: String?) async
    func archiveSelected(currentUserId: String?) async
    func unarchiveSelected() async
    func moveSelectedToLockedFolder(currentUserId: String?) async
    func stackSelected(currentUserId: String?) async
}
