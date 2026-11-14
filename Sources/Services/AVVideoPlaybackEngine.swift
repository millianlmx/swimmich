import AVFoundation
import Foundation

/// How the engine reaches a server that has a TLS client certificate attached
/// (L-10): the app's own session (read at every request) and the identities
/// that say which servers have one.
struct VideoAppTransport {
    let session: @Sendable () -> URLSession
    let identities: any ClientIdentityStoring
}

/// Concrete `VideoPlaybackEngine` backed by `AVPlayer` + HLS playback URL.
///
/// - Auth: `AVURLAssetHTTPHeaderFieldsKey` carries the session token and the
///   server's custom headers (`ServerRequestAuthorization`), so the m3u8
///   playlist AND its segments (same authenticated base) both succeed. For a
///   server with a client certificate the URL goes through
///   `AppTransportVideoLoader` instead (`assetURL(for:transport:)`).
/// - Audio: session category set to `.playback` (movie playback) on prepare —
///   matches Photos' "ignore silent switch" behavior for videos.
/// - Lifecycle: time observer (0.5 s) → `onTimeUpdate`; end-of-play
///   notification → `onEnded`; item asset `load(.duration)` failure → error
///   surfaced to the caller through `prepare`'s throwing path.
/// - `@unchecked Sendable`: `AVPlayer` is not Sendable; every call happens on
///   the main actor via the ViewModel (pattern: `ImmichAPIClient`).
final class AVVideoPlaybackEngine: NSObject, VideoPlaybackEngine, @unchecked Sendable {

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var failedToEndObserver: NSObjectProtocol?
    private var failureReported = false
    private var currentItem: AVPlayerItem?

    private(set) var duration: Double = 0
    private(set) var isReady = false

    var onTimeUpdate: ((Double) -> Void)?
    var onReady: ((Double) -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private let customHeaders: any CustomHeadersProviding
    private let appTransport: VideoAppTransport?
    /// The loader of the item in place; AVFoundation only keeps it weakly.
    private var loader: AppTransportVideoLoader?

    init(
        customHeaders: any CustomHeadersProviding = CustomHeadersRegistry.shared,
        appTransport: VideoAppTransport? = nil
    ) {
        self.customHeaders = customHeaders
        self.appTransport = appTransport
        super.init()
    }

    /// The URL to hand to AVFoundation. With an app transport, an `http(s)` URL
    /// of a server that has a client certificate goes through the resource
    /// loader's private scheme; anything else keeps its URL (and the header
    /// based path below, AirPlay included).
    static func assetURL(for url: URL, transport: VideoAppTransport?) -> (url: URL, usesLoader: Bool) {
        guard let transport,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let key = ServerKey(url: url),
              transport.identities.hasIdentity(for: key),
              let loaderURL = AppTransportVideoLoader.loaderURL(for: url)
        else { return (url, false) }
        return (loaderURL, true)
    }

    /// The options of the `AVURLAsset`: pulled out so a test can read them
    /// without playing a video.
    static func assetOptions(
        url: URL, token: String?, customHeaders: any CustomHeadersProviding
    ) -> [String: Any] {
        let fields = ServerRequestAuthorization.dictionary(token: token, custom: customHeaders.headers(for: url))
        guard !fields.isEmpty else { return [:] }
        // The public constant `AVURLAssetHTTPHeaderFieldsKey` was dropped
        // from the iOS 26 SDK headers (symbol survives only in the .tbd),
        // but the option key string itself is stable and read verbatim
        // by AVURLAsset's options parser.
        return ["AVURLAssetHTTPHeaderFieldsKey": fields]
    }

    func prepare(url: URL, token: String?) async throws {
        let (assetURL, usesLoader) = Self.assetURL(for: url, transport: appTransport)
        let asset: AVURLAsset
        if usesLoader, let appTransport {
            // No header option: the loader applies the token and the custom
            // headers itself, on the app's session.
            asset = AVURLAsset(url: assetURL)
            let fresh = AppTransportVideoLoader(session: appTransport.session, token: token, customHeaders: customHeaders)
            asset.resourceLoader.setDelegate(fresh, queue: fresh.queue)
            loader = fresh
        } else {
            loader = nil
            let options = Self.assetOptions(url: url, token: token, customHeaders: customHeaders)
            asset = AVURLAsset(url: url, options: options)
        }
        // `isPlayable` is false for a file the device cannot play (a codec it lacks):
        // its container still loads a duration, so the duration alone proves nothing.
        let (loadedDuration, playable) = try await asset.load(.duration, .isPlayable)
        guard playable else { throw VideoPlaybackEngineError.notPlayable }
        attach(AVPlayerItem(asset: asset))

        let seconds = loadedDuration.seconds
        duration = seconds.isFinite ? seconds : 0
        isReady = true

        // Gap G9: let the viewer's stream leave for an external screen. Written
        // explicitly because the defaults are the only thing that would let a
        // future engine change break casting silently — and a Bearer-
        // authenticated URL keeps working over AirPlay, the phone staying the
        // HTTP client that the route reads through.
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        try? AVAudioSession.sharedInstance()
            .setCategory(.playback, mode: .moviePlayback)

        onReady?(duration)
    }

    /// Puts `item` in the player and watches it (end, failure, time). Split from
    /// `prepare` so a test can hand the engine an item that really fails.
    func attach(_ item: AVPlayerItem) {
        invalidateObservers()
        currentItem = item
        player.replaceCurrentItem(with: item)
        observeEnd(of: item)
        observeFailure(of: item)
        armTimeObserver()
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    func reload() {
        invalidateObservers()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        duration = 0
        isReady = false
    }

    func makePlayerLayer() -> AVPlayerLayer {
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        return layer
    }

    deinit {
        player.pause()
        invalidateObservers()
    }

    // MARK: - Observers

    private func armTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.onTimeUpdate?(time.seconds)
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onEnded?()
        }
    }

    /// An item that fails after it was ready — a file whose container reads but
    /// whose frames do not — is the only way to learn the media is unreadable
    /// once `prepare` has succeeded. Emits `onFailure` once per item, on the
    /// main queue; neither the item's error text nor its URL leave the engine.
    private func observeFailure(of item: AVPlayerItem) {
        failureReported = false
        let identity = ObjectIdentifier(item)
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.reportFailure(of: identity) }
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.reportFailure(of: identity)
        }
    }

    private func reportFailure(of identity: ObjectIdentifier) {
        guard let currentItem, ObjectIdentifier(currentItem) == identity, !failureReported else { return }
        failureReported = true
        onFailure?(UserFacingError.genericMessage)
    }

    private func invalidateObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }
    }
}