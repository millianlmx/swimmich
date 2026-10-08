import XCTest
@testable import ImmichSwiftUI

@MainActor
final class VideoPlaybackViewModelTests: XCTestCase {

    private let baseURL = URL(string: "https://example.com")!

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: AppSettingsStore!

    /// A dedicated suite per case: the player reads its auto-play, loop and
    /// source switches from the store, and `UserDefaults.standard` would let a
    /// real app run on the same simulator decide what these tests observe.
    override func setUp() {
        super.setUp()
        suiteName = "VideoPlaybackViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = AppSettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        super.tearDown()
    }

    private func makeVideoAsset(id: String = "v1", livePair: String? = nil) -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: false, thumbhash: nil,
            createdAt: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            localOffsetHours: 0, duration: 12, livePhotoVideoId: livePair, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func makeLivePhotoStill(id: String = "still-1", livePair: String? = "vid-9") -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: "2024-07-01T00:00:00.000Z", fileCreatedAt: "2024-07-01T00:00:00.000Z",
            localOffsetHours: 0, duration: nil, livePhotoVideoId: livePair, projectionType: nil,
            city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    // MARK: - Prepare / URL

    func test_prepare_uses_videoPlaybackEndpoint_and_PassesToken() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)

        await vm.prepare(asset: makeVideoAsset(id: "v9"), baseURL: baseURL, token: "tok-123")

        XCTAssertEqual(mock.preparedURL?.path, "/api/assets/v9/video/playback")
        XCTAssertEqual(mock.preparedToken, "tok-123")
        XCTAssertEqual(mock.preparedURL?.host, "example.com")
    }

    /// A downloaded video plays from disk (issue #18): the whole point of the
    /// offline cache is that this page works with the server unreachable.
    func test_prepare_withLocalFile_playsFromDiskAndSendsNoToken() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        let local = URL(fileURLWithPath: "/tmp/offline/v9.mp4")

        await vm.prepare(asset: makeVideoAsset(id: "v9"), baseURL: baseURL, token: "tok-123", localFileURL: local)

        XCTAssertEqual(mock.preparedURL, local, "a cached video must be read from its file, not streamed")
        XCTAssertNil(mock.preparedToken, "a local file needs no bearer token")
        XCTAssertEqual(vm.status, .playing)
    }

    func test_prepare_autoplays_afterReady() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)

        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        XCTAssertEqual(vm.status, .playing)
        XCTAssertEqual(mock.playCount, 1)
        XCTAssertEqual(vm.duration, 30)
    }

    func test_prepare_failure_setsFailedState() async {
        let mock = MockVideoPlaybackEngine()
        mock.prepareError = URLError(.notConnectedToInternet)
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)

        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        guard case .failed(let message) = vm.status else {
            return XCTFail("expected failed, got \(vm.status)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - Play / Pause / Seek

    func test_togglePlayPause_transitions() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        vm.pause()
        XCTAssertEqual(vm.status, .paused)
        XCTAssertEqual(mock.pauseCount, 1)

        vm.togglePlayPause()
        XCTAssertEqual(vm.status, .playing)
        XCTAssertEqual(mock.playCount, 2)
    }

    func test_seekBy_clampsToDuration() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        mock.fireTimeUpdate(10)
        vm.seek(by: 15)
        XCTAssertEqual(vm.currentTime, 25)
        XCTAssertEqual(mock.lastSeek, 25)

        vm.seek(by: 60)
        XCTAssertEqual(vm.currentTime, 30)
        XCTAssertEqual(mock.lastSeek, 30)

        vm.seek(by: -100)
        XCTAssertEqual(vm.currentTime, 0)
        XCTAssertEqual(mock.lastSeek, 0)
    }

    func test_seekTo_scrubber_position() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        vm.seek(to: 7.5)

        XCTAssertEqual(vm.currentTime, 7.5)
        XCTAssertEqual(mock.lastSeek, 7.5)
        XCTAssertEqual(vm.progress, 7.5 / 30, accuracy: 0.001)
    }

    // MARK: - End / Time / Retry

    func test_ended_setsState_and_replay_restarts() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        mock.fireEnded()

        XCTAssertEqual(vm.status, .ended)
        XCTAssertEqual(vm.currentTime, 30)

        vm.replay()
        XCTAssertEqual(vm.status, .playing)
        XCTAssertEqual(mock.lastSeek, 0)
        XCTAssertEqual(mock.playCount, 2)
    }

    func test_timeUpdate_drivesProgress() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        vm.pause()
        mock.fireTimeUpdate(15)

        XCTAssertEqual(vm.currentTime, 15)
        XCTAssertEqual(vm.progress, 0.5, accuracy: 0.001)
    }

    func test_retry_after_failure_rePrepares() async {
        let mock = MockVideoPlaybackEngine()
        mock.prepareError = URLError(.cannotConnectToHost)
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)
        guard case .failed = vm.status else {
            return XCTFail("expected failed")
        }

        vm.reset()
        XCTAssertEqual(vm.status, .idle)
        XCTAssertEqual(mock.reloadCount, 1)

        mock.prepareError = nil
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        XCTAssertEqual(vm.status, .playing)
        XCTAssertEqual(mock.playCount, 1)
    }

    func test_engineFailureHook_setsFailed() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        mock.fireFailure("stream unavailable")

        guard case .failed(let message) = vm.status else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(message, UserFacingError.genericMessage)
    }

    // MARK: - Live Photo pair (P1)

    func test_P1_livePhoto_pairUsesPairAssetID() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        let still = makeLivePhotoStill(livePair: "vid-42")

        await vm.prepareLivePhoto(asset: still, baseURL: baseURL, token: "tok-lp")

        XCTAssertEqual(vm.preparedAssetID, "vid-42")
        XCTAssertEqual(mock.preparedURL?.path, "/api/assets/vid-42/video/playback")
        XCTAssertEqual(mock.preparedToken, "tok-lp")
        XCTAssertEqual(vm.status, .playing)
    }

    func test_P1_livePhoto_prepareByID_override() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)

        await vm.prepare(assetID: "vid-7", baseURL: baseURL, token: nil)

        XCTAssertEqual(vm.preparedAssetID, "vid-7")
        XCTAssertEqual(mock.preparedURL?.path, "/api/assets/vid-7/video/playback")
    }

    func test_P1_livePhoto_missingPair_fails() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        let orphan = makeLivePhotoStill(livePair: nil)

        await vm.prepareLivePhoto(asset: orphan, baseURL: baseURL, token: nil)

        guard case .failed(let message) = vm.status else {
            return XCTFail("expected failed, got \(vm.status)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(mock.preparedURL, "engine must not prepare without a pair")
        XCTAssertEqual(mock.playCount, 0)
    }

    // MARK: - Preferences (settings-parity, G22)

    func test_prepare_streamOriginal_usesTheOriginalFileURL() async {
        settings.loadOriginalVideo = true
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)

        await vm.prepare(asset: makeVideoAsset(id: "v9"), baseURL: baseURL, token: "tok-123")

        XCTAssertEqual(mock.preparedURL?.path, "/api/assets/v9/original")
        XCTAssertEqual(mock.preparedToken, "tok-123")
    }

    func test_prepare_autoPlayOff_leavesThePageReadyWithoutPlaying() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        settings.autoPlayVideo = false

        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        XCTAssertEqual(vm.status, .ready, "prepared, waiting for a tap")
        XCTAssertEqual(mock.playCount, 0)
    }

    func test_loopVideo_restartsTheMovieInsteadOfEnding() async {
        settings.loopVideo = true
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)
        let playsAfterPrepare = mock.playCount

        mock.fireEnded()

        XCTAssertEqual(vm.status, .playing)
        XCTAssertEqual(mock.lastSeek, 0)
        XCTAssertEqual(mock.playCount, playsAfterPrepare + 1)
    }

    /// The slideshow's pages pass `false`: a looping slide never reports
    /// `.ended`, and the show would wait on that video forever.
    func test_loopOverride_false_endsEvenWhenTheSettingIsOn() async {
        settings.loopVideo = true
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings, loopsVideo: false)
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)

        mock.fireEnded()

        XCTAssertEqual(vm.status, .ended)
    }

    /// The switches describe the NEXT preparation — a movie already playing
    /// keeps the shape it was prepared with.
    func test_loopFlipAfterPrepare_doesNotChangeTheRunningMovie() async {
        let mock = MockVideoPlaybackEngine()
        let vm = VideoPlaybackViewModel(engine: mock, appSettings: settings)
        await vm.prepare(asset: makeVideoAsset(), baseURL: baseURL, token: nil)
        settings.loopVideo = true

        mock.fireEnded()

        XCTAssertEqual(vm.status, .ended)
    }
}