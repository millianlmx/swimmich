import XCTest
@testable import ImmichSwiftUI

/// Deterministic state-machine tests — the ticking loop is view-owned
/// (`.task(id:)` in SlideshowView), so no Timer and no AVFoundation here.
@MainActor
final class SlideshowViewModelTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettingsStore!

    /// Every case gets its own defaults suite. The view model now reads its
    /// speed, look, order and repeat flag from the store and writes speed/look
    /// back, so a shared suite would leak one case's speed into the next — and
    /// `UserDefaults.standard` would leak one *run* into the next.
    override func setUp() {
        super.setUp()
        suiteName = "SlideshowViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        super.tearDown()
    }

    private func makeViewModel(_ assets: [AssetReactItem], startIndex: Int = 0) -> SlideshowViewModel {
        SlideshowViewModel(assets: assets, startIndex: startIndex, appSettings: settings)
    }

    private func makeAsset(id: String, video: Bool = false, livePhoto: Bool = false) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: !video, thumbhash: nil,
            createdAt: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            localOffsetHours: 0, duration: video ? 12 : nil, livePhotoVideoId: livePhoto ? "pair-\(id)" : nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    // MARK: - Init

    func test_init_clampsStartIndex() {
        let assets = [makeAsset(id: "a"), makeAsset(id: "b"), makeAsset(id: "c")]
        let vm = makeViewModel(assets, startIndex: 7)
        XCTAssertEqual(vm.currentIndex, 2)
        XCTAssertEqual(vm.currentAsset?.id, "c")

        let empty = makeViewModel([], startIndex: 0)
        XCTAssertEqual(empty.currentIndex, 0)
        XCTAssertNil(empty.currentAsset)
    }

    func test_init_defaultNotPlaying_threeSeconds() {
        let vm = makeViewModel([makeAsset(id: "a")])
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.speed, .threeSeconds)
        XCTAssertEqual(vm.speed.rawValue, 3)
    }

    func test_init_identityOrder() {
        let vm = makeViewModel([makeAsset(id: "a"), makeAsset(id: "b"), makeAsset(id: "c")])
        XCTAssertEqual(vm.order, [0, 1, 2])
    }

    // MARK: - Advance / wrap

    func test_advance_wrapsAround() {
        let vm = makeViewModel([makeAsset(id: "a"), makeAsset(id: "b"), makeAsset(id: "c")])
        vm.start()
        vm.advance()
        XCTAssertEqual(vm.currentIndex, 1)
        vm.advance()
        XCTAssertEqual(vm.currentIndex, 2)
        vm.advance()
        XCTAssertEqual(vm.currentIndex, 0)
        vm.advance()
        XCTAssertEqual(vm.currentIndex, 1)
    }

    func test_advance_noop_whilePaused() {
        let vm = makeViewModel([makeAsset(id: "a"), makeAsset(id: "b")], startIndex: 1)
        vm.advance()
        XCTAssertEqual(vm.currentIndex, 1)
        vm.togglePlayPause()
        vm.advance()
        XCTAssertEqual(vm.currentIndex, 0)
    }

    func test_advance_noop_whileVideoActive() {
        let assets = [makeAsset(id: "photo"), makeAsset(id: "clip", video: true)]
        let vm = makeViewModel(assets, startIndex: 1)
        vm.start()
        vm.slideChanged()
        XCTAssertTrue(vm.isVideoActive)
        vm.advance()
        XCTAssertEqual(vm.currentIndex, 1)
    }

    // MARK: - videoEnded (B2/B3: immediate advance, idempotent, skip on failure)

    func test_videoEnded_advancesImmediately() {
        let assets = [makeAsset(id: "photo"), makeAsset(id: "clip", video: true)]
        let vm = makeViewModel(assets, startIndex: 1)
        vm.start()
        vm.slideChanged()
        XCTAssertTrue(vm.isVideoActive)
        vm.videoEnded()
        XCTAssertFalse(vm.isVideoActive)
        XCTAssertEqual(vm.currentIndex, 0)
    }

    func test_videoEnded_noopWhenPaused() {
        let assets = [makeAsset(id: "photo"), makeAsset(id: "clip", video: true)]
        let vm = makeViewModel(assets, startIndex: 1)
        vm.slideChanged()
        XCTAssertTrue(vm.isVideoActive)
        vm.videoEnded()
        XCTAssertFalse(vm.isVideoActive)
        XCTAssertEqual(vm.currentIndex, 1)
    }

    func test_videoEnded_idempotent() {
        let assets = [makeAsset(id: "photo"), makeAsset(id: "clip", video: true)]
        let vm = makeViewModel(assets, startIndex: 1)
        vm.start()
        vm.slideChanged()
        vm.videoEnded()
        vm.videoEnded()
        XCTAssertEqual(vm.currentIndex, 0)
    }

    func test_videoEnded_noopOnStillSlide() {
        let vm = makeViewModel([makeAsset(id: "a"), makeAsset(id: "b")], startIndex: 0)
        vm.start()
        vm.videoEnded()
        XCTAssertEqual(vm.currentIndex, 0)
    }

    func test_slideChanged_clearsVideoActiveOnStill() {
        let assets = [makeAsset(id: "clip", video: true), makeAsset(id: "photo")]
        let vm = makeViewModel(assets, startIndex: 0)
        vm.start()
        vm.slideChanged()
        XCTAssertTrue(vm.isVideoActive)
        vm.next()
        XCTAssertEqual(vm.currentIndex, 1)
        vm.slideChanged()
        XCTAssertFalse(vm.isVideoActive)
    }

    // MARK: - Live Photos (F4) + motion detection

    func test_hasPlayableMotion() {
        XCTAssertTrue(makeAsset(id: "v", video: true).hasPlayableMotion)
        XCTAssertFalse(makeAsset(id: "p").hasPlayableMotion)
        XCTAssertTrue(makeAsset(id: "l", livePhoto: true).hasPlayableMotion)
    }

    func test_slideChanged_armsLivePhoto() {
        let assets = [makeAsset(id: "l", livePhoto: true), makeAsset(id: "p")]
        let vm = makeViewModel(assets, startIndex: 0)
        vm.start()
        vm.slideChanged()
        XCTAssertTrue(vm.isVideoActive)
    }

    // MARK: - Manual navigation (allowed while paused)

    func test_next_previous_wrapWhilePaused() {
        let vm = makeViewModel([makeAsset(id: "a"), makeAsset(id: "b"), makeAsset(id: "c")])
        vm.previous()
        XCTAssertEqual(vm.currentIndex, 2)
        vm.next()
        XCTAssertEqual(vm.currentIndex, 0)
    }

    func test_singleAsset_neverLeavesZero() {
        let vm = makeViewModel([makeAsset(id: "only")])
        vm.start()
        vm.advance()
        XCTAssertEqual(vm.currentIndex, 0)
        vm.next()
        XCTAssertEqual(vm.currentIndex, 0)
        vm.previous()
        XCTAssertEqual(vm.currentIndex, 0)
    }

    // MARK: - Transport + speed + transition

    func test_startStopToggle() {
        let vm = makeViewModel([makeAsset(id: "a")])
        vm.start()
        XCTAssertTrue(vm.isPlaying)
        vm.stop()
        XCTAssertFalse(vm.isPlaying)
        vm.togglePlayPause()
        XCTAssertTrue(vm.isPlaying)
        vm.togglePlayPause()
        XCTAssertFalse(vm.isPlaying)
    }

    func test_speedChange() {
        let vm = makeViewModel([makeAsset(id: "a")])
        XCTAssertEqual(vm.speed, .threeSeconds)
        vm.speed = .tenSeconds
        XCTAssertEqual(vm.speed, .tenSeconds)
        XCTAssertEqual(SlideshowViewModel.SlideshowSpeed.allCases.count, 4)
    }

    func test_transition_defaultDissolve() {
        let vm = makeViewModel([makeAsset(id: "a")])
        XCTAssertEqual(vm.transition, .dissolve)
    }

    func test_goTo_clamps() {
        let vm = makeViewModel([makeAsset(id: "a"), makeAsset(id: "b")])
        vm.goTo(index: 5)
        XCTAssertEqual(vm.currentIndex, 1)
    }

    // MARK: - Shuffle (F5)

    func test_shuffle_coversAllIndices() {
        let assets = (0..<10).map { makeAsset(id: "\($0)") }
        let vm = makeViewModel(assets)
        vm.shuffle()
        XCTAssertEqual(Set(vm.order), Set(0..<10))
        XCTAssertEqual(vm.count, 10)
    }

    func test_shuffle_preservesCurrentAsset() {
        let assets = [makeAsset(id: "a"), makeAsset(id: "b"), makeAsset(id: "c"), makeAsset(id: "d")]
        let vm = makeViewModel(assets, startIndex: 2)
        let currentID = vm.currentAsset?.id
        vm.shuffle()
        XCTAssertEqual(vm.currentAsset?.id, currentID)
    }

    // MARK: - Screen stays on (L-29, AC-58)

    @MainActor
    private final class FakeIdleTimer: IdleTimerControlling {
        var isIdleTimerDisabled: Bool
        init(_ initial: Bool = false) { isIdleTimerDisabled = initial }
    }

    private func makeViewModel(idleTimer: FakeIdleTimer) -> SlideshowViewModel {
        SlideshowViewModel(
            assets: [makeAsset(id: "a"), makeAsset(id: "b")], startIndex: 0,
            appSettings: settings, idleTimer: idleTimer
        )
    }

    func test_AC_58_showingTheSlideshowKeepsTheScreenAwake() {
        let timer = FakeIdleTimer()
        let vm = makeViewModel(idleTimer: timer)
        XCTAssertFalse(timer.isIdleTimerDisabled, "building the model changes nothing")

        vm.keepScreenAwake()

        XCTAssertTrue(timer.isIdleTimerDisabled)
    }

    func test_AC_58_1_pauseKeepsAwakeCloseRestoresFalse() {
        let timer = FakeIdleTimer()
        let vm = makeViewModel(idleTimer: timer)
        vm.keepScreenAwake()
        vm.start()
        vm.advance()
        vm.stop()
        vm.togglePlayPause()
        vm.togglePlayPause()
        XCTAssertTrue(timer.isIdleTimerDisabled, "playing, paused or moving on: still awake")

        vm.releaseScreen()

        XCTAssertFalse(timer.isIdleTimerDisabled)
    }

    func test_AC_58_1_closeRestoresAPreviouslyDisabledTimer() {
        let timer = FakeIdleTimer(true)
        let vm = makeViewModel(idleTimer: timer)
        vm.keepScreenAwake()
        vm.releaseScreen()
        XCTAssertTrue(timer.isIdleTimerDisabled, "the value found before the show comes back, not false")
    }

    func test_AC_58_1_releaseWithoutHoldAndDoubleCallsAreHarmless() {
        let timer = FakeIdleTimer(true)
        let vm = makeViewModel(idleTimer: timer)
        vm.releaseScreen()
        XCTAssertTrue(timer.isIdleTimerDisabled, "no hold, nothing to give back")

        timer.isIdleTimerDisabled = false
        vm.keepScreenAwake()
        vm.keepScreenAwake()
        vm.releaseScreen()
        vm.releaseScreen()
        XCTAssertFalse(timer.isIdleTimerDisabled, "the second keep did not record `true` as the value to restore")
    }

    func test_shuffle_singleAssetNoop() {
        let vm = makeViewModel([makeAsset(id: "only")])
        vm.shuffle()
        XCTAssertEqual(vm.order, [0])
    }

    // MARK: - Preferences (settings-parity, G22)

    func test_init_seedsSpeedAndLookFromTheStore() {
        settings.slideshowSpeed = 5
        settings.slideshowLook = "slide"

        let vm = makeViewModel([makeAsset(id: "a")])

        XCTAssertEqual(vm.speed, .fiveSeconds)
        XCTAssertEqual(vm.transition, .slide)
    }

    /// The show's own menu and the Preferences screen write the same value:
    /// the picker in the viewer follows a change made in the other screen, and
    /// what the viewer picks is what the next launch reads.
    func test_speedAndLook_changesWriteTheStore() {
        let vm = makeViewModel([makeAsset(id: "a")])

        vm.speed = .tenSeconds
        vm.transition = .kenBurns

        XCTAssertEqual(settings.slideshowSpeed, 10)
        XCTAssertEqual(settings.slideshowLook, "kenBurns")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).slideshowSpeed, 10)
    }

    func test_init_reverseOrder_runsBackwardsFromTheCurrentSlide() {
        settings.slideshowReverse = true
        let assets = [makeAsset(id: "a"), makeAsset(id: "b"), makeAsset(id: "c")]

        let vm = makeViewModel(assets, startIndex: 2)

        XCTAssertEqual(vm.currentAsset?.id, "c", "the show opens on the photo on screen")
        vm.start()
        vm.advance()
        XCTAssertEqual(vm.currentAsset?.id, "b", "and then walks the library backwards")
    }

    func test_repeatOff_stopsAtTheLastSlide() {
        settings.slideshowRepeat = false
        let vm = makeViewModel([makeAsset(id: "a"), makeAsset(id: "b")], startIndex: 1)
        vm.start()

        vm.advance()

        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.currentIndex, 1)
    }
}

// MARK: - Pure helpers (no @MainActor needed)

final class SlideshowHelpersTests: XCTestCase {

    // MARK: SlideshowDirection

    func test_direction_forwardNormal() {
        XCTAssertTrue(SlideshowDirection.isForward(from: 0, to: 1, count: 5))
        XCTAssertFalse(SlideshowDirection.isForward(from: 1, to: 0, count: 5))
    }

    func test_direction_wrap() {
        XCTAssertTrue(SlideshowDirection.isForward(from: 4, to: 0, count: 5))
        XCTAssertFalse(SlideshowDirection.isForward(from: 0, to: 4, count: 5))
    }

    func test_direction_singleAsset() {
        XCTAssertTrue(SlideshowDirection.isForward(from: 0, to: 0, count: 1))
    }

    // MARK: KenBurnsPhase

    func test_kenBurns_identityWhenReduceMotion() {
        let phase = KenBurnsPhase.progress(elapsed: 5, reduceMotion: true)
        XCTAssertEqual(phase.scale, 1.0)
        XCTAssertEqual(phase.offset, .zero)
    }

    func test_kenBurns_scaleWithinBounds() {
        for t in stride(from: 0.0, through: 64.0, by: 0.25) {
            let scale = KenBurnsPhase.progress(elapsed: t, reduceMotion: false).scale
            XCTAssertGreaterThanOrEqual(scale, 1.0)
            XCTAssertLessThanOrEqual(scale, 1.06 + 0.0001)
        }
    }

    func test_kenBurns_periodic() {
        let a = KenBurnsPhase.progress(elapsed: 2, reduceMotion: false)
        let b = KenBurnsPhase.progress(elapsed: 34, reduceMotion: false)
        XCTAssertEqual(a.scale, b.scale, accuracy: 0.001)
    }

    func test_kenBurns_peakAtMidCycle() {
        let peak = KenBurnsPhase.progress(elapsed: 16, reduceMotion: false)
        XCTAssertEqual(peak.scale, 1.06, accuracy: 0.001)
    }
}
