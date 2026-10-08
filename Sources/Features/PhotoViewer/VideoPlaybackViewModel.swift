import Foundation

/// State machine for one full-screen video page in the photo viewer.
///
/// Owns playback state; the concrete AVFoundation player lives behind the
/// injectable `engine` seam, so unit tests exercise every transition with
/// `MockVideoPlaybackEngine`. Auto-plays once prepared (Photos behavior).
@Observable @MainActor
final class VideoPlaybackViewModel {

    private(set) var status: VideoPlaybackStatus = .idle
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var preparedAssetID: String?

    let engine: any VideoPlaybackEngine

    /// Preferences seam (gap G22). Read **at `prepare`**, never captured at
    /// init: the switches describe the next playback, and a movie already
    /// playing is not cut short because the user flipped one mid-stream.
    private let appSettings: AppSettingsStore

    /// Per-page override of the "Loop" preference. The slideshow passes `false`:
    /// a looping video never reaches `.ended`, and the slideshow's ticker waits
    /// on exactly that to move to the next slide.
    private let loopsVideo: Bool?

    /// The playback shape, snapshotted by `prepare` (see `appSettings`).
    private var autoPlayWhenReady = true
    private var loopWhenEnded = false

    init(
        engine: any VideoPlaybackEngine = AVVideoPlaybackEngine(),
        appSettings: AppSettingsStore = .shared,
        loopsVideo: Bool? = nil
    ) {
        self.engine = engine
        self.appSettings = appSettings
        self.loopsVideo = loopsVideo
        // Hooks stay synchronous: the concrete engine fires them on the main
        // queue (time observer + end notification), and the mock fires them
        // synchronously in tests — no async hop needed.
        engine.onTimeUpdate = { [weak self] seconds in
            self?.applyTime(seconds)
        }
        engine.onReady = { [weak self] seconds in
            guard let self else { return }
            self.duration = seconds
            self.status = .ready
            if self.autoPlayWhenReady { self.play() }
        }
        engine.onEnded = { [weak self] in
            guard let self else { return }
            self.currentTime = self.duration
            if self.loopWhenEnded {
                // Straight back to the top, still `.playing`: the transport
                // never parks on the last frame, so no `.ended` is reported.
                self.seek(to: 0)
                self.play()
            } else {
                self.status = .ended
            }
        }
        engine.onFailure = { [weak self] _ in
            self?.status = .failed(UserFacingError.genericMessage)
        }
    }

    /// Prepares the video page for `asset` against `baseURL` (HLS playback
    /// URL via `ImmichAssetURL.videoPlayback`) and auto-plays.
    ///
    /// `localFileURL` (issue #18) is the offline copy: when the asset was
    /// downloaded for offline viewing, playback reads that file instead of
    /// streaming — no network, and no bearer token (a local file needs none).
    func prepare(asset: AssetReactItem, baseURL: URL, token: String?, localFileURL: URL? = nil) async {
        await prepare(assetID: asset.id, baseURL: baseURL, token: token, localFileURL: localFileURL)
    }

    /// Prepares by explicit asset ID — used by the viewer for Live Photo
    /// video pairs, where the playable pair has a different id than the
    /// still page (`livePhotoVideoId`).
    func prepare(assetID: String, baseURL: URL, token: String?, localFileURL: URL? = nil) async {
        if let localFileURL {
            await prepare(url: localFileURL, assetID: assetID, token: nil)
            return
        }
        // "Stream Original" (gap G22): the original file instead of the
        // server's transcode of it. The offline copy above wins over both — a
        // downloaded file is not streamed at all.
        let url = appSettings.loadOriginalVideo
            ? ImmichAssetURL.original(assetId: assetID, baseURL: baseURL)
            : ImmichAssetURL.videoPlayback(assetId: assetID, baseURL: baseURL)
        await prepare(url: url, assetID: assetID, token: token)
    }

    /// Prepares the video PAIR of a Live Photo still (Photos-style live
    /// playback). Fails upstream when the still has no pair — the engine is
    /// never touched.
    func prepareLivePhoto(asset: AssetReactItem, baseURL: URL, token: String?) async {
        guard let pairID = asset.livePhotoVideoId, !pairID.isEmpty else {
            status = .failed("This Live Photo has no video pair.")
            return
        }
        await prepare(assetID: pairID, baseURL: baseURL, token: token)
    }

    /// Re-entrant safe core — tests call this directly with a crafted URL.
    func prepare(url: URL, assetID: String, token: String?) async {
        guard status != .preparing else { return }
        // The two shape switches are read HERE, once per preparation: the page
        // plays the way the settings said when it was prepared, whatever the
        // user does to the switches afterwards.
        autoPlayWhenReady = appSettings.autoPlayVideo
        loopWhenEnded = loopsVideo ?? appSettings.loopVideo
        status = .preparing
        preparedAssetID = assetID
        currentTime = 0
        duration = 0
        do {
            try await engine.prepare(url: url, token: token)
        } catch {
            // A cancelled preparation is no event, but `.preparing` would block
            // every later `prepare` (guard above): fall back to `.idle` (SP-1).
            guard let failure = UserFacingError.from(error) else {
                if status == .preparing { status = .idle }
                return
            }
            status = .failed(failure.message)
        }
    }

    func togglePlayPause() {
        switch status {
        case .playing:
            pause()
        case .ready, .paused, .ended:
            play()
        case .idle, .preparing, .failed:
            break
        }
    }

    func play() {
        guard status != .preparing else { return }
        engine.play()
        status = .playing
    }

    func pause() {
        engine.pause()
        if status == .playing { status = .paused }
    }

    /// Replay from the start after the movie finished (Photos parity).
    func replay() {
        seek(to: 0)
        play()
    }

    /// Jumps ±15 s (Photos' go-backward/forward 15 buttons).
    func seek(by seconds: Double) {
        let target = (currentTime + seconds).clamped(to: 0...max(duration, currentTime))
        seek(to: target)
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        engine.seek(to: target)
        currentTime = target
    }

    /// 0...1 scrubber position.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    /// Tears down a failed engine (drops the stuck item) so a Retry can
    /// re-prepare cleanly.
    func reset() {
        engine.reload()
        status = .idle
        preparedAssetID = nil
        currentTime = 0
        duration = 0
    }

    // MARK: - Engine hooks

    private func applyTime(_ seconds: Double) {
        currentTime = max(0, seconds)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}