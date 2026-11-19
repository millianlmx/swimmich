import Foundation

/// UserDefaults-backed `TrustedServerStore` — hosts stored as a string set, the
/// certificate pinned for each one as a `host → fingerprint` dictionary.
///
/// A host trusted by an earlier build has no pin: its next handshake pins the
/// certificate it presents, exactly as a host the user has just trusted.
final class TrustedServerStoreImpl: TrustedServerStore, @unchecked Sendable {
    static let defaultsKey = "trustedServers"
    static let pinsDefaultsKey = "trustedServerPins"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var pinLearned: (@Sendable () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Called (on the thread of the handshake) each time a pin is recorded: the
    /// app republishes the widget session, which carries the pins.
    var onPinLearned: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return pinLearned }
        set { lock.lock(); defer { lock.unlock() }; pinLearned = newValue }
    }

    func contains(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.load(from: defaults).contains(host)
    }

    func add(_ host: String) {
        lock.lock()
        defer { lock.unlock() }
        var hosts = Self.load(from: defaults)
        hosts.insert(host)
        defaults.set(Array(hosts), forKey: Self.defaultsKey)
        var pins = Self.loadPins(from: defaults)
        if pins.removeValue(forKey: host) != nil {
            defaults.set(pins, forKey: Self.pinsDefaultsKey)
        }
    }

    func pin(for host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard Self.load(from: defaults).contains(host) else { return nil }
        return Self.loadPins(from: defaults)[host]
    }

    @discardableResult
    func pinIfAbsent(_ fingerprint: String, for host: String) -> String? {
        lock.lock()
        guard Self.load(from: defaults).contains(host) else {
            lock.unlock()
            return nil
        }
        var pins = Self.loadPins(from: defaults)
        if let existing = pins[host] {
            lock.unlock()
            return existing
        }
        pins[host] = fingerprint
        defaults.set(pins, forKey: Self.pinsDefaultsKey)
        let learned = pinLearned
        lock.unlock()
        learned?()
        return fingerprint
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.pinsDefaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    private static func loadPins(from defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: pinsDefaultsKey) as? [String: String] ?? [:]
    }
}
