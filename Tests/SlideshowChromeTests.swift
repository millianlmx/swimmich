import XCTest
@testable import ImmichSwiftUI

/// AC-34.10 (L-19): with VoiceOver on, the slideshow keeps its controls in the
/// accessibility tree — no auto-hide and no tap-to-hide — and without VoiceOver
/// the chrome still hides after a few seconds of playback.
@MainActor
final class SlideshowChromeTests: XCTestCase {

    func test_AC_34_10_voiceOverKeepsControlsWhilePlaying() {
        // VoiceOver: never auto-hidden, and shown even when hidden was requested.
        XCTAssertFalse(SlideshowView.shouldAutoHide(isPlaying: true, controlsShown: true, voiceOverEnabled: true))
        XCTAssertTrue(SlideshowView.controlsShown(requested: false, voiceOverEnabled: true))

        // No VoiceOver: the auto-hide applies to a playing show with visible chrome only.
        XCTAssertTrue(SlideshowView.shouldAutoHide(isPlaying: true, controlsShown: true, voiceOverEnabled: false))
        XCTAssertFalse(SlideshowView.shouldAutoHide(isPlaying: false, controlsShown: true, voiceOverEnabled: false))
        XCTAssertFalse(SlideshowView.shouldAutoHide(isPlaying: true, controlsShown: false, voiceOverEnabled: false))
        XCTAssertTrue(SlideshowView.controlsShown(requested: true, voiceOverEnabled: false))
        XCTAssertFalse(SlideshowView.controlsShown(requested: false, voiceOverEnabled: false))
    }
}
