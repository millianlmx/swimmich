import Foundation

/// What the visible tab does once the address of the server was evaluated again
/// (L-26): it reloads when the address changed, and otherwise only when it shows
/// a load error (so a screen stranded offline recovers by itself).
enum ReloadAfterEvaluation {
    static func shouldReload(changedAddress: Bool, hasLoadError: Bool) -> Bool {
        changedAddress || hasLoadError
    }
}

/// Picks the root screen of the tab on display and reloads it when
/// `ReloadAfterEvaluation` says so (L-26).
@MainActor
struct VisibleTabReloader {
    let photos: any ReloadableScreen
    let memories: any ReloadableScreen
    let albums: any ReloadableScreen
    let shared: any ReloadableScreen

    /// `.search` has no root screen to reload.
    func screen(for tab: RootTab) -> (any ReloadableScreen)? {
        switch tab {
        case .photos: photos
        case .memories: memories
        case .albums: albums
        case .shared: shared
        case .search: nil
        }
    }

    /// Refreshes the screen of `tab` once when `shouldReload` says so; nothing for `.search`.
    func reload(tab: RootTab, after outcome: EvaluationOutcome) async {
        guard let screen = screen(for: tab),
              ReloadAfterEvaluation.shouldReload(changedAddress: outcome.changedAddress, hasLoadError: screen.hasLoadError)
        else { return }
        await screen.refresh()
    }
}
