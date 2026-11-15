import Foundation

/// The root screen of a tab, as the reload after an address evaluation sees it (L-26).
@MainActor
protocol ReloadableScreen: AnyObject {
    /// The screen shows a failure of its own read; a failed action does not count.
    var hasLoadError: Bool { get }
    func refresh() async
}
