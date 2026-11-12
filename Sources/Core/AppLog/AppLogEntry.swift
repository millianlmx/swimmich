import Foundation

/// Severity of one line of the transport log (gap G24).
///
/// Three levels — the scale the Flutter client's log page tints its rows with
/// (info → brand, warning → orange, severe → red), so the iOS screen reads at a
/// glance exactly like the one it replaces.
enum AppLogLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case info
    case warning
    case severe

    var id: String { rawValue }
}

/// One line of the transport log.
///
/// Deliberately narrow. The buffer keeps the request's **path alone**: never
/// what follows the `?`, never any request metadata, never a body. That is not a
/// size decision but a privacy one — a shared link's visitor credential travels
/// in the URL's parameters, and a signed-in session's proof travels in the
/// request's metadata, so a wider record would let a diagnostic screen display a
/// usable credential. Every field below is safe to read out loud and safe to
/// export — the narrowness handles the structure; `message`, `details` and `stack`
/// may still quote an error's text (a URL, a token), which is why the buffer
/// that keeps the lines masks them (`AppLogRedactor`).
struct AppLogEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let level: AppLogLevel
    let method: String
    /// Path only (`/api/assets/abc`) — never the URL's parameters.
    let path: String
    /// nil when nothing came back at all (a thrown error).
    let status: Int?
    let durationMS: Int?
    /// Which egress produced the line: `HTTP` (`dispatch`) or `Upload`
    /// (`dispatchUpload`).
    let category: String
    /// The one-line fact the list shows.
    let message: String
    /// The full failure text when there is one — the DETAILS block.
    let details: String?
    /// Call symbols of a thrown error — the STACK TRACE block. Nil on every
    /// nominal line: capturing symbols costs, and only a failure earns it.
    let stack: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: AppLogLevel,
        method: String,
        path: String,
        status: Int? = nil,
        durationMS: Int? = nil,
        category: String,
        message: String,
        details: String? = nil,
        stack: String? = nil
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.method = method
        self.path = path
        self.status = status
        self.durationMS = durationMS
        self.category = category
        self.message = message
        self.details = details
        self.stack = stack
    }
}

/// Where the transport hands its lines.
///
/// `learn…` tell the sink what must never appear in a line (a server's address,
/// a token, a password): the sink that keeps lines (`AppLogStore`) masks them at
/// recording and keeps what it learnt for the life of the process. The default
/// implementations ignore it, for sinks that keep nothing.
protocol AppLogSink: Sendable {
    func record(_ entry: AppLogEntry)
    func learnServer(_ baseURL: URL)
    func learnSecret(_ value: String)
    func learnRequest(_ request: URLRequest, customHeaderNames: [String])
}

extension AppLogSink {
    func learnServer(_ baseURL: URL) {}
    func learnSecret(_ value: String) {}
    func learnRequest(_ request: URLRequest, customHeaderNames: [String]) {}
}

/// The sink that keeps nothing — the transport's default, so it stays usable
/// (and silent) without a log: unit tests, previews, and any future extension
/// that builds a client of its own.
struct NoopAppLogSink: AppLogSink {
    func record(_ entry: AppLogEntry) {}
}
