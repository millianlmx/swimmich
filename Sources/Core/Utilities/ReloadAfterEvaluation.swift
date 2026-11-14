import Foundation

/// What the visible tab does once the address of the server was evaluated again
/// (L-26): it reloads when the address changed, and otherwise only when it shows
/// a load error (so a screen stranded offline recovers by itself).
enum ReloadAfterEvaluation {
    static func shouldReload(changedAddress: Bool, hasLoadError: Bool) -> Bool {
        changedAddress || hasLoadError
    }
}
