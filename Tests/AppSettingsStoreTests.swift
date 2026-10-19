import XCTest
import SwiftUI
import UIKit
@testable import ImmichSwiftUI

/// The store's contract is "what the user picked is still there next launch":
/// every case writes through one instance and reads it back with a second one,
/// so a value that only lives in memory fails. The defaults matter just as
/// much — they are what makes the feature purely additive for anyone who never
/// opens the Preferences screen.
@MainActor
final class AppSettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Defaults

    /// The fourteen defaults are the behavior the app had before this store
    /// existed, spelled out: `tilesPerRow = 3` and day grouping for the grid,
    /// the transcoded preview, the chrome-toggling tap, auto-play on, no loop,
    /// the transcoded video, a dissolving 3-second slideshow that wraps, the
    /// system theme, the Immich accent and haptics on.
    func test_defaults_matchCurrentBehaviour() {
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.tilesPerRow, 3)
        XCTAssertEqual(store.groupBy, .day)
        XCTAssertFalse(store.loadOriginal)
        XCTAssertFalse(store.tapToNavigate)
        XCTAssertTrue(store.autoPlayVideo)
        XCTAssertFalse(store.loopVideo)
        XCTAssertFalse(store.loadOriginalVideo)
        XCTAssertTrue(store.slideshowRepeat, "the ticker wrapped at the last slide")
        XCTAssertEqual(store.slideshowSpeed, 3)
        XCTAssertEqual(store.slideshowLook, "dissolve")
        XCTAssertFalse(store.slideshowReverse)
        XCTAssertEqual(store.theme, .system, "iOS decided the appearance")
        XCTAssertEqual(store.accent, .immich)
        XCTAssertTrue(store.hapticsEnabled)
    }

    // MARK: - Density bound

    func test_tilesPerRow_isClampedToTwoThroughSeven() {
        let store = AppSettingsStore(defaults: defaults)

        store.tilesPerRow = 1
        XCTAssertEqual(store.tilesPerRow, 2)
        store.tilesPerRow = 9
        XCTAssertEqual(store.tilesPerRow, 7)
        store.tilesPerRow = 5
        XCTAssertEqual(store.tilesPerRow, 5)

        // The bound also holds for a value this version never wrote (a newer
        // build, an older one): the grid must never be told to draw 0 columns.
        defaults.set(42, forKey: AppSettingsStore.timelineTilesPerRowKey)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).tilesPerRow, 7)
    }

    // MARK: - Relaunch

    func test_everySetting_survivesAFreshStoreOnTheSameDefaults() {
        let store = AppSettingsStore(defaults: defaults)
        store.groupBy = .month
        store.tilesPerRow = 5
        store.loadOriginal = true
        store.tapToNavigate = true
        store.autoPlayVideo = false
        store.loopVideo = true
        store.loadOriginalVideo = true
        store.slideshowRepeat = false
        store.slideshowSpeed = 5
        store.slideshowLook = "kenBurns"
        store.slideshowReverse = true
        store.theme = .dark
        store.accent = .purple
        store.hapticsEnabled = false

        let reloaded = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(reloaded.groupBy, .month)
        XCTAssertEqual(reloaded.tilesPerRow, 5)
        XCTAssertTrue(reloaded.loadOriginal)
        XCTAssertTrue(reloaded.tapToNavigate)
        XCTAssertFalse(reloaded.autoPlayVideo)
        XCTAssertTrue(reloaded.loopVideo)
        XCTAssertTrue(reloaded.loadOriginalVideo)
        XCTAssertFalse(reloaded.slideshowRepeat)
        XCTAssertEqual(reloaded.slideshowSpeed, 5)
        XCTAssertEqual(reloaded.slideshowLook, "kenBurns")
        XCTAssertTrue(reloaded.slideshowReverse)
        XCTAssertEqual(reloaded.theme, .dark)
        XCTAssertEqual(reloaded.accent, .purple)
        XCTAssertFalse(reloaded.hapticsEnabled)
    }

    func test_unreadableStoredTheme_fallsBackToSystem() {
        defaults.set("midnight", forKey: AppSettingsStore.themeModeKey)

        XCTAssertEqual(AppSettingsStore(defaults: defaults).theme, .system)
    }

    // MARK: - Reset

    func test_resetToDefaults_restoresEveryKey() {
        let store = AppSettingsStore(defaults: defaults)
        store.groupBy = .none
        store.tilesPerRow = 6
        store.loadOriginal = true
        store.tapToNavigate = true
        store.autoPlayVideo = false
        store.loopVideo = true
        store.loadOriginalVideo = true
        store.slideshowRepeat = false
        store.slideshowSpeed = 5
        store.slideshowLook = "slide"
        store.slideshowReverse = true
        store.theme = .light
        store.accent = .pink
        store.hapticsEnabled = false

        store.resetToDefaults()

        XCTAssertEqual(store.groupBy, .day)
        XCTAssertEqual(store.tilesPerRow, 3)
        XCTAssertFalse(store.loadOriginal)
        XCTAssertFalse(store.tapToNavigate)
        XCTAssertTrue(store.autoPlayVideo)
        XCTAssertFalse(store.loopVideo)
        XCTAssertFalse(store.loadOriginalVideo)
        XCTAssertTrue(store.slideshowRepeat)
        XCTAssertEqual(store.slideshowSpeed, 3)
        XCTAssertEqual(store.slideshowLook, "dissolve")
        XCTAssertFalse(store.slideshowReverse)
        XCTAssertEqual(store.theme, .system)
        XCTAssertEqual(store.accent, .immich)
        XCTAssertTrue(store.hapticsEnabled)

        // The keys are removed, not rewritten with their defaults: the next
        // launch must read what a fresh install reads.
        XCTAssertEqual(AppSettingsStore(defaults: defaults).tilesPerRow, 3)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).accent, .immich)
    }

    // MARK: - The two projections the root consumes

    func test_theme_colorScheme_nilOnlyForSystem() {
        XCTAssertNil(AppTheme.system.colorScheme, "nil is what hands the choice back to iOS")
        XCTAssertEqual(AppTheme.light.colorScheme, .light)
        XCTAssertEqual(AppTheme.dark.colorScheme, .dark)
    }

    /// `.immich` must render the brand color in light *and* dark — it wraps a
    /// dynamic provider, so the invariant is about the resolved pixels, not
    /// about the wrapper. "Ne rien changer" has to stay the color of today.
    func test_accent_immichIsTheBrandColor() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertEqual(
                components(of: AppAccent.immich.color, style: style),
                components(of: Color.immichPrimary, style: style),
                "\(style) brand color drifted"
            )
        }
    }

    /// AC-8: the mark's two ends are `immichPrimary` frozen at one appearance
    /// each (pale = its dark value, deep = its light value), and they stay
    /// frozen: the mark must not follow the system appearance.
    func test_logoPalette_isTheBrandPairInEveryAppearance() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            XCTAssertEqual(
                components(of: .immichLogoLight, style: style),
                components(of: .immichPrimary, style: .dark),
                "\(style) pale end drifted from immichPrimary dark"
            )
            XCTAssertEqual(
                components(of: .immichLogoDeep, style: style),
                components(of: .immichPrimary, style: .light),
                "\(style) deep end drifted from immichPrimary light"
            )
        }
    }

    /// AC-4: the visible name changed to "Swimmich", the stored identity did not —
    /// a user who picked the default accent before the rename keeps `"immich"`
    /// under `themePrimaryColor`, and it still reads back as `.immich`.
    func test_accent_immichRawValueSurvivesTheRename() {
        XCTAssertEqual(AppAccent(rawValue: "immich"), .immich)

        defaults.set("immich", forKey: AppSettingsStore.accentColorKey)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).accent, .immich)

        let store = AppSettingsStore(defaults: defaults)
        store.accent = .blue
        store.accent = .immich
        XCTAssertEqual(defaults.string(forKey: AppSettingsStore.accentColorKey), "immich")
    }

    private func components(of color: Color, style: UIUserInterfaceStyle) -> [CGFloat] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        return UIColor(color).resolvedColor(with: traits).cgColor.components ?? []
    }
}
