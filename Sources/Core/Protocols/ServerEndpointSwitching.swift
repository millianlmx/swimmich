import Foundation
import ImmichSharedKit

/// Why the address of the server is being evaluated again (L-26).
enum EvaluationReason: Equatable, Sendable {
    case launch, foreground, networkChange, backgroundPass, settingsChanged
}

/// The result of one evaluation, observable so a screen can reload once.
/// `id` grows with every outcome: two identical outcomes stay distinct.
struct EvaluationOutcome: Equatable, Sendable {
    let id: Int
    let changedAddress: Bool
}

/// Which address of the active account the app talks to, and the declared local
/// and external addresses behind it. The app's identity of the account never
/// changes (`accountURL`); only the address in use does.
@MainActor
protocol ServerEndpointSwitching: AnyObject {
    var accountID: String? { get }
    var settings: ServerAddressSettings { get }
    var activeURL: URL? { get }
    var usesLocal: Bool { get }
    var externalURL: URL? { get }
    var localURL: URL? { get }
    var localStatus: ServerAddressStatus { get }
    /// Nil until the external address has been probed in this session.
    var externalStatus: ServerAddressStatus? { get }
    var isEvaluating: Bool { get }
    var lastOutcome: EvaluationOutcome? { get }

    /// The address links shared with other people are built on.
    var publicURL: URL? { get }
    /// The connection address, the external one and the local one, no duplicate.
    var knownURLs: [URL] { get }

    func save(_ new: ServerAddressSettings) async
    func evaluate(_ reason: EvaluationReason) async
}
