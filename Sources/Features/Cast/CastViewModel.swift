import Foundation
import Observation

/// Projects `CastService` into what the viewer's cast sheet renders.
///
/// Every member is a read-through: the ViewModel stores no copy of the service's
/// state, so there is nothing to resynchronise when a route change arrives while
/// the sheet is open — the sheet observes the service through this object and
/// SwiftUI re-reads it on the service's mutation.
///
/// It also carries the one fact that would otherwise be buried in a view: a
/// video can be sent, a still image cannot (unless the implementation says
/// otherwise). That asymmetry is what the user must be told, so it lives here,
/// where it is testable, and not inside `CastSheet`.
@MainActor @Observable final class CastViewModel {
    private let service: any CastService

    init(service: any CastService) {
        self.service = service
    }

    var isAvailable: Bool { service.isAvailable }
    var isConnected: Bool { service.isConnected }
    var connectedRouteName: String? { service.connectedRouteName }
    var supportsStillImages: Bool { service.supportsStillImages }

    /// Name of the connected route, `nil` when nothing is connected — the sheet
    /// owns the wording of the empty state, the ViewModel does not.
    var statusText: String? { service.isConnected ? service.connectedRouteName : nil }

    /// Whether `asset` can leave the device over the current implementation.
    func canCast(_ asset: AssetReactItem) -> Bool {
        asset.isVideo || service.supportsStillImages
    }

    /// Whether the sheet warns that AirPlay cannot play this video (L-10): only
    /// a video, and only when a client certificate is installed for the server.
    func showsClientCertificateHint(for asset: AssetReactItem, clientCertificateActive: Bool) -> Bool {
        asset.isVideo && clientCertificateActive
    }

    /// Idempotent refresh hooks: the service is already observing process-wide,
    /// these keep the sheet's state current across its lifetime.
    func onAppear() { service.startObserving() }
    func onDisappear() { service.stopObserving() }
}
