import Foundation
import Observation

/// Load state of one full-screen photo page, and its "Try Again" (L-29).
///
/// One instance per page, held by `ZoomableImageView`, never shared: the pager
/// gives each page `.id(asset.id)`, so a failure stays on its own page.
@Observable
@MainActor
final class ViewerImageLoadViewModel {
    enum Phase: Equatable { case loading, loaded, failed }

    private(set) var phase: Phase = .loading
    /// Number of retries so far. It is the loader's `reloadToken`: bumping it
    /// restarts the load and makes the request bypass the URL cache.
    private(set) var attempt = 0

    /// Result of one load. Ignored when it belongs to an attempt that a retry
    /// has since replaced.
    func record(_ outcome: ImageSourceOutcome, forAttempt: Int) {
        guard forAttempt == attempt else { return }
        switch outcome {
        case .loaded: phase = .loaded
        case .failed: phase = .failed
        }
    }

    /// Only a failed page retries: a second tap while the request is in flight
    /// must not send a duplicate.
    func retry() {
        guard phase == .failed else { return }
        attempt += 1
        phase = .loading
    }

    var showsRetry: Bool { phase == .failed }
    /// The first display shows no spinner (it would change L-14's zoomed
    /// opening): only a retry in flight does.
    var showsRetryProgress: Bool { phase == .loading && attempt > 0 }
}
