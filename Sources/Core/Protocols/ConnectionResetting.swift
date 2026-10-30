import Foundation

/// Something that owns network connections and can drop them all, so the next
/// request opens a fresh socket (and faces a fresh TLS challenge).
protocol ConnectionResetting: AnyObject, Sendable {
    func resetConnections() async
}
