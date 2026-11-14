import Foundation
@testable import ImmichSwiftUI

/// Deterministic `VideoPlaybackEngine` for ViewModel tests — records calls,
/// exposes the closure hooks so tests can fire engine events (time update,
/// ready, ended, failure) exactly like the real AVPlayer engine would.
final class MockVideoPlaybackEngine: NSObject, VideoPlaybackEngine, @unchecked Sendable {

    var duration: Double = 30
    var isReady = false

    var onTimeUpdate: ((Double) -> Void)?
    var onReady: ((Double) -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: ((String) -> Void)?

    var preparedURL: URL?
    var preparedToken: String?
    var prepareError: Error?
    var playCount = 0
    var pauseCount = 0
    var lastSeek: Double?
    var reloadCount = 0

    /// Every `prepare` call, failed ones included (`preparedURL` keeps the last successful one).
    private(set) var preparedURLs: [URL] = []
    private(set) var preparedTokens: [String?] = []
    /// Per-URL failure, consulted before `prepareError`.
    var prepareErrorsByURL: [URL: Error] = [:]
    /// Awaited at the start of each `prepare`, before it returns or throws.
    var onPrepare: ((URL) async -> Void)?

    func prepare(url: URL, token: String?) async throws {
        preparedURLs.append(url)
        preparedTokens.append(token)
        await onPrepare?(url)
        if let error = prepareErrorsByURL[url] {
            throw error
        }
        if let prepareError {
            throw prepareError
        }
        preparedURL = url
        preparedToken = token
        isReady = true
        onReady?(duration)
    }

    func play() { playCount += 1 }

    func pause() { pauseCount += 1 }

    func seek(to seconds: Double) { lastSeek = seconds }

    func reload() {
        isReady = false
        reloadCount += 1
    }

    /// Fires the hooks the same way `AVVideoPlaybackEngine` would.
    func fireTimeUpdate(_ seconds: Double) { onTimeUpdate?(seconds) }
    func fireReady(_ seconds: Double) { onReady?(seconds) }
    func fireEnded() { onEnded?() }
    func fireFailure(_ message: String) { onFailure?(message) }
}