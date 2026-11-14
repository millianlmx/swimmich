import CoreLocation
import Foundation
import Observation

/// The device position through CoreLocation, "while using the app" only.
/// The manager is created on first use, so building the container (or a view
/// model in a unit test) touches nothing of CoreLocation.
@MainActor
final class SystemDeviceLocationService: NSObject, DeviceLocationProviding, CLLocationManagerDelegate {
    /// Key of `NSLocationTemporaryUsageDescriptionDictionary` in the Info.plist.
    static let preciseAccuracyPurposeKey = "MyLocation"

    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        return manager
    }()

    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var fixWaiters: [CheckedContinuation<DeviceCoordinate, Error>] = []

    func currentStatus() async -> DeviceLocationStatus {
        // `locationServicesEnabled()` blocks: asked off the main thread.
        let servicesEnabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
        guard servicesEnabled else { return .servicesDisabled }
        switch manager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .restricted, .denied:
            return .denied
        case .authorizedWhenInUse, .authorizedAlways:
            return manager.accuracyAuthorization == .fullAccuracy ? .authorizedFull : .authorizedReduced
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() async -> DeviceLocationStatus {
        let status = await currentStatus()
        guard status == .notDetermined else { return status }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            authorizationWaiters.append(waiter)
            manager.requestWhenInUseAuthorization()
        }
        return await currentStatus()
    }

    func requestPreciseAccuracy() async -> DeviceLocationStatus {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            manager.requestTemporaryFullAccuracyAuthorization(
                withPurposeKey: Self.preciseAccuracyPurposeKey
            ) { _ in waiter.resume() }
        }
        return await currentStatus()
    }

    func currentCoordinate() async throws -> DeviceCoordinate {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<DeviceCoordinate, Error>) in
            fixWaiters.append(waiter)
            manager.requestLocation()
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Also fired when the delegate is set, with the status still undecided:
        // only a decision ends the wait.
        guard manager.authorizationStatus != .notDetermined else { return }
        Task { @MainActor [weak self] in self?.finishAuthorizationWait() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coordinate = DeviceCoordinate(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
        Task { @MainActor [weak self] in self?.finishFixWait(.success(coordinate)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.finishFixWait(.failure(DeviceLocationFailure.unavailable)) }
    }

    private func finishAuthorizationWait() {
        let waiters = authorizationWaiters
        authorizationWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func finishFixWait(_ result: Result<DeviceCoordinate, Error>) {
        let waiters = fixWaiters
        fixWaiters = []
        waiters.forEach { $0.resume(with: result) }
    }
}

/// A scripted position for the UI tests and the unit tests: the permission,
/// the answers to the two prompts and the fix are all set up front. The app only
/// builds one when `-uiTestLocationStatus` is on the launch arguments; the key is
/// never written by the app, so production never reads it.
///
/// Launch arguments:
/// - `-uiTestLocationStatus`: `servicesDisabled`, `notDetermined`, `denied`,
///   `authorizedReduced` or `authorizedFull`.
/// - `-uiTestLocationFix`: `lat,lon` of the position, or `none` for no fix.
/// - `-uiTestLocationPrompt`: what the user answers to the permission prompt,
///   `allow` (default), `allowReduced` or `deny`.
/// - `-uiTestLocationPrecise`: the answer to the temporary precise-position
///   request, `grant` (default) or `refuse`.
@Observable
@MainActor
final class ScriptedDeviceLocationService: DeviceLocationProviding {
    enum PromptAnswer: String {
        case allow, allowReduced, deny
    }

    private(set) var status: DeviceLocationStatus
    /// Prompts raised so far — the proof that opening a screen asks nothing.
    private(set) var authorizationPromptCount = 0
    private(set) var preciseAccuracyRequestCount = 0
    private(set) var fixCount = 0

    @ObservationIgnored private let fix: DeviceCoordinate?
    @ObservationIgnored private let promptAnswer: PromptAnswer
    @ObservationIgnored private let grantsPreciseAccuracy: Bool

    init(
        status: DeviceLocationStatus,
        fix: DeviceCoordinate?,
        promptAnswer: PromptAnswer = .allow,
        grantsPreciseAccuracy: Bool = true
    ) {
        self.status = status
        self.fix = fix
        self.promptAnswer = promptAnswer
        self.grantsPreciseAccuracy = grantsPreciseAccuracy
    }

    static let statusKey = "uiTestLocationStatus"
    static let fixKey = "uiTestLocationFix"
    static let promptKey = "uiTestLocationPrompt"
    static let preciseKey = "uiTestLocationPrecise"

    /// The scripted service the launch arguments ask for, `nil` in production.
    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> ScriptedDeviceLocationService? {
        guard let raw = defaults.string(forKey: statusKey) else { return nil }
        let status: DeviceLocationStatus
        switch raw {
        case "servicesDisabled": status = .servicesDisabled
        case "notDetermined": status = .notDetermined
        case "denied": status = .denied
        case "authorizedReduced": status = .authorizedReduced
        case "authorizedFull": status = .authorizedFull
        default: return nil
        }
        let parts = defaults.string(forKey: fixKey)?.split(separator: ",").compactMap { Double($0) }
        let fix = parts.flatMap { $0.count == 2 ? DeviceCoordinate(latitude: $0[0], longitude: $0[1]) : nil }
        return ScriptedDeviceLocationService(
            status: status,
            fix: fix,
            promptAnswer: defaults.string(forKey: promptKey).flatMap(PromptAnswer.init(rawValue:)) ?? .allow,
            grantsPreciseAccuracy: defaults.string(forKey: preciseKey) != "refuse"
        )
    }

    func currentStatus() async -> DeviceLocationStatus { status }

    func requestAuthorization() async -> DeviceLocationStatus {
        guard status == .notDetermined else { return status }
        authorizationPromptCount += 1
        switch promptAnswer {
        case .allow: status = .authorizedFull
        case .allowReduced: status = .authorizedReduced
        case .deny: status = .denied
        }
        return status
    }

    func requestPreciseAccuracy() async -> DeviceLocationStatus {
        guard status == .authorizedReduced else { return status }
        preciseAccuracyRequestCount += 1
        // Temporary: the permission itself stays reduced, like the system's.
        return grantsPreciseAccuracy ? .authorizedFull : .authorizedReduced
    }

    func currentCoordinate() async throws -> DeviceCoordinate {
        guard let fix else { throw DeviceLocationFailure.unavailable }
        fixCount += 1
        return fix
    }
}
