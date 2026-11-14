import AVFoundation
import Foundation

/// Playback state machine surfaced to the UI. Kept here (not on the concrete
/// engine) so the ViewModel can own the transitions with a mock engine.
enum VideoPlaybackStatus: Sendable, Equatable {
    case idle
    case preparing
    case ready
    case playing
    case paused
    case ended
    case failed(String)
}

/// Why an engine refused media it could load: the file is intact but the
/// device cannot play it (unsupported codec). The view model falls back to the
/// server's stream on any failure, this one included.
enum VideoPlaybackEngineError: Error, Equatable {
    case notPlayable
}

/// Thin, injectable seam over `AVPlayer` for the photo-viewer video pages.
///
/// The ViewModel drives the state machine from these hooks and never touches
/// AVFoundation — unit tests use `MockVideoPlaybackEngine` (no AVPlayer).
protocol VideoPlaybackEngine: AnyObject, Sendable {
    var duration: Double { get }
    var isReady: Bool { get }

    var onTimeUpdate: ((Double) -> Void)? { get set }
    var onReady: ((Double) -> Void)? { get set }
    var onEnded: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }

    /// Loads `url` (HLS or original), authenticating with `token` when
    /// present, and fires `onReady(duration)` once playable.
    func prepare(url: URL, token: String?) async throws
    func play()
    func pause()
    func seek(to seconds: Double)
    /// Drops the current item so a failed engine can be re-`prepare`d.
    func reload()

    /// Layer bound to the engine's player, handed to the SwiftUI view.
    /// Default impl lets mock engines skip AVFoundation entirely.
    func makePlayerLayer() -> AVPlayerLayer
}

extension VideoPlaybackEngine {
    func makePlayerLayer() -> AVPlayerLayer { AVPlayerLayer() }
}