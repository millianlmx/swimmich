import Foundation

/// File-backed `BackupEditLedgerStoring`: the edited versions already sent to
/// the server, in `Application Support/immich-backup-edits.json` (version 1),
/// separate from the original-asset ledger so that file keeps its format.
/// Same shape as `BackupLedger`: the map lives in memory behind a lock, loaded
/// lazily, and `save()` coalesces writes onto a serial utility queue.
///
/// Production uses `persistent()`; `inMemory()` (no file I/O) is the engine's
/// default so unit tests stay isolated. The composition root never injects
/// `inMemory()`: a memory emptied at every launch would re-export (and
/// re-download from iCloud) every edited rendering on every run.
final class BackupEditLedger: BackupEditLedgerStoring, @unchecked Sendable {
    private struct Snapshot: Codable {
        var version: Int
        var entries: [String: BackupEditRecord]
    }

    private static let currentVersion = 1

    /// nil = pure in-memory ledger (no disk I/O).
    private let fileURL: URL?
    private let lock = NSLock()
    private var entries: [String: BackupEditRecord] = [:]
    private var loaded = false
    private var dirty = false

    private static let ioQueue = DispatchQueue(label: "app.immich.backup.edits.io", qos: .utility)

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    static func persistent() -> BackupEditLedger {
        BackupEditLedger(fileURL: defaultURL())
    }

    static func inMemory() -> BackupEditLedger {
        BackupEditLedger(fileURL: nil)
    }

    private static func defaultURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("immich-backup-edits.json")
    }

    /// Lazily loads the file on first access. Caller MUST hold `lock`. A missing,
    /// unreadable or differently shaped file is an empty memory: the file is left
    /// alone and rewritten by the next `save()` that follows a change.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == Self.currentVersion else { return }
        entries = snapshot.entries
    }

    func record(id: String) -> BackupEditRecord? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return entries[id]
    }

    func upsert(id: String, _ record: BackupEditRecord) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        guard entries[id] != record else { return }
        entries[id] = record
        dirty = true
    }

    func markStacked(id: String) {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        guard var existing = entries[id], !existing.isStacked else { return }
        existing.isStacked = true
        entries[id] = existing
        dirty = true
    }

    func pendingStackIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return entries.filter { !$0.value.isStacked }.map(\.key).sorted()
    }

    func allRecords() -> [String: BackupEditRecord] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return entries
    }

    func entriesForReconciliation() -> [(id: String, checksum: String)] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return entries.map { (id: $0.key, checksum: $0.value.checksum) }
    }

    func forget(ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        for id in ids where entries.removeValue(forKey: id) != nil { dirty = true }
    }

    func save() {
        lock.lock()
        guard dirty, let fileURL else { lock.unlock(); return }
        dirty = false
        let snapshot = Snapshot(version: Self.currentVersion, entries: entries)
        lock.unlock()
        Self.ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func removeAll() {
        lock.lock()
        loaded = true
        entries = [:]
        dirty = false
        let fileURL = self.fileURL
        lock.unlock()
        guard let fileURL else { return }
        Self.ioQueue.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Blocks until the writes queued so far have landed — tests only.
    static func drainIO() {
        ioQueue.sync {}
    }
}
