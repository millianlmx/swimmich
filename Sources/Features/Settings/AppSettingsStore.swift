import Foundation
import Observation

/// Every purely-local preference the app persists (settings-parity, gap G22):
/// timeline grouping and density, the viewer's image quality and tap behavior,
/// the three video switches, the slideshow's axes, the appearance pair and the
/// haptic master switch. No server route is involved — these are client
/// choices, read by the screens that own each axis.
///
/// Shape: one `UserDefaults` key per setting, decoded on creation and written on
/// mutation (`AppLanguageStore` / `MapSettingsStore` precedent), with `defaults`
/// injectable so tests exercise a dedicated suite instead of the app's storage.
///
/// Two rules hold the whole store together:
/// - **Every default reproduces today's behavior** (`tilesPerRow = 3`,
///   `groupBy = .day`, `loadOriginal = false`, `autoPlayVideo = true`,
///   `loopVideo = false`, `loadOriginalVideo = false`, slideshow wrapping and
///   dissolving at 3 s, `theme = .system`, `accent = .immich`,
///   `hapticsEnabled = true`, `smoothScrubbing = false`), so the feature is purely additive for anyone who
///   never opens the screen.
/// - **A stored value that cannot be decoded falls back to the default** rather
///   than wedging a screen into a state the user cannot see the origin of.
@MainActor
@Observable
final class AppSettingsStore {
    /// The one store per process. `DependencyContainer` publishes this very
    /// instance into the view tree, so a consumer built with the defaulted
    /// initializer reads the same preferences the Preferences screen writes —
    /// two instances would keep two mirrors of the same keys (the trap
    /// `DependencyContainer.language` documents).
    static let shared = AppSettingsStore()

    // MARK: - Keys
    //
    // The key strings are the ones upstream (`immich-app/immich@e55ac299`)
    // writes, kept verbatim: a setting that changes key silently loses the
    // user's choice on the next launch.

    static let timelineGroupByKey = "timelineGroupAssetsBy"
    static let timelineTilesPerRowKey = "timelineTilesPerRow"
    static let imageLoadOriginalKey = "imageLoadOriginal"
    static let tapToNavigateKey = "viewerTapToNavigate"
    static let autoPlayVideoKey = "viewerAutoPlayVideo"
    static let loopVideoKey = "viewerLoopVideo"
    static let loadOriginalVideoKey = "viewerLoadOriginalVideo"
    static let slideshowRepeatKey = "slideshowRepeat"
    static let slideshowSpeedKey = "slideshowDuration"
    static let slideshowLookKey = "slideshowLook"
    static let slideshowReverseKey = "slideshowDirection"
    static let themeModeKey = "themeMode"
    static let accentColorKey = "themePrimaryColor"
    static let hapticsEnabledKey = "hapticFeedbackEnabled"
    static let timelineSmoothScrubbingKey = "timelineSmoothScrubbing"

    private let defaults: UserDefaults

    // MARK: - Storage
    //
    // Private per setting: the public accessor below is the only way in, so no
    // mutation can skip the clamp or the write.
    //
    // `slideshowSpeed` is stored as raw seconds (upstream's `.slideshowDuration`)
    // so the on-disk shape survives a change to the picker's cases.

    private var storedGroupBy: TimelineGroupBy
    private var storedTilesPerRow: Int
    private var storedLoadOriginal: Bool
    private var storedTapToNavigate: Bool
    private var storedAutoPlayVideo: Bool
    private var storedLoopVideo: Bool
    private var storedLoadOriginalVideo: Bool
    private var storedSlideshowRepeat: Bool
    private var storedSlideshowSpeed: TimeInterval
    private var storedSlideshowLook: String
    private var storedSlideshowReverse: Bool
    private var storedTheme: AppTheme
    private var storedAccent: AppAccent
    private var storedHapticsEnabled: Bool
    private var storedSmoothScrubbing: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedGroupBy = defaults.string(forKey: Self.timelineGroupByKey)
            .flatMap(TimelineGroupBy.init(rawValue:)) ?? .day
        // An out-of-range density written by another version is clamped on read
        // as well as on write — the grid must never ask for 0 columns.
        storedTilesPerRow = (defaults.object(forKey: Self.timelineTilesPerRowKey) as? Int)
            .map { min(max($0, 2), 7) } ?? 3
        storedLoadOriginal = defaults.object(forKey: Self.imageLoadOriginalKey) as? Bool ?? false
        storedTapToNavigate = defaults.object(forKey: Self.tapToNavigateKey) as? Bool ?? false
        storedAutoPlayVideo = defaults.object(forKey: Self.autoPlayVideoKey) as? Bool ?? true
        storedLoopVideo = defaults.object(forKey: Self.loopVideoKey) as? Bool ?? false
        storedLoadOriginalVideo = defaults.object(forKey: Self.loadOriginalVideoKey) as? Bool ?? false
        // ON by default: today's ticker wraps at the last slide, and "Repeat"
        // off is what stops the show there.
        storedSlideshowRepeat = defaults.object(forKey: Self.slideshowRepeatKey) as? Bool ?? true
        storedSlideshowSpeed = defaults.object(forKey: Self.slideshowSpeedKey) as? TimeInterval ?? 3
        storedSlideshowLook = defaults.string(forKey: Self.slideshowLookKey) ?? "dissolve"
        storedSlideshowReverse = defaults.object(forKey: Self.slideshowReverseKey) as? Bool ?? false
        storedTheme = defaults.string(forKey: Self.themeModeKey)
            .flatMap(AppTheme.init(rawValue:)) ?? .system
        storedAccent = defaults.string(forKey: Self.accentColorKey)
            .flatMap(AppAccent.init(rawValue:)) ?? .immich
        storedHapticsEnabled = defaults.object(forKey: Self.hapticsEnabledKey) as? Bool ?? true
        storedSmoothScrubbing = defaults.object(forKey: Self.timelineSmoothScrubbingKey) as? Bool ?? false
    }

    // MARK: - Photos (timeline)

    var groupBy: TimelineGroupBy {
        get { storedGroupBy }
        set {
            guard newValue != storedGroupBy else { return }
            storedGroupBy = newValue
            defaults.set(newValue.rawValue, forKey: Self.timelineGroupByKey)
        }
    }

    /// Grid density, clamped **here** rather than at the call sites: the pinch
    /// gesture in the timeline and the Preferences stepper are two writers of
    /// one setting, and both must land on the same 2…7 bound.
    var tilesPerRow: Int {
        get { storedTilesPerRow }
        set {
            let clamped = min(max(newValue, 2), 7)
            guard clamped != storedTilesPerRow else { return }
            storedTilesPerRow = clamped
            defaults.set(clamped, forKey: Self.timelineTilesPerRowKey)
        }
    }

    /// Date scrubber behavior: off, releasing it snaps the grid to the first
    /// photo of the targeted month; on, to the spot of the month it was
    /// released at (upstream's "Smooth timeline scrubbing", PR #32552).
    var smoothScrubbing: Bool {
        get { storedSmoothScrubbing }
        set {
            guard newValue != storedSmoothScrubbing else { return }
            storedSmoothScrubbing = newValue
            defaults.set(newValue, forKey: Self.timelineSmoothScrubbingKey)
        }
    }

    // MARK: - Viewer

    /// Serve the original file instead of the transcoded `.fullsize` preview.
    var loadOriginal: Bool {
        get { storedLoadOriginal }
        set {
            guard newValue != storedLoadOriginal else { return }
            storedLoadOriginal = newValue
            defaults.set(newValue, forKey: Self.imageLoadOriginalKey)
        }
    }

    /// A tap on a photo advances to the next one instead of toggling the chrome.
    var tapToNavigate: Bool {
        get { storedTapToNavigate }
        set {
            guard newValue != storedTapToNavigate else { return }
            storedTapToNavigate = newValue
            defaults.set(newValue, forKey: Self.tapToNavigateKey)
        }
    }

    // MARK: - Video

    var autoPlayVideo: Bool {
        get { storedAutoPlayVideo }
        set {
            guard newValue != storedAutoPlayVideo else { return }
            storedAutoPlayVideo = newValue
            defaults.set(newValue, forKey: Self.autoPlayVideoKey)
        }
    }

    /// Restart the movie when it reaches the end instead of parking on the last
    /// frame (the viewer's replay button stays the manual path).
    var loopVideo: Bool {
        get { storedLoopVideo }
        set {
            guard newValue != storedLoopVideo else { return }
            storedLoopVideo = newValue
            defaults.set(newValue, forKey: Self.loopVideoKey)
        }
    }

    /// Stream the original file rather than the transcoded playback rendition.
    var loadOriginalVideo: Bool {
        get { storedLoadOriginalVideo }
        set {
            guard newValue != storedLoadOriginalVideo else { return }
            storedLoadOriginalVideo = newValue
            defaults.set(newValue, forKey: Self.loadOriginalVideoKey)
        }
    }

    // MARK: - Slideshow

    var slideshowRepeat: Bool {
        get { storedSlideshowRepeat }
        set {
            guard newValue != storedSlideshowRepeat else { return }
            storedSlideshowRepeat = newValue
            defaults.set(newValue, forKey: Self.slideshowRepeatKey)
        }
    }

    /// Seconds per slide (upstream's `.slideshowDuration`).
    var slideshowSpeed: TimeInterval {
        get { storedSlideshowSpeed }
        set {
            guard newValue != storedSlideshowSpeed else { return }
            storedSlideshowSpeed = newValue
            defaults.set(newValue, forKey: Self.slideshowSpeedKey)
        }
    }

    /// Raw value of `SlideshowViewModel.SlideshowTransitionStyle` — kept as the
    /// enum's own vocabulary so an unreadable value falls back to `.dissolve`.
    var slideshowLook: String {
        get { storedSlideshowLook }
        set {
            guard newValue != storedSlideshowLook else { return }
            storedSlideshowLook = newValue
            defaults.set(newValue, forKey: Self.slideshowLookKey)
        }
    }

    /// Play the show backwards (upstream's `.slideshowDirection`).
    var slideshowReverse: Bool {
        get { storedSlideshowReverse }
        set {
            guard newValue != storedSlideshowReverse else { return }
            storedSlideshowReverse = newValue
            defaults.set(newValue, forKey: Self.slideshowReverseKey)
        }
    }

    // MARK: - Appearance

    var theme: AppTheme {
        get { storedTheme }
        set {
            guard newValue != storedTheme else { return }
            storedTheme = newValue
            defaults.set(newValue.rawValue, forKey: Self.themeModeKey)
        }
    }

    var accent: AppAccent {
        get { storedAccent }
        set {
            guard newValue != storedAccent else { return }
            storedAccent = newValue
            defaults.set(newValue.rawValue, forKey: Self.accentColorKey)
        }
    }

    // MARK: - Feedback

    var hapticsEnabled: Bool {
        get { storedHapticsEnabled }
        set {
            guard newValue != storedHapticsEnabled else { return }
            storedHapticsEnabled = newValue
            defaults.set(newValue, forKey: Self.hapticsEnabledKey)
        }
    }

    // MARK: - Reset

    /// Back to factory state without reinstalling: the keys are **removed**
    /// (not rewritten with the defaults) so the next launch reads exactly what
    /// a fresh install would.
    func resetToDefaults() {
        [
            Self.timelineGroupByKey, Self.timelineTilesPerRowKey, Self.imageLoadOriginalKey,
            Self.tapToNavigateKey, Self.autoPlayVideoKey, Self.loopVideoKey,
            Self.loadOriginalVideoKey, Self.slideshowRepeatKey, Self.slideshowSpeedKey,
            Self.slideshowLookKey, Self.slideshowReverseKey, Self.themeModeKey,
            Self.accentColorKey, Self.hapticsEnabledKey, Self.timelineSmoothScrubbingKey
        ].forEach(defaults.removeObject(forKey:))

        storedGroupBy = .day
        storedTilesPerRow = 3
        storedLoadOriginal = false
        storedTapToNavigate = false
        storedAutoPlayVideo = true
        storedLoopVideo = false
        storedLoadOriginalVideo = false
        storedSlideshowRepeat = true
        storedSlideshowSpeed = 3
        storedSlideshowLook = "dissolve"
        storedSlideshowReverse = false
        storedTheme = .system
        storedAccent = .immich
        storedHapticsEnabled = true
        storedSmoothScrubbing = false
    }
}
