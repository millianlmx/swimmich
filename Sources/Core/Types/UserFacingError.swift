import Foundation

/// Single source of user-visible error copy. Every error surface maps through
/// here: no transport, decoding or server-body text may reach the UI.
///
/// `from(_:)` returns `nil` for a cancellation: a cancelled request is a normal
/// outcome and must be treated as "no event" (no message, no loading state).
struct UserFacingError: Equatable, Sendable {
    enum Family: Equatable, Sendable { case offline, serverError, sessionExpired, other }

    let family: Family
    let message: String

    /// `true` for cooperative cancellation: `CancellationError`, `URLError(.cancelled)`,
    /// `APIError.network(URLError(.cancelled))`, or its bridged `NSError`.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError { return url.code == .cancelled }
        if let api = error as? APIError, case .network(let url) = api { return url.code == .cancelled }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    /// Maps any error to a user-facing copy. `nil` means cancellation: treat it as no event.
    static func from(_ error: Error) -> UserFacingError? {
        if isCancellation(error) { return nil }
        if let api = error as? APIError {
            switch api {
            case .unauthorized:
                return UserFacingError(family: .sessionExpired, message: sessionExpiredMessage)
            case .network:
                return UserFacingError(family: .offline, message: offlineMessage)
            case .serverError(let code, _) where code >= 500:
                return UserFacingError(family: .serverError, message: serverErrorMessage)
            case .http(let code) where code >= 500:
                return UserFacingError(family: .serverError, message: serverErrorMessage)
            case .readOnlyMode:
                return UserFacingError(family: .other, message: readOnlyModeMessage)
            case .serverError, .decoding, .invalidURL, .multipartEncoding, .http:
                return UserFacingError(family: .other, message: genericMessage)
            }
        }
        if error is URLError || (error as NSError).domain == NSURLErrorDomain {
            return UserFacingError(family: .offline, message: offlineMessage)
        }
        return UserFacingError(family: .other, message: genericMessage)
    }

    static var offlineMessage: String {
        String(localized: "No network connection. Check your connection and try again.")
    }

    static var serverErrorMessage: String {
        String(localized: "The server ran into a problem. Please try again.")
    }

    static var sessionExpiredMessage: String {
        String(localized: "Your session has expired. Please sign in again.")
    }

    static var genericMessage: String {
        String(localized: "Something went wrong. Please try again.")
    }

    static var readOnlyModeMessage: String {
        String(localized: "Read-only mode is on. Turn it off in Me to change your library.")
    }
}

extension Error {
    /// `nil` ⇔ cancellation — to be treated as "no event".
    var userFacingMessage: String? { UserFacingError.from(self)?.message }
}
