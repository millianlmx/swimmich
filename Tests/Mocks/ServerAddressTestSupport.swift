import Foundation
@testable import ImmichSwiftUI

/// `ServerAddressSettingsStoring` in memory.
final class InMemoryServerAddressSettingsStore: ServerAddressSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String: ServerAddressSettings]

    init(_ all: [String: ServerAddressSettings] = [:]) { self.all = all }

    func settings(for accountID: String) -> ServerAddressSettings {
        lock.lock(); defer { lock.unlock() }
        return all[accountID] ?? .empty
    }

    func save(_ settings: ServerAddressSettings, for accountID: String) {
        lock.lock(); defer { lock.unlock() }
        if settings == .empty { all[accountID] = nil } else { all[accountID] = settings }
    }

    func remove(for accountID: String) {
        lock.lock(); defer { lock.unlock() }
        all[accountID] = nil
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        all = [:]
    }
}

/// A probe that answers from a script, per address: each call takes the next
/// step of its address (the last one repeats). `delay` makes a step late.
final class ScriptedServerAddressProbe: ServerAddressProbing, @unchecked Sendable {
    struct Step {
        var result: ServerAddressProbeResult
        var delay: Duration = .zero
    }

    struct Call: Equatable {
        let url: URL
        let headers: [CustomHTTPHeader]
    }

    private let lock = NSLock()
    private var scripts: [String: [Step]] = [:]
    private var used: [String: Int] = [:]
    private var _calls: [Call] = []
    /// Called when a probe starts, before it answers.
    var onProbe: (@Sendable (URL) -> Void)?

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    func script(_ url: URL, _ steps: Step...) {
        lock.lock(); defer { lock.unlock() }
        scripts[Self.key(url)] = steps
        used[Self.key(url)] = 0
    }

    func answer(_ url: URL, _ result: ServerAddressProbeResult) { script(url, Step(result: result)) }

    func callCount(for url: URL) -> Int { calls.filter { Self.key($0.url) == Self.key(url) }.count }

    func probe(_ base: URL, headers: [CustomHTTPHeader], deadline: Duration) async -> ServerAddressProbeResult {
        let step: Step = {
            lock.lock(); defer { lock.unlock() }
            _calls.append(Call(url: base, headers: headers))
            let key = Self.key(base)
            let steps = scripts[key] ?? [Step(result: .unreachable)]
            let index = min(used[key] ?? 0, steps.count - 1)
            used[key] = (used[key] ?? 0) + 1
            return steps[index]
        }()
        onProbe?(base)
        if step.delay > .zero { try? await Task.sleep(for: step.delay) }
        return step.result
    }

    private static func key(_ url: URL) -> String { url.absoluteString }
}

/// A network monitor a test drives by hand.
final class FakeNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private(set) var startCount = 0

    func start(onChange: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        handler = onChange
        startCount += 1
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
    }

    func fireChange() {
        lock.lock(); let current = handler; lock.unlock()
        current?()
    }
}
