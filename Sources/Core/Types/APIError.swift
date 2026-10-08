import Foundation

/// Errors surfaced by the Immich client layer.
enum APIError: Error, LocalizedError, Equatable {
    case unauthorized
    case network(URLError)
    case serverError(Int, String?)
    case decoding(String)
    case invalidURL
    case multipartEncoding(String)
    case http(Int)
    /// The device is in read-only mode: a write was attempted and refused
    /// before it reached the wire (gap G17).
    case readOnlyMode

    var errorDescription: String? { UserFacingError.from(self)?.message }

    /// `true` when this error represents cooperative `Task` cancellation (a
    /// `URLError(.cancelled)` surfacing from `URLSession.data(for:)` when the
    /// enclosing Task was cancelled). Cancellation is a normal outcome of
    /// debounced live search / pagination and must NOT be surfaced to the user.
    var isCancellation: Bool {
        switch self {
        case .network(let e): return e.code == .cancelled
        default: return false
        }
    }

    /// Maps a raw URL response error to the APIError domain.
    static func from(_ error: Error) -> APIError {
        if let api = error as? APIError { return api }
        if let url = error as? URLError {
            // URLSession surfaces 401 via status code path, not URLError, but defensive.
            return .network(url)
        }
        // Cooperative `Task` cancellation (`error` is `CancellationError`) —
        // round-trip through `.network(.cancelled)` so callers can detect it
        // via `isCancellation` instead of mislabeling it a decoding failure.
        if error is CancellationError {
            return .network(URLError(.cancelled))
        }
        return .decoding(String(describing: error))
    }
}
