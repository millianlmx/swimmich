import Foundation
import Observation

/// Which of the two coordinate fields a value or an error belongs to.
enum CoordinateAxis: Hashable {
    case latitude
    case longitude

    /// Inclusive bounds, like `AssetDetailViewModel.setLocation`.
    var range: ClosedRange<Double> {
        switch self {
        case .latitude: -90...90
        case .longitude: -180...180
        }
    }
}

/// Why a typed coordinate cannot be used.
enum CoordinateFieldError: Error, Equatable {
    case empty
    case notNumeric
    case outOfRange
}

struct PhotoCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

/// State behind the adjust-location sheet: the two typed fields, the pin they
/// drive, and the save that validates both from their *current* text — never
/// from a Return key or a focus change.
@Observable
@MainActor
final class AdjustLocationViewModel: Identifiable {
    let id = UUID()
    let detail: AssetDetailViewModel
    let startedWithoutLocation: Bool

    /// Written by the sheet's text fields. Every change re-reads both fields.
    var latitudeText: String {
        didSet { if !isApplyingPin { textChanged(.latitude) } }
    }
    var longitudeText: String {
        didSet { if !isApplyingPin { textChanged(.longitude) } }
    }

    /// Where the pin sits: the last pair of values that both read correctly.
    /// `nil` on a photo without a location until two valid values exist.
    private(set) var pin: PhotoCoordinate?
    private(set) var latitudeError: CoordinateFieldError?
    private(set) var longitudeError: CoordinateFieldError?
    private(set) var isSaving = false
    private(set) var isLocating = false
    /// Why "My Location" left the pin and the fields alone; the sheet shows it as an alert.
    var locationNotice: MyLocationNotice?

    /// The device position behind "My Location" (L-25, B-29.3).
    let location: any DeviceLocationProviding

    @ObservationIgnored private var isApplyingPin = false

    init(detail: AssetDetailViewModel, location: (any DeviceLocationProviding)? = nil) {
        self.detail = detail
        self.location = location ?? SystemDeviceLocationService()
        let exif = detail.detail?.exifInfo
        let start: PhotoCoordinate?
        if let lat = exif?.latitude, let lon = exif?.longitude {
            start = PhotoCoordinate(latitude: lat, longitude: lon)
        } else if let lat = detail.asset.latitude, let lon = detail.asset.longitude {
            start = PhotoCoordinate(latitude: lat, longitude: lon)
        } else {
            start = nil
        }
        pin = start
        startedWithoutLocation = start == nil
        latitudeText = start.map { Self.format($0.latitude) } ?? ""
        longitudeText = start.map { Self.format($0.longitude) } ?? ""
    }

    // MARK: - My Location

    /// "My Location": the pin and both fields take the device's position, and
    /// nothing is sent until Save. This position is written to the server, so
    /// the precise one is required: an approximate fix (kilometres off) is
    /// refused with a message and leaves pin and fields as they were.
    func useMyLocation() async {
        guard !isLocating, !isSaving else { return }
        isLocating = true
        defer { isLocating = false }
        let outcome = await location.locate(requiringPreciseAccuracy: true)
        guard case .located(let coordinate) = outcome else {
            locationNotice = outcome.notice
            return
        }
        locationNotice = nil
        pinDragged(to: PhotoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    // MARK: - Pure helpers

    /// Reads a typed coordinate: comma or point decimal, optional sign,
    /// inclusive bounds of `axis`.
    nonisolated static func parse(_ text: String, axis: CoordinateAxis) -> Result<Double, CoordinateFieldError> {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .failure(.empty) }
        s = s.replacingOccurrences(of: "\u{2212}", with: "-")
        guard s.range(of: "^[+-]?([0-9]+([.,][0-9]*)?|[.,][0-9]+)$", options: .regularExpression) != nil else {
            return .failure(.notNumeric)
        }
        s = s.replacingOccurrences(of: ",", with: ".")
        // `Double(_:)` is locale-independent; give it a digit on each side of the point.
        var sign = ""
        if let first = s.first, first == "+" || first == "-" {
            sign = String(first)
            s.removeFirst()
        }
        if s.hasPrefix(".") { s = "0" + s }
        if s.hasSuffix(".") { s += "0" }
        guard let value = Double(sign + s) else { return .failure(.notNumeric) }
        return axis.range.contains(value) ? .success(value) : .failure(.outOfRange)
    }

    /// Field text for a coordinate: at most 6 decimals, trailing zeros dropped,
    /// point decimal whatever the language, no `-0`.
    nonisolated static func format(_ value: Double) -> String {
        var s = String(format: "%.6f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    nonisolated static func accessibilityValue(_ c: PhotoCoordinate) -> String {
        "\(format(c.latitude)), \(format(c.longitude))"
    }

    nonisolated static func message(for error: CoordinateFieldError, axis: CoordinateAxis) -> String {
        switch (axis, error) {
        case (.latitude, .empty): String(localized: "Enter a latitude.")
        case (.latitude, .notNumeric): String(localized: "Latitude must be a number.")
        case (.latitude, .outOfRange): String(localized: "Latitude must be between -90 and 90.")
        case (.longitude, .empty): String(localized: "Enter a longitude.")
        case (.longitude, .notNumeric): String(localized: "Longitude must be a number.")
        case (.longitude, .outOfRange): String(localized: "Longitude must be between -180 and 180.")
        }
    }

    // MARK: - Fields <-> pin

    private func read(_ axis: CoordinateAxis) -> Result<Double, CoordinateFieldError> {
        Self.parse(axis == .latitude ? latitudeText : longitudeText, axis: axis)
    }

    private func textChanged(_ axis: CoordinateAxis) {
        // An error already on screen follows the text; a new one only appears on save.
        switch axis {
        case .latitude where latitudeError != nil: latitudeError = read(.latitude).failureValue
        case .longitude where longitudeError != nil: longitudeError = read(.longitude).failureValue
        default: break
        }
        if case .success(let lat) = read(.latitude), case .success(let lon) = read(.longitude) {
            pin = PhotoCoordinate(latitude: lat, longitude: lon)
        }
    }

    /// The pin was dropped somewhere: the fields take its exact coordinates.
    func pinDragged(to c: PhotoCoordinate) {
        isApplyingPin = true
        pin = c
        latitudeText = Self.format(c.latitude)
        longitudeText = Self.format(c.longitude)
        isApplyingPin = false
        latitudeError = nil
        longitudeError = nil
        detail.errorMessage = nil
    }

    // MARK: - Save

    /// Validates both fields as typed right now, then writes the location.
    /// Returns whether it persisted; a failure message is left in
    /// `detail.errorMessage`, a field problem in `latitudeError`/`longitudeError`.
    @discardableResult
    func save() async -> Bool {
        guard !isSaving else { return false }
        let lat = read(.latitude)
        let lon = read(.longitude)
        latitudeError = lat.failureValue
        longitudeError = lon.failureValue
        guard case .success(let latitude) = lat, case .success(let longitude) = lon else { return false }
        isSaving = true
        detail.errorMessage = nil
        await detail.setLocation(latitude: latitude, longitude: longitude)
        isSaving = false
        guard detail.errorMessage == nil else { return false }
        pin = PhotoCoordinate(latitude: latitude, longitude: longitude)
        return true
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
