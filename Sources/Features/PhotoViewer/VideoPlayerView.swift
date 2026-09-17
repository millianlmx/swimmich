import AVFoundation
import SwiftUI

/// UIKit host that keeps an `AVPlayerLayer` pinned to its bounds (a plain
/// `UIViewRepresentable` returning the player layer directly has no layout
/// pass, so the video would not track the container on rotation/resize).
final class VideoPlayerLayerContainer: UIView {
    private let playerLayer: AVPlayerLayer

    init(playerLayer: AVPlayerLayer, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        playerLayer.videoGravity = videoGravity
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// SwiftUI wrapper over the AVPlayerLayer container.
struct VideoPlayerLayerView: UIViewRepresentable {
    let playerLayer: AVPlayerLayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> UIView {
        VideoPlayerLayerContainer(playerLayer: playerLayer, videoGravity: videoGravity)
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// One photo-viewer page for a video asset: full-bleed AVPlayer layer +
/// Photos-grade controls (play/pause, ±15 s, scrubber, replay, retry).
///
/// `controlsVisible` follows the viewer chrome so a single tap hides both the
/// chrome and the transport controls together.
struct VideoPlayerView: View {
    let asset: AssetReactItem
    let baseURL: URL
    let token: String?
    /// Playback id override — set for Live Photo pairs, where the playable
    /// video is a different asset than the still page (`livePhotoVideoId`).
    /// `nil` plays `asset.id` itself.
    var assetID: String? = nil
    /// Offline copy (issue #18): when set, playback reads this file instead of
    /// streaming the asset from the server.
    var localFileURL: URL? = nil
    var controlsVisible: Bool = true
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var onSingleTap: () -> Void = {}
    /// Fired when playback reaches the end — lets the viewer swap back to
    /// the Live Photo still (Photos behavior).
    var onPlaybackEnded: (() -> Void)? = nil
    /// External pause channel (slideshow): pauses/resumes the player without
    /// the transport controls. Resume only revives a `.paused` player — an
    /// `.ended` player is left alone (the slideshow will advance past it).
    var isPaused: Bool = false
    /// Broadcasts every playback status change — the slideshow advances on
    /// `.ended` and skips on `.failed`.
    var onStatusChange: ((VideoPlaybackStatus) -> Void)? = nil
    /// Overrides the "Loop" preference for this page. The slideshow passes
    /// `false`: a looping video never reports `.ended`, and its ticker waits on
    /// exactly that to move to the next slide.
    var loopsVideo: Bool? = nil

    @State private var vm: VideoPlaybackViewModel
    @State private var playerLayer: AVPlayerLayer?

    /// Explicit init because the view model is seeded from the store, and the
    /// environment is not readable from a property initializer. Every parameter
    /// keeps its default, so no call site changes; the store defaults to the
    /// process-wide instance the root injects (same pattern as `PhotoViewer`'s
    /// `client` / `downloads`).
    init(
        asset: AssetReactItem,
        baseURL: URL,
        token: String?,
        assetID: String? = nil,
        localFileURL: URL? = nil,
        controlsVisible: Bool = true,
        videoGravity: AVLayerVideoGravity = .resizeAspect,
        onSingleTap: @escaping () -> Void = {},
        onPlaybackEnded: (() -> Void)? = nil,
        isPaused: Bool = false,
        onStatusChange: ((VideoPlaybackStatus) -> Void)? = nil,
        loopsVideo: Bool? = nil,
        appSettings: AppSettingsStore = .shared
    ) {
        self.asset = asset
        self.baseURL = baseURL
        self.token = token
        self.assetID = assetID
        self.localFileURL = localFileURL
        self.controlsVisible = controlsVisible
        self.videoGravity = videoGravity
        self.onSingleTap = onSingleTap
        self.onPlaybackEnded = onPlaybackEnded
        self.isPaused = isPaused
        self.onStatusChange = onStatusChange
        self.loopsVideo = loopsVideo
        _vm = State(initialValue: VideoPlaybackViewModel(appSettings: appSettings, loopsVideo: loopsVideo))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let playerLayer {
                VideoPlayerLayerView(playerLayer: playerLayer, videoGravity: videoGravity)
                    .ignoresSafeArea()
            }

            if controlsVisible {
                transportControls
            }

            if case .failed = vm.status {
                errorOverlay
            }

            if vm.status == .preparing {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white) // DS-exempt: loading state on black
            }
        }
        .onAppear {
            if playerLayer == nil {
                playerLayer = vm.engine.makePlayerLayer()
            }
            Task { await vm.prepare(assetID: assetID ?? asset.id, baseURL: baseURL, token: token, localFileURL: localFileURL) }
        }
        .onDisappear {
            vm.pause()
        }
        .onChange(of: vm.status) { _, newStatus in
            onStatusChange?(newStatus)
            if case .ended = newStatus {
                onPlaybackEnded?()
            }
            // External pause arrived before the player became ready/playing:
            // suppress the auto-play so the slide respects the slideshow state.
            if isPaused, newStatus == .ready || newStatus == .playing {
                vm.pause()
            }
        }
        .onChange(of: isPaused) { _, paused in
            if paused {
                vm.pause()
            } else if vm.status == .paused {
                vm.play()
            }
        }
        .onTapGesture(perform: onSingleTap)
        .contentShape(Rectangle())
    }

    // MARK: - Transport

    private var transportControls: some View {
        VStack(spacing: PVSpacing.s12) {
            if vm.status == .ended {
                Button {
                    vm.replay()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 56)) // DS-exempt: immersive replay glyph
                        .foregroundStyle(Color.white)
                        .shadow(color: .black.opacity(0.4), radius: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Replay")
            } else {
                HStack(spacing: PVSpacing.s32) {
                    seekButton(symbol: "gobackward.15", delta: -15, label: "Back 15 seconds")
                    playPauseButton
                    seekButton(symbol: "goforward.15", delta: 15, label: "Forward 15 seconds")
                }
            }

            Slider(
                value: Binding(
                    get: { vm.currentTime },
                    set: { vm.seek(to: $0) }
                ),
                in: 0...max(vm.duration, 1)
            )
            .tint(.white) // DS-exempt: transport accent on black
            .padding(.horizontal, PVSpacing.s16)

            HStack {
                Text(Self.format(vm.currentTime))
                Spacer()
                Text(Self.format(vm.duration))
            }
            .font(.pvCaption)
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .padding(.horizontal, PVSpacing.s16)
        }
        .padding(.bottom, PVSpacing.s12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    private var playPauseButton: some View {
        Button {
            vm.togglePlayPause()
        } label: {
            Image(systemName: vm.status == .playing ? "pause.fill" : "play.fill")
                .font(.pvTitle)
                .foregroundStyle(Color.white)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(vm.status == .playing ? "Pause" : "Play")
    }

    private func seekButton(symbol: String, delta: Double, label: LocalizedStringKey) -> some View {
        Button {
            vm.seek(by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.pvHeadline)
                .foregroundStyle(Color.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Failure

    private var errorOverlay: some View {
        VStack(spacing: PVSpacing.s12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.pvH2)
                .foregroundStyle(Color.white)
            if let message = vm.errorMessage {
                Text(message)
                    .font(.pvSubhead)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PVSpacing.s24)
            }
            Button {
                vm.reset()
                Task { await vm.prepare(assetID: assetID ?? asset.id, baseURL: baseURL, token: token, localFileURL: localFileURL) }
            } label: {
                Text("Retry")
                    .font(.pvSubhead.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, PVSpacing.s16)
                    .padding(.vertical, PVSpacing.s8)
                    .glassEffect(.regular.tint(.black.opacity(0.6)), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    /// mm:ss (0:ss under a minute) — or h:mm:ss for video playback timer.
    static func format(_ seconds: Double) -> String {
        AssetThumbnailCell.formattedDuration(Int(seconds.rounded()), includeSecondsIfHours: true)
    }
}