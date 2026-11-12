import XCTest
import SwiftUI
@testable import ImmichSwiftUI

/// Contract of the motion gate (`Motion+PhotoVault.swift`): under Reduce Motion it
/// only ever hands back a change of opacity or an immediate change; with the
/// setting off it hands back exactly what was asked for (AC-172), and the journey
/// rules built on it hold (AC-33, AC-162 to AC-171).
final class MotionGateTests: XCTestCase {

    private var suiteName: String?

    override func tearDown() {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        suiteName = nil
        super.tearDown()
    }

    // MARK: - The gate (AC-172)

    func test_AC_172_movement() {
        XCTAssertNil(PVMotion.movement(.snappy, reduceMotion: true))
        XCTAssertNil(PVMotion.movement(PVMotion.standard, reduceMotion: true))
        XCTAssertEqual(PVMotion.movement(.spring(), reduceMotion: false), .spring())
    }

    func test_AC_172_fading() {
        XCTAssertEqual(PVMotion.fading(PVMotion.standard, reduceMotion: true), PVMotion.fade)
        XCTAssertEqual(PVMotion.fading(PVMotion.standard, reduceMotion: false), PVMotion.standard)
        XCTAssertEqual(PVMotion.fade, .linear(duration: 0.3))
    }

    func test_AC_172_appearance() {
        let requested: [PVTransition] = [.opacityAndScale(0.7), .opacityAndMove(.top), .opacity]
        for transition in requested {
            XCTAssertEqual(PVMotion.appearance(transition, reduceMotion: true), .fade)
            XCTAssertEqual(PVMotion.appearance(transition, reduceMotion: false), transition)
        }
    }

    func test_AC_172_scrollEffect() {
        XCTAssertEqual(
            PVMotion.scrollEffect(isIdentity: false, scale: 0.94, opacity: 0.9, reduceMotion: true),
            PVScrollEffect(scale: 1, opacity: 1)
        )
        XCTAssertEqual(
            PVMotion.scrollEffect(isIdentity: false, scale: 0.94, opacity: 0.9, reduceMotion: false),
            PVScrollEffect(scale: 0.94, opacity: 0.9)
        )
        XCTAssertEqual(
            PVMotion.scrollEffect(isIdentity: true, scale: 0.94, opacity: 0.9, reduceMotion: false),
            PVScrollEffect(scale: 1, opacity: 1)
        )
    }

    func test_AC_172_contentChange() {
        XCTAssertEqual(PVMotion.contentChange(.numericText(), reduceMotion: true), .opacity)
        XCTAssertEqual(PVMotion.contentChange(.symbolEffect(.replace), reduceMotion: true), .opacity)
        XCTAssertEqual(PVMotion.contentChange(.numericText(), reduceMotion: false), .numericText())
        XCTAssertEqual(PVMotion.contentChange(.symbolEffect(.replace), reduceMotion: false), .symbolEffect(.replace))
    }

    func test_AC_172_symbolEffectsRemoved() {
        XCTAssertTrue(PVMotion.symbolEffectsRemoved(reduceMotion: true))
        XCTAssertFalse(PVMotion.symbolEffectsRemoved(reduceMotion: false))
    }

    func test_AC_172_shimmer() {
        XCTAssertNil(PVMotion.shimmerLoop(duration: 1.5, reduceMotion: true))
        XCTAssertEqual(
            PVMotion.shimmerLoop(duration: 1.5, reduceMotion: false),
            .linear(duration: 1.5).repeatForever(autoreverses: false)
        )
        XCTAssertFalse(PVMotion.shimmerVisible(reduceMotion: true))
        XCTAssertTrue(PVMotion.shimmerVisible(reduceMotion: false))
    }

    func test_AC_172_scaleAndOffset() {
        XCTAssertEqual(PVMotion.scale(0.97, reduceMotion: true), 1)
        XCTAssertEqual(PVMotion.scale(0.97, reduceMotion: false), 0.97)
        XCTAssertEqual(PVMotion.offset(-12, reduceMotion: true), 0)
        XCTAssertEqual(PVMotion.offset(-12, reduceMotion: false), -12)
    }

    func test_AC_172_coverStyle() {
        XCTAssertEqual(PVMotion.coverStyle(selfAnimated: false, reduceMotion: true), .fade)
        XCTAssertEqual(PVMotion.coverStyle(selfAnimated: false, reduceMotion: false), .system)
        XCTAssertEqual(PVMotion.coverStyle(selfAnimated: true, reduceMotion: true), .selfAnimated)
        XCTAssertEqual(PVMotion.coverStyle(selfAnimated: true, reduceMotion: false), .selfAnimated)
    }

    func test_AC_172_isReduced() {
        XCTAssertTrue(PVMotion.isReduced(system: false, testSwitch: true))
        XCTAssertTrue(PVMotion.isReduced(system: true, testSwitch: false))
        XCTAssertFalse(PVMotion.isReduced(system: false, testSwitch: false))
    }

    // MARK: - The journey (AC-33, AC-162 to AC-171)

    func test_AC_33_reducedJourneyRules() {
        let reduced = PVMotion.isReduced(system: true, testSwitch: false)
        // No parallax at the edge of the grid.
        XCTAssertEqual(
            PVMotion.scrollEffect(isIdentity: false, scale: 0.94, opacity: 0.9, reduceMotion: reduced),
            PVScrollEffect(scale: 1, opacity: 1)
        )
        // The photo opens by fade, covers fade, nothing springs.
        XCTAssertEqual(
            ViewerZoomPlan.openStyle(hasHeroImage: true, hasSourceFrame: true, reduceMotion: reduced),
            .fade
        )
        XCTAssertEqual(PVMotion.coverStyle(selfAnimated: false, reduceMotion: reduced), .fade)
        XCTAssertNil(PVMotion.movement(PVMotion.standard, reduceMotion: reduced))
    }

    func test_AC_162_parallaxAndHeaderStayStill() {
        XCTAssertEqual(
            PVMotion.scrollEffect(isIdentity: false, scale: 0.94, opacity: 0.9, reduceMotion: true),
            PVScrollEffect(scale: 1, opacity: 1)
        )
        XCTAssertEqual(
            PVMotion.scrollEffect(isIdentity: false, scale: 1.35, opacity: 0.92, reduceMotion: true),
            PVScrollEffect(scale: 1, opacity: 1)
        )
    }

    func test_AC_163_viewerOpensAndClosesByFade() {
        let tile = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(
            ViewerZoomPlan.openStyle(hasHeroImage: true, hasSourceFrame: true, reduceMotion: true),
            .fade
        )
        XCTAssertEqual(
            ViewerZoomPlan.closeStyle(route: .reduce(to: tile), hasHeroImage: true, reduceMotion: true),
            .fade
        )
        XCTAssertEqual(
            ViewerZoomPlan.dragTransform(translation: CGSize(width: 0, height: 150), reduceMotion: true).scale,
            1
        )
        // The short drag that does not close goes back in place without a spring.
        XCTAssertNil(PVMotion.movement(.snappy, reduceMotion: true))
    }

    func test_AC_164_zoomAndFilmstripAreImmediate() {
        XCTAssertNil(PVMotion.movement(PVMotion.snappy, reduceMotion: true))
    }

    @MainActor
    func test_AC_165_densityChangesWithoutMotionAndPersists() throws {
        let name = "MotionGateTests.\(UUID().uuidString)"
        suiteName = name
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))

        let store = AppSettingsStore(defaults: defaults)
        store.tilesPerRow = 5
        XCTAssertEqual(store.tilesPerRow, 5)
        store.tilesPerRow = 4
        XCTAssertEqual(store.tilesPerRow, 4)

        let relaunched = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(relaunched.tilesPerRow, 4)
        relaunched.tilesPerRow = 9
        XCTAssertEqual(relaunched.tilesPerRow, 7)
    }

    func test_AC_166_memoryFadesInAndOut() {
        XCTAssertEqual(PVMotion.coverStyle(selfAnimated: false, reduceMotion: true), .fade)
        XCTAssertEqual(MemoryPlaybackMotion.pageChange(reduceMotion: true), .fade)
        XCTAssertEqual(PVMotion.offset(24, reduceMotion: true), 0)
        XCTAssertNil(PVMotion.movement(PVMotion.standard, reduceMotion: true))
    }

    func test_AC_167_controlsNeitherScaleNorBounce() {
        XCTAssertEqual(PVMotion.scale(0.97, reduceMotion: true), 1)
        XCTAssertEqual(PVMotion.scale(0.96, reduceMotion: true), 1)
        XCTAssertTrue(PVMotion.symbolEffectsRemoved(reduceMotion: true))
        XCTAssertEqual(PVMotion.contentChange(.symbolEffect(.replace), reduceMotion: true), .opacity)
        XCTAssertEqual(PVMotion.contentChange(.numericText(), reduceMotion: true), .opacity)
        // The four insertion transitions of the app all become a fade.
        let appearances: [PVTransition] = [
            .opacityAndMove(.bottom), .opacityAndMove(.top), .opacityAndScale(0.7), .opacityAndScale(0.92),
        ]
        for transition in appearances {
            XCTAssertEqual(PVMotion.appearance(transition, reduceMotion: true), .fade)
        }
    }

    func test_AC_168_shimmerStaysStill() {
        XCTAssertNil(PVMotion.shimmerLoop(duration: 1.5, reduceMotion: true))
        XCTAssertNil(PVMotion.shimmerLoop(duration: 1.1, reduceMotion: true))
        XCTAssertFalse(PVMotion.shimmerVisible(reduceMotion: true))
    }

    func test_AC_169_offModeUnchanged() {
        XCTAssertEqual(PVMotion.movement(PVMotion.snappy, reduceMotion: false), PVMotion.snappy)
        XCTAssertEqual(PVMotion.fading(PVMotion.standard, reduceMotion: false), PVMotion.standard)
        XCTAssertEqual(PVMotion.appearance(.opacityAndScale(0.7), reduceMotion: false), .opacityAndScale(0.7))
        XCTAssertEqual(
            PVMotion.scrollEffect(isIdentity: false, scale: 1.35, opacity: 0.92, reduceMotion: false),
            PVScrollEffect(scale: 1.35, opacity: 0.92)
        )
        XCTAssertEqual(PVMotion.contentChange(.numericText(), reduceMotion: false), .numericText())
        XCTAssertTrue(PVMotion.shimmerVisible(reduceMotion: false))
        XCTAssertEqual(PVMotion.scale(0.97, reduceMotion: false), 0.97)
        XCTAssertEqual(PVMotion.offset(24, reduceMotion: false), 24)
        XCTAssertEqual(
            ViewerZoomPlan.openStyle(hasHeroImage: true, hasSourceFrame: true, reduceMotion: false),
            .zoom
        )
        XCTAssertEqual(PVMotion.coverStyle(selfAnimated: false, reduceMotion: false), .system)
        XCTAssertEqual(MemoryPlaybackMotion.pageChange(reduceMotion: false), .slide)
    }

    func test_AC_170_followsTheSettingWithoutRelaunch() {
        XCTAssertFalse(PVMotion.isReduced(system: false, testSwitch: false))
        XCTAssertTrue(PVMotion.isReduced(system: true, testSwitch: false))
        XCTAssertFalse(PVMotion.isReduced(system: false, testSwitch: false))
    }

    func test_AC_171_everyFullScreenCoverFades() {
        XCTAssertEqual(PVMotion.coverStyle(selfAnimated: false, reduceMotion: true), .fade)
    }
}
