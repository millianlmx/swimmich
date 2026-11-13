import Foundation

/// A position of the device, in degrees.
struct DeviceCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// What the app may do with the device position right now.
enum DeviceLocationStatus: Equatable, Sendable {
    /// Location Services are switched off for the whole device.
    case servicesDisabled
    /// The user was never asked.
    case notDetermined
    /// Refused, or restricted by the system (a parental control cannot be lifted by the user).
    case denied
    /// Allowed "while using" with the approximate position only.
    case authorizedReduced
    /// Allowed "while using" with the precise position.
    case authorizedFull

    /// True when the app may read a position (precise or approximate).
    var allowsPosition: Bool { self == .authorizedFull || self == .authorizedReduced }
}

enum DeviceLocationFailure: Error, Equatable {
    /// The system could not produce a position (no signal, timeout, error).
    case unavailable
}

/// The device position, behind a contract so the map, the adjust-location
/// sheet and their tests never touch CoreLocation directly (L-25, B-29.2).
///
/// Nothing here asks the user anything on its own: only
/// `requestAuthorization()` raises the system prompt, and callers invoke it
/// from a tap on "My Location", never from opening a screen.
@MainActor
protocol DeviceLocationProviding: AnyObject {
    /// The current permission, without any prompt.
    func currentStatus() async -> DeviceLocationStatus
    /// Raises the "while using the app" prompt when the status is
    /// `notDetermined`, and returns the status once the user has answered.
    /// Any other status is returned as is, without a prompt.
    func requestAuthorization() async -> DeviceLocationStatus
    /// Asks for the precise position for this use only (iOS "temporary full
    /// accuracy"), and returns the status afterwards: still
    /// `authorizedReduced` when the user kept the approximate position.
    func requestPreciseAccuracy() async -> DeviceLocationStatus
    /// One fix. Throws `DeviceLocationFailure.unavailable` when none comes.
    func currentCoordinate() async throws -> DeviceCoordinate
}

/// Why "My Location" did or did not produce a position.
enum MyLocationOutcome: Equatable, Sendable {
    case located(DeviceCoordinate)
    case denied
    case servicesDisabled
    case unavailable
    /// Only with `requiringPreciseAccuracy`: the user keeps the approximate position.
    case preciseRequired
}

/// The localized message that explains a refusal. `denied` is the only cause
/// the user can lift from the app's page in Settings, so only it offers the shortcut.
struct MyLocationNotice: Equatable, Identifiable {
    enum Cause: Equatable {
        case denied
        case servicesDisabled
        case unavailable
        case preciseRequired
    }

    let cause: Cause
    var id: Cause { cause }

    var title: String {
        switch cause {
        case .denied: String(localized: "Location Access Is Off")
        case .servicesDisabled: String(localized: "Location Services Are Off")
        case .unavailable: String(localized: "Position Unavailable")
        case .preciseRequired: String(localized: "Precise Location Needed")
        }
    }

    var message: String {
        switch cause {
        case .denied:
            String(localized: "Allow Swimmich to use your location in Settings to find where you are.")
        case .servicesDisabled:
            String(localized: "Turn on Location Services in Settings, under Privacy & Security, to use your position.")
        case .unavailable:
            String(localized: "Your position could not be determined. Try again in a moment.")
        case .preciseRequired:
            String(localized: "Placing a photo needs your precise position. Allow Precise Location for Swimmich in Settings.")
        }
    }

    var offersSettings: Bool { cause == .denied || cause == .preciseRequired }
}

extension MyLocationOutcome {
    /// `nil` when a position was found.
    var notice: MyLocationNotice? {
        switch self {
        case .located: nil
        case .denied: MyLocationNotice(cause: .denied)
        case .servicesDisabled: MyLocationNotice(cause: .servicesDisabled)
        case .unavailable: MyLocationNotice(cause: .unavailable)
        case .preciseRequired: MyLocationNotice(cause: .preciseRequired)
        }
    }
}

extension DeviceLocationProviding {
    /// The whole "My Location" gesture: ask once when never asked, insist on
    /// the precise position only when the caller needs it (the adjust-location
    /// sheet writes the result to the server; the map only centers on it), then
    /// read one fix.
    func locate(requiringPreciseAccuracy: Bool) async -> MyLocationOutcome {
        var status = await currentStatus()
        if status == .notDetermined {
            status = await requestAuthorization()
        }
        switch status {
        case .servicesDisabled:
            return .servicesDisabled
        case .notDetermined, .denied:
            return .denied
        case .authorizedReduced:
            if requiringPreciseAccuracy {
                guard await requestPreciseAccuracy() == .authorizedFull else { return .preciseRequired }
            }
        case .authorizedFull:
            break
        }
        do {
            return .located(try await currentCoordinate())
        } catch {
            return .unavailable
        }
    }
}
