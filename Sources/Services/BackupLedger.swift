import Foundation

/// File-backed `BackupLedgerStoring`. Holds the entry map in memory behind a
/// lock and persists it as versioned JSON. Writes are coalesced onto a serial
/// background queue via `save()` (the engine flushes once per chunk and at run
/// end), never per marked asset, so a first full-library run doesn't rewrite
/// the whole file thousands of times.
///
/// Use `persistent()` in production and `inMemory()` in tests — an in-memory
/// ledger performs no file I/O, so unit tests neither read stale state nor
/// pollute each other across runs.
final class BackupLedger: BackupLedgerStoring, @unchecked Sendable {
    /// One tracked asset. `checksum` is absent for entries migrated from the v1
    /// file format — the checksum was simply not stored then, and re-deriving it
    /// would mean re-downloading the asset, the exact cost the ledger exists to
    /// avoid. Such an entry stays valid for the skip and gains its checksum at
    /// the next run that marks it. `serverAssetId` is absent for the same
    /// reason (v1 and v2 files never carried it): it is the asset's UUID on the
    /// server, which is what the timeline renders, while the entry is keyed by
    /// the Photos `localIdentifier`.
    private struct Entry: Codable {
        let signature: String
        var checksum: String?
        var serverAssetId: String?
    }

    /// On-disk shape. Versioned so a v1 file (`[String: String]`) can be told
    /// apart from a v3 snapshot without guessing at the shape. v2 files decode
    /// as-is: both fields v3 added are optional.
    private struct Snapshot: Codable {
        var version: Int
        var lastReconciliation: Date?
        var entries: [String: Entry]
    }

    private static let currentVersion = 3

    /// nil = pure in-memory ledger (no disk I/O).
    private let fileURL: URL?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var dirty = false
    private var reconciliationDate: Date?

    private static let ioQueue = DispatchQueue(label: "app.immich.backup.ledger.io", qos: .utility)

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Production ledger, persisted under Application Support.
    static func persistent() -> BackupLedger {
        BackupLedger(fileURL: defaultURL())
    }

    /// Ephemeral ledger — no disk I/O. Default for the engine so tests stay
    /// isolated; production explicitly injects `persistent()`.
    static func inMemory() -> BackupLedger {
        BackupLedger(fileURL: nil)
    }

    private static func defaultURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("immich-backup-ledger.json")
    }

    /// Lazily loads the file on first access. Caller MUST hold `lock`.
    /// Tries the current format, then the v1 map — an unreadable file is
    /// treated as an empty ledger, as before.
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            entries = snapshot.entries
            reconciliationDate = snapshot.lastReconciliation
            return
        }
        if let legacy = try? decoder.decode([String: String].self, from: data) {
            entries = legacy.mapValues { Entry(signature: $0, checksum: nil) }
        }
    }

    func isBackedUp(id: String, signature: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return entries[id]?.signature == signature
    }

    func markBackedUp(id: String, signature: String, checksum: String, serverAssetId: String?) {
        lock.lock()
        ensureLoaded()
        let existing = entries[id]
        // A write that carries no UUID keeps the one already stored: the id
        // belongs to the asset, and the badge would go dark on an asset this
        // device already proved if a `reject` answered without it (the DTO
        // only *requires* `action` and `id`). An id the server no longer has
        // is dropped by reconciliation, which forgets the whole entry.
        let resolved = serverAssetId ?? existing?.serverAssetId
        if existing?.signature != signature || existing?.checksum != checksum
            || existing?.serverAssetId != resolved {
            entries[id] = Entry(signature: signature, checksum: checksum, serverAssetId: resolved)
            dirty = true
        }
        lock.unlock()
    }

    func uploadedServerAssetIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return Set(entries.values.compactMap(\.serverAssetId))
    }

    func uploadedLocalAssetIDs() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return Set(entries.keys)
    }

    func hasUploaded(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return entries[id] != nil
    }

    func trackedEntry(id: String) -> BackupLedgerEntry? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return entries[id].map {
            BackupLedgerEntry(signature: $0.signature, checksum: $0.checksum, serverAssetId: $0.serverAssetId)
        }
    }

    func entriesForReconciliation() -> [(id: String, checksum: String)] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return entries.compactMap { id, entry in
            entry.checksum.map { (id: id, checksum: $0) }
        }
    }

    func forget(ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.lock()
        ensureLoaded()
        for id in ids where entries.removeValue(forKey: id) != nil { dirty = true }
        lock.unlock()
    }

    var lastReconciliation: Date? {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return reconciliationDate
    }

    func recordReconciliation(at date: Date) {
        lock.lock()
        reconciliationDate = date
        dirty = true
        lock.unlock()
    }

    func save() {
        lock.lock()
        guard dirty, let fileURL else { lock.unlock(); return }
        dirty = false
        let snapshot = Snapshot(
            version: Self.currentVersion,
            lastReconciliation: reconciliationDate,
            entries: entries
        )
        lock.unlock()
        Self.ioQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func trackedCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        return entries.count
    }

    func removeAll() {
        lock.lock()
        loaded = true
        entries = [:]
        reconciliationDate = nil
        dirty = false
        let fileURL = self.fileURL
        lock.unlock()
        guard let fileURL else { return }
        Self.ioQueue.async { try? FileManager.default.removeItem(at: fileURL) }
    }
}
