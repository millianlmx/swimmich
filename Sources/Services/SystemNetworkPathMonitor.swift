import Foundation
import Network

/// What counts as "the network changed": the path status, the interfaces it can
/// use and its gateways. A first reading is the reference, never a change.
struct NetworkPathChangeDetector: Sendable {
    private var last: String?

    /// True when `signature` differs from the previous reading. The first
    /// reading only records the reference.
    mutating func changed(to signature: String) -> Bool {
        defer { last = signature }
        guard let last else { return false }
        return last != signature
    }
}

/// `NWPathMonitor` on a utility queue, reporting a change only when the path
/// signature differs from the previous one (L-26).
final class SystemNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var monitor: NWPathMonitor?

    /// Pure and testable: `status`, the sorted `(name, type)` pairs of the usable
    /// interfaces and the gateways, as one comparable string.
    static func signature(
        status: NWPath.Status, interfaces: [(name: String, type: NWInterface.InterfaceType)], gateways: [String]
    ) -> String {
        let names = interfaces.map { "\($0.name):\($0.type)" }.sorted().joined(separator: ",")
        return "\(status)|\(names)|\(gateways.sorted().joined(separator: ","))"
    }

    static func signature(of path: NWPath) -> String {
        signature(
            status: path.status,
            interfaces: path.availableInterfaces.map { ($0.name, $0.type) },
            gateways: path.gateways.map { "\($0)" }
        )
    }

    func start(onChange: @escaping @Sendable () -> Void) {
        stop()
        let monitor = NWPathMonitor()
        var detector = NetworkPathChangeDetector()
        monitor.pathUpdateHandler = { path in
            // The handler runs serially on the monitor's queue: `detector` is not shared.
            if detector.changed(to: Self.signature(of: path)) { onChange() }
        }
        monitor.start(queue: DispatchQueue(label: "app.immich.swiftui.network-path", qos: .utility))
        lock.lock()
        self.monitor = monitor
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let old = monitor
        monitor = nil
        lock.unlock()
        old?.cancel()
    }

    deinit { monitor?.cancel() }
}
