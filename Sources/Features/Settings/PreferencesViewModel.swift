import Foundation
import Observation

/// The Preferences screen's view model (settings-parity, gap G22) — the exact
/// shape of `LanguageSettingsViewModel`: it holds no state of its own, and every
/// read and every mutation is forwarded to `AppSettingsStore`.
///
/// The store stays the single writer, which is what lets four consumers
/// (`TimelineView`, the zoomable page, the video player, the slideshow) and this
/// screen share one value per setting instead of each keeping a copy the next
/// launch would contradict.
///
/// Two of the fourteen rows are projections rather than direct reads: the
/// slideshow pickers offer the enums the slideshow itself uses, while the store
/// keeps primitives (seconds, raw value) — an unreadable stored value then falls
/// back to the same case the slideshow would.
@MainActor
@Observable
final class PreferencesViewModel {
    private let store: AppSettingsStore

    init(store: AppSettingsStore) {
        self.store = store
    }

    // MARK: - Photos

    var groupBy: TimelineGroupBy {
        get { store.groupBy }
        set { store.groupBy = newValue }
    }

    var tilesPerRow: Int {
        get { store.tilesPerRow }
        set { store.tilesPerRow = newValue }
    }

    var smoothScrubbing: Bool {
        get { store.smoothScrubbing }
        set { store.smoothScrubbing = newValue }
    }

    // MARK: - Viewer

    var loadOriginal: Bool {
        get { store.loadOriginal }
        set { store.loadOriginal = newValue }
    }

    var tapToNavigate: Bool {
        get { store.tapToNavigate }
        set { store.tapToNavigate = newValue }
    }

    // MARK: - Video

    var autoPlayVideo: Bool {
        get { store.autoPlayVideo }
        set { store.autoPlayVideo = newValue }
    }

    var loopVideo: Bool {
        get { store.loopVideo }
        set { store.loopVideo = newValue }
    }

    var loadOriginalVideo: Bool {
        get { store.loadOriginalVideo }
        set { store.loadOriginalVideo = newValue }
    }

    // MARK: - Slideshow

    var slideshowRepeat: Bool {
        get { store.slideshowRepeat }
        set { store.slideshowRepeat = newValue }
    }

    /// The picker's axis is the slideshow's own enum, so the screen and the
    /// slideshow menu cannot drift apart on the set of speeds on offer.
    var slideshowSpeed: SlideshowViewModel.SlideshowSpeed {
        get { SlideshowViewModel.SlideshowSpeed(rawValue: store.slideshowSpeed) ?? .threeSeconds }
        set { store.slideshowSpeed = newValue.rawValue }
    }

    var slideshowLook: SlideshowViewModel.SlideshowTransitionStyle {
        get { SlideshowViewModel.SlideshowTransitionStyle(rawValue: store.slideshowLook) ?? .dissolve }
        set { store.slideshowLook = newValue.rawValue }
    }

    var slideshowReverse: Bool {
        get { store.slideshowReverse }
        set { store.slideshowReverse = newValue }
    }

    // MARK: - Appearance

    var theme: AppTheme {
        get { store.theme }
        set { store.theme = newValue }
    }

    var accent: AppAccent {
        get { store.accent }
        set { store.accent = newValue }
    }

    // MARK: - Feedback

    var hapticsEnabled: Bool {
        get { store.hapticsEnabled }
        set { store.hapticsEnabled = newValue }
    }

    // MARK: - Reset

    func resetToDefaults() {
        store.resetToDefaults()
    }
}
