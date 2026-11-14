import Foundation

/// Tells the app when the device changed network (another Wi-Fi, Wi-Fi to
/// cellular, a VPN going up or down, connectivity lost or back). The first state
/// seen after `start` is the reference and is not a change.
protocol NetworkPathMonitoring: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable () -> Void)
    func stop()
}
