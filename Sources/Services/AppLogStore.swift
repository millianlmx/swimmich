import Foundation

/// Bounded, synchronous, in-memory log of the transport's egress (gap G24).
///
/// `os.Logger` was the obvious alternative and is rejected for three measurable
/// reasons: it carries no application-level severity of its own, it records
/// neither the request's path nor its status nor its duration, and it offers no
/// "Clear" action — a screen built on it could show nothing an operator wants and
/// could not empty what it did show.
///
/// Synchronous and lock-guarded like `BackupLedger`, the house pattern for a
/// store several threads touch: `dispatch` records on its way out of a
/// `URLSession` call, so `record` cannot `await`. `@unchecked Sendable` because
/// the lock — not the compiler — is what makes it safe.
///
/// **Local only.** Nothing is written to disk, nothing is synchronised, and
/// nothing leaves the device on its own: the buffer dies with the process, and
/// the export is a user action (`ShareLink` in `AppLogView`), never a background
/// one.
///
/// **Masked at the door.** `record` passes every line through an
/// `AppLogRedactor` before it is stored, so the buffer never holds a server's
/// address nor a secret: the screen, the detail blocks, the clipboard and the
/// export all read `snapshot()` and cannot leak what is not there. The
/// redactor's vocabulary (`learn…`) only grows, for the life of the process —
/// `clear()` empties the lines, not what the store has learnt. When it grows,
/// the lines already kept are masked again; a generation counter closes the
/// window between masking a line and storing it.
final class AppLogStore: AppLogSink, @unchecked Sendable {
    private let lock = NSLock()
    /// Oldest first; `snapshot()` reverses for the screen.
    private var entries: [AppLogEntry] = []
    private let capacity: Int
    private var redactor = AppLogRedactor()
    /// Bumped, under the lock, each time the vocabulary grows.
    private var generation = 0
    /// Lines below this severity are dropped at recording; lines already kept
    /// stay. Persisted by the store itself (`minimumLevelKey`).
    private var minimumLevel: AppLogLevel
    private let defaults: UserDefaults

    static let minimumLevelKey = "logLevel"

    /// 500 lines — the bound the Flutter client's logger keeps, chosen there to
    /// hold a session's traffic without holding a session's memory.
    init(capacity: Int = 500, defaults: UserDefaults = .standard) {
        self.capacity = capacity
        self.defaults = defaults
        minimumLevel = defaults.string(forKey: Self.minimumLevelKey)
            .flatMap(AppLogLevel.init(rawValue:)) ?? .info
    }

    func currentMinimumLevel() -> AppLogLevel {
        lock.lock(); defer { lock.unlock() }
        return minimumLevel
    }

    /// The Advanced screen's log level: only lines at this level or more
    /// severe are recorded from now on.
    func setMinimumLevel(_ level: AppLogLevel) {
        lock.lock(); defer { lock.unlock() }
        minimumLevel = level
        defaults.set(level.rawValue, forKey: Self.minimumLevelKey)
    }

    func record(_ entry: AppLogEntry) {
        lock.lock()
        // Dropped before any masking: a line below the threshold costs one
        // comparison, on every request's way out.
        if entry.level < minimumLevel {
            lock.unlock()
            return
        }
        let snapshotRedactor = redactor
        let seen = generation
        lock.unlock()

        // The regexes run outside the lock: `record` is on every request's way
        // out, and the lock is shared with the screen.
        var masked = snapshotRedactor.redact(entry)

        lock.lock(); defer { lock.unlock() }
        if generation != seen {
            // Something was learnt while this line was being masked: start again
            // from the original with the current vocabulary.
            masked = redactor.redact(entry)
        }
        entries.append(masked)
        // Surplus goes out the bottom: the newest lines are the ones that
        // describe what just failed, and they are what the operator is reading.
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func learnServer(_ baseURL: URL) {
        learn { $0.learnServer(baseURL) }
    }

    func learnSecret(_ value: String) {
        learn { $0.learnSecret(value) }
    }

    func learnRequest(_ request: URLRequest, customHeaderNames: [String]) {
        learn { $0.learnRequest(request, customHeaderNames: customHeaderNames) }
    }

    /// Grows the vocabulary and, when it did, masks the kept lines again — with
    /// what is new only: they were masked with the rest when they came in.
    private func learn(_ grow: (inout AppLogRedactor) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        let before = redactor
        guard grow(&redactor) else { return }
        generation += 1
        let added = redactor.additions(since: before)
        entries = entries.map { added.redact($0) }
    }

    /// A copy, most recent first — the order the screen lists and the export
    /// writes.
    func snapshot() -> [AppLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.reversed())
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Empties the buffer — the screen's "Clear" action, and the only eraser.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }
}
