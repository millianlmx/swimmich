import SwiftUI

/// Fullscreen autoplay slideshow (Photos-style) — presented as an INTERNAL
/// overlay of the photo viewer (never a new presentation layer: cover-inside-
/// cover is a known teardown crash, memory 2026-08-05).
///
/// The ticking loop lives HERE (view-owned), not in the VM: a `.task(id:)`
/// loop re-arms whenever speed/play/video-active state changes and calls
/// `vm.advance()` only when `vm.isPlaying && !vm.isVideoActive`, so the VM
/// stays a pure, unit-testable state machine. Videos and Live Photos play
/// inline via the existing `VideoPlayerView`; the ticker suspends during
/// playback and resumes the instant the video ends or fails.
///
/// Chrome is Liquid Glass, auto-hides after a few seconds while playing, and
/// reappears on tap (single tap toggles it).
struct SlideshowView: View {
    let vm: SlideshowViewModel
    let baseURL: URL
    let token: String?
    var onClose: () -> Void = {}
    /// Reads each photo's pixel size for its zoom ceiling when the item has none.
    var client: (any ImmichClient)? = nil

    @PVReduceMotion private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// VoiceOver keeps the chrome on screen: Close, Play/Pause, Shuffle, Previous,
    /// Next, speed and transition would otherwise leave the accessibility tree
    /// 3 s after playback starts, with only an unlabelled tap to bring them back.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    /// Offline cache mirror (issue #18): a slideshow over downloaded assets must
    /// keep running with no server, so every slide gets its local copy.
    @Environment(OfflineAssetIndex.self) private var offline: OfflineAssetIndex?

    @State private var showControls = true
    @State private var directionForward = true

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
                .onTapGesture(perform: toggleControls)

            if let asset = vm.currentAsset {
                slideContent(asset)
                    .ignoresSafeArea()
                    .transition(slideTransition)
                    .id(asset.id)
                    .animation(transitionAnimation, value: vm.currentIndex)
            }
        }
        .overlay(alignment: .top) {
            if Self.controlsShown(requested: showControls, voiceOverEnabled: voiceOverEnabled) { topBar }
        }
        .overlay(alignment: .bottom) {
            if Self.controlsShown(requested: showControls, voiceOverEnabled: voiceOverEnabled) { chromeFooter }
        }
        .pvFullscreenChromeTextCap()
        .statusBarHidden(true)
        .task(id: tickerKey) { await runTicker() }
        .task(id: autoHideKey) { await autoHideControls() }
        .onAppear {
            vm.slideChanged()
            if !Self.autoplayOff { vm.start() }
        }
        .onChange(of: vm.currentIndex) { old, new in
            directionForward = SlideshowDirection.isForward(from: old, to: new, count: vm.count)
            vm.slideChanged()
        }
    }

    // MARK: - Slide content

    @ViewBuilder
    private func slideContent(_ asset: AssetReactItem) -> some View {
        if asset.isVideo {
            VideoPlayerView(
                asset: asset,
                baseURL: baseURL,
                token: token,
                localFileURL: offline?.localURL(for: asset.id),
                controlsVisible: false,
                onSingleTap: toggleControls,
                isPaused: !vm.isPlaying,
                onStatusChange: handleStatusChange,
                // A slide must end: the "Loop" preference is a viewer setting,
                // and obeying it here would leave the show parked on the video.
                loopsVideo: false
            )
        } else if let pairID = asset.livePhotoVideoId, !pairID.isEmpty {
            VideoPlayerView(
                asset: asset,
                baseURL: baseURL,
                token: token,
                assetID: pairID,
                localFileURL: offline?.localURL(for: pairID),
                controlsVisible: false,
                onSingleTap: toggleControls,
                isPaused: !vm.isPlaying,
                onStatusChange: handleStatusChange,
                loopsVideo: false
            )
        } else if vm.transition == .kenBurns {
            KenBurnsImageView(
                asset: asset,
                baseURL: baseURL,
                token: token,
                localFileURL: offline?.localURL(for: asset.id),
                onSingleTap: toggleControls
            )
        } else {
            ZoomableImageView(
                asset: asset,
                baseURL: baseURL,
                token: token,
                onSingleTap: toggleControls,
                localFileURL: offline?.localURL(for: asset.id),
                client: client
            )
        }
    }

    private func handleStatusChange(_ status: VideoPlaybackStatus) {
        switch status {
        case .ended, .failed:
            vm.videoEnded()
        default:
            break
        }
    }

    // MARK: - Ticker (view-owned)

    /// `repeats` is part of the key so flipping "Repeat" while the show sits on
    /// its last slide re-arms the loop instead of leaving it stopped.
    private var tickerKey: String { "\(vm.speed.rawValue)-\(vm.isPlaying)-\(vm.isVideoActive)-\(vm.repeats)" }

    private func runTicker() async {
        guard vm.isPlaying, !vm.isVideoActive else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(vm.speed.rawValue))
            guard vm.isPlaying, !vm.isVideoActive else { return }
            vm.advance()
        }
    }

    // MARK: - Auto-hide chrome

    private var autoHideKey: String { "\(showControls)-\(vm.isPlaying)-\(vm.isVideoActive)-\(voiceOverEnabled)" }

    /// The chrome is on screen when requested, and always under VoiceOver.
    static func controlsShown(requested: Bool, voiceOverEnabled: Bool) -> Bool {
        requested || voiceOverEnabled
    }

    /// The 3 s auto-hide only runs for a playing show with visible chrome and no VoiceOver.
    static func shouldAutoHide(isPlaying: Bool, controlsShown: Bool, voiceOverEnabled: Bool) -> Bool {
        isPlaying && controlsShown && !voiceOverEnabled
    }

    private func autoHideControls() async {
        guard Self.shouldAutoHide(isPlaying: vm.isPlaying, controlsShown: showControls, voiceOverEnabled: voiceOverEnabled) else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled,
              Self.shouldAutoHide(isPlaying: vm.isPlaying, controlsShown: showControls, voiceOverEnabled: voiceOverEnabled)
        else { return }
        withAnimation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion)) {
            showControls = false
        }
    }

    private func toggleControls() {
        guard !voiceOverEnabled else { return }
        withAnimation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion)) {
            showControls.toggle()
        }
    }

    // MARK: - Transition

    private var slideTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        switch vm.transition {
        case .dissolve, .kenBurns:
            return .opacity
        case .slide:
            let insertEdge: Edge = directionForward ? .trailing : .leading
            let removeEdge: Edge = directionForward ? .leading : .trailing
            return .asymmetric(
                insertion: .move(edge: insertEdge).combined(with: .opacity),
                removal: .move(edge: removeEdge).combined(with: .opacity)
            )
        }
    }

    private var transitionAnimation: Animation {
        switch vm.transition {
        case .dissolve, .kenBurns:
            return PVMotion.fading(.easeInOut(duration: 0.4), reduceMotion: reduceMotion)
        case .slide:
            return PVMotion.fading(.spring(duration: 0.35, bounce: 0), reduceMotion: reduceMotion)
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: PVSpacing.s12) {
            if let asset = vm.currentAsset {
                SlideshowCounterLabel(
                    index: vm.currentIndex,
                    count: vm.count,
                    isVideo: asset.hasPlayableMotion
                )
            }

            Spacer()

            transitionMenu

            Button {
                vm.stop()
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.pvHeadline)
                    .foregroundStyle(Color.white)
                    .frame(width: 40, height: 40)
                    .pvFloating(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Slideshow")
            .accessibilityIdentifier("slideshowCloseButton")
        }
        .padding(.horizontal, PVSpacing.s16)
        .padding(.top, PVSpacing.s8)
    }

    private var chromeFooter: some View {
        VStack(spacing: PVSpacing.s8) {
            progressBar
            bottomBar
        }
        .padding(.bottom, PVSpacing.s8)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(0, geo.size.width * progress))
            }
        }
        .frame(height: 3)
        .padding(.horizontal, PVSpacing.s24)
        .accessibilityHidden(true)
    }

    private var progress: Double {
        guard vm.count > 0 else { return 0 }
        return Double(vm.currentIndex + 1) / Double(vm.count)
    }

    private var bottomBar: some View {
        GlassEffectContainer {
            HStack(spacing: PVSpacing.s4) {
                controlButton(systemName: "shuffle", label: "Shuffle", identifier: "slideshowShuffleButton") { vm.shuffle() }
                    .disabled(vm.count < 2)

                controlButton(systemName: "chevron.left", label: "Previous", identifier: "slideshowPreviousButton") { vm.previous() }
                    .disabled(vm.count < 2)

                Spacer(minLength: PVSpacing.s8)

                playPauseButton

                Spacer(minLength: PVSpacing.s8)

                controlButton(systemName: "chevron.right", label: "Next", identifier: "slideshowNextButton") { vm.next() }
                    .disabled(vm.count < 2)

                speedMenu
            }
            .padding(.horizontal, PVSpacing.s16)
            .padding(.vertical, PVSpacing.s8)
        }
    }

    private var playPauseButton: some View {
        Button {
            vm.togglePlayPause()
        } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                .font(.pvTitle)
                .foregroundStyle(Color.white)
                .frame(width: 48, height: 48)
                .pvFloating(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
        .accessibilityIdentifier("slideshowPlayPauseButton")
        .appSensoryFeedback(.selection, trigger: vm.isPlaying)
    }

    private var speedMenu: some View {
        Menu {
            Picker("Slideshow Speed", selection: Binding(get: { vm.speed }, set: { vm.speed = $0 })) {
                ForEach(SlideshowViewModel.SlideshowSpeed.allCases) { speed in
                    Text(speed.label).tag(speed)
                }
            }
        } label: {
            SlideshowSpeedLabel(text: vm.speed.label)
        }
        .accessibilityLabel("Slideshow Speed")
        .accessibilityValue(Text(verbatim: vm.speed.label))
        .accessibilityIdentifier("slideshowSpeedMenu")
    }

    private var transitionMenu: some View {
        Menu {
            Picker("Transition", selection: Binding(get: { vm.transition }, set: { vm.transition = $0 })) {
                ForEach(SlideshowViewModel.SlideshowTransitionStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.pvHeadline)
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .pvFloating(.circle)
        }
        .accessibilityLabel("Transition")
        .accessibilityIdentifier("slideshowTransitionMenu")
    }

    private func controlButton(systemName: String, label: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.pvHeadline)
                .foregroundStyle(Color.white)
                .frame(width: 40, height: 40)
                .pvFloating(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

extension SlideshowView {
    /// UI-test switch, off in production (same model as `MemoryPlaybackProbe`):
    /// `-uiTestSlideshowAutoplayOff YES` opens the show paused, so its chrome stays
    /// up (it only hides itself while playing) and a scenario can measure it.
    static let autoplayOffKey = "uiTestSlideshowAutoplayOff"
    static let autoplayOff = UserDefaults.standard.bool(forKey: autoplayOffKey)
}

/// "n of N" pill of the slideshow. `index` is zero-based. Carries its own
/// full-screen cap so it measures the same outside the slideshow.
struct SlideshowCounterLabel: View {
    let index: Int
    let count: Int
    let isVideo: Bool

    var body: some View {
        Text("\(index + 1) of \(count)")
            .font(.pvCaption.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, PVSpacing.s12)
            .padding(.vertical, PVSpacing.s4)
            .pvFloating(.pill)
            .accessibilityLabel("Slide \(index + 1) of \(count): \(isVideo ? "Video" : "Photo")")
            .accessibilityIdentifier("slideshowCounter")
            .pvFullscreenChromeTextCap()
    }
}

/// Playback-speed pill of the slideshow. The vertical padding lets the frame
/// grow with the text (it stays 40 pt at the default size: 16 + one line < 40).
struct SlideshowSpeedLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.pvCaption.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.vertical, PVSpacing.s8)
            .frame(minWidth: 44, minHeight: 40)
            .pvFloating(.pill)
            .pvFullscreenChromeTextCap()
    }
}
