import Foundation

/// Something that owns `URLSession`s to the Immich server and can replace them.
///
/// A client certificate change must reach the very next TLS handshake, and a
/// resumed handshake raises no challenge: `renewSessions()` builds new sessions
/// (new delegates, same configurations), puts them in place, then calls
/// `invalidateAndCancel()` on the old ones. Tasks still running on an old
/// session are cancelled. Every consumer therefore reads the current session
/// when it creates a task — creating one on an invalidated session crashes.
protocol SessionRenewing: AnyObject, Sendable {
    func renewSessions()
}
