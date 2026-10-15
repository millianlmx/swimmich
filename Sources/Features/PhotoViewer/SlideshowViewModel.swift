import Foundation
import Observation

/// Pure slideshow state machine — no Timer, no AVFoundation (unit-testable).
///
/// The VIEW owns the ticking loop (see `SlideshowView`): it runs a `.task(id:)`
/// loop re-armed whenever speed/play/video-active state changes, and calls
/// `advance()` only when `isPlaying` and the current slide is not an active
/// video. `slideChanged()` arms the video suspension when a video/Live-Photo
/// slide appears; `videoEnded()` releases it and moves on immediately (Photos
/// behavior: the slideshow pauses on a video and continues the instant it ends).
@MainActor
@Observable
final class SlideshowViewModel {

    enum SlideshowSpeed: TimeInterval, CaseIterable, Identifiable {
        case twoSeconds = 2
        case threeSeconds = 3
        case fiveSeconds = 5
        case tenSeconds = 10

        var id: TimeInterval { rawValue }

        var label: String { "\(Int(rawValue))s" }
    }

    /// Cross-slide transition flavor. `kenBurns` only affects stills (the
    /// image itself drifts); the cross-slide transition stays a crossfade.
    enum SlideshowTransitionStyle: String, CaseIterable, Identifiable {
        case dissolve
        case slide
        case kenBurns

        var id: String { rawValue }

        /// The English literal **is** the catalog key and is extracted at build
        /// time — but the key only reaches the screen through
        /// `String(localized:)`: the Preferences picker and the slideshow's own
        /// menu render `Text(label)`, and a bare literal there would stay
        /// English on a French device.
        var label: String {
            switch self {
            case .dissolve: return String(localized: "Dissolve")
            case .slide: return String(localized: "Slide")
            case .kenBurns: return String(localized: "Ken Burns")
            }
        }
    }

    // MARK: - State

    private(set) var currentIndex: Int
    private(set) var isPlaying = false

    /// Preferences seam (gap G22). Speed, look and order are seeded from it at
    /// init, and the two setters below write back — so the slideshow's own
    /// menus and the Preferences screen modify the same value, which is exactly
    /// what two independent `@AppStorage` declarations would not do.
    private let appSettings: AppSettingsStore

    private var storedSpeed: SlideshowSpeed
    private var storedTransition: SlideshowTransitionStyle

    var speed: SlideshowSpeed {
        get { storedSpeed }
        set {
            guard newValue != storedSpeed else { return }
            storedSpeed = newValue
            appSettings.slideshowSpeed = newValue.rawValue
        }
    }

    var transition: SlideshowTransitionStyle {
        get { storedTransition }
        set {
            guard newValue != storedTransition else { return }
            storedTransition = newValue
            appSettings.slideshowLook = newValue.rawValue
        }
    }

    /// Whether the show wraps at the last slide. Today's ticker wraps
    /// unconditionally, so the additive default is ON (`advance()` stops only
    /// when this is off).
    var repeats: Bool {
        get { appSettings.slideshowRepeat }
        set { appSettings.slideshowRepeat = newValue }
    }
    /// True while the current slide is a video/Live-Photo being played inline —
    /// the ticker must not advance during playback.
    private(set) var isVideoActive = false

    let assets: [AssetReactItem]
    /// Playback order: position → asset index. Identity until `shuffle()`.
    private(set) var order: [Int]

    var currentAsset: AssetReactItem? {
        guard order.indices.contains(currentIndex) else { return nil }
        let assetIndex = order[currentIndex]
        guard assets.indices.contains(assetIndex) else { return nil }
        return assets[assetIndex]
    }

    var count: Int { assets.count }

    // MARK: - Init

    init(assets: [AssetReactItem], startIndex: Int = 0, appSettings: AppSettingsStore = .shared) {
        self.assets = assets
        self.appSettings = appSettings
        // Unreadable stored values fall back to the case the slideshow would
        // have used before the setting existed.
        self.storedSpeed = SlideshowSpeed(rawValue: appSettings.slideshowSpeed) ?? .threeSeconds
        self.storedTransition = SlideshowTransitionStyle(rawValue: appSettings.slideshowLook) ?? .dissolve

        // "Reverse Order": the show runs backwards. The order is reversed, not
        // the step direction, so the slide on screen when the viewer starts the
        // show is still the one that opens it (its position is looked up in the
        // reversed order instead of assumed to be `startIndex`).
        var initialOrder = Array(assets.indices)
        if appSettings.slideshowReverse { initialOrder.reverse() }
        self.order = initialOrder

        let wanted = assets.isEmpty ? 0 : min(max(startIndex, 0), assets.count - 1)
        self.currentIndex = initialOrder.firstIndex(of: wanted) ?? wanted
    }

    // MARK: - Transport

    func start() { isPlaying = true }

    func stop() { isPlaying = false }

    func togglePlayPause() { isPlaying.toggle() }

    /// Advances one slide. No-op while paused or while a video is playing on
    /// the current slide (ticker gating, belt and braces). At the last slide it
    /// wraps when "Repeat" is on — today's behavior, and the default — and
    /// otherwise stops the show, which is what the ticker's `isPlaying` guard
    /// then sees.
    func advance() {
        guard isPlaying, !isVideoActive, !assets.isEmpty else { return }
        guard currentIndex + 1 < assets.count else {
            guard repeats else {
                stop()
                return
            }
            currentIndex = 0
            return
        }
        currentIndex += 1
    }

    /// Manual next — allowed even while paused.
    func next() {
        guard !assets.isEmpty else { return }
        currentIndex = (currentIndex + 1) % assets.count
    }

    /// Manual previous — allowed even while paused.
    func previous() {
        guard !assets.isEmpty else { return }
        currentIndex = (currentIndex - 1 + assets.count) % assets.count
    }

    func goTo(index: Int) {
        guard !assets.isEmpty else { return }
        currentIndex = min(max(index, 0), assets.count - 1)
    }

    /// Called via `VideoPlayerView.onStatusChange` on `.ended` AND `.failed` —
    /// releases the suspension and advances immediately (Photos skips a broken
    /// video). Idempotent: only advances if a video was actually active.
    func videoEnded() {
        let wasVideo = isVideoActive
        isVideoActive = false
        if wasVideo { advance() }
    }

    /// Jolts the state machine when the slide changes (view calls on
    /// `.onChange(of: currentIndex)`): a video/Live-Photo slide arms the
    /// suspension, a still clears it.
    func slideChanged() {
        if let asset = currentAsset, asset.hasPlayableMotion {
            isVideoActive = true
        } else {
            isVideoActive = false
        }
    }

    /// Randomizes the playback order while keeping the current asset on screen
    /// (no visual jump). No-op for fewer than two assets.
    func shuffle() {
        guard assets.count > 1 else { return }
        let currentAssetID = currentAsset?.id
        order.shuffle()
        if let id = currentAssetID, let newPosition = order.firstIndex(where: { assets[$0].id == id }) {
            currentIndex = newPosition
        } else {
            currentIndex = min(currentIndex, assets.count - 1)
        }
    }
}

/// Pure swipe/step direction helper for the cross-slide transition (unit-testable,
/// no SwiftUI): `isForward` decides whether moving `old → new` is a "next" step
/// (insertion from the trailing edge) or a "previous" step, accounting for wrap.
enum SlideshowDirection {
    static func isForward(from old: Int, to new: Int, count: Int) -> Bool {
        guard count > 1 else { return true }
        let forward = (new - old + count) % count
        let backward = (old - new + count) % count
        return forward <= backward
    }
}

/// Pure Ken Burns phase math (unit-testable, no SwiftUI): maps elapsed time to a
/// slow drift (scale 1.0→1.06 + gentle pan). Identity when Reduce Motion is on —
/// the image stays static.
struct KenBurnsPhase: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let identity = KenBurnsPhase()

    /// `elapsed` = seconds since an arbitrary epoch (e.g. reference date).
    /// Ping-pong drift over `period`: zoom in, then back out, with a subtle pan.
    static func progress(elapsed: TimeInterval, reduceMotion: Bool, period: TimeInterval = 16) -> KenBurnsPhase {
        guard !reduceMotion else { return .identity }
        let cycle = elapsed.truncatingRemainder(dividingBy: period * 2) / period   // 0..<2
        let pingPong = cycle <= 1 ? cycle : 2 - cycle                              // 0→1→0
        let scale = 1.0 + 0.06 * pingPong
        let pan = 8 * sin(pingPong * .pi * 2)
        return KenBurnsPhase(scale: scale, offset: CGSize(width: pan, height: pan * 0.5))
    }
}
