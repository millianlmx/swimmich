import SwiftUI

/// The two haptics of the memories playback — the only ones it emits. The
/// "Haptic Feedback" setting silences them through `appSensoryFeedback`.
enum MemoryPlaybackFeedback {
    /// A photo change made by the user (`selectionClick` upstream).
    static let photo: SensoryFeedback = .selection
    /// A memory change made by the user (`mediumImpact` upstream).
    static let memory: SensoryFeedback = .impact(weight: .medium)
}

/// UI-test switches, off in production (same model as `ImageLoadProbe`):
/// `-uiTestMemoryPlaybackProbe YES` adds the `memoryPlaybackProbe` element that
/// reads the playback state and the haptic actually returned to SwiftUI, and
/// `-uiTestMemoryAutoplayOff YES` creates the playback with the auto-play off so
/// a scenario only moves on its own gestures.
enum MemoryPlaybackProbe {
    static let defaultsKey = "uiTestMemoryPlaybackProbe"
    static let isEnabled = UserDefaults.standard.bool(forKey: defaultsKey)
    static let autoplayOffKey = "uiTestMemoryAutoplayOff"
    static let autoplayOff = UserDefaults.standard.bool(forKey: autoplayOffKey)

    /// Names what the haptic gate returned: nil when nothing was played.
    static func label(for played: SensoryFeedback?) -> String? {
        guard let played else { return nil }
        if played == .selection { return "selection" }
        if played == .impact(weight: .medium) { return "medium" }
        return "other"
    }
}

/// How a page change that came from the model (auto-play, swipe past the last
/// photo, "Start Over", a delete) reaches the screen.
enum MemoryPlaybackMotion {
    enum PageChangeStyle: Equatable {
        case slide
        case fade
    }

    static func pageChange(reduceMotion: Bool) -> PageChangeStyle {
        reduceMotion ? .fade : .slide
    }
}

extension View {
    /// The playback's two haptics, on the two counters of the view model. `onEmit`
    /// reports what the gate returned (only the UI-test probe passes one).
    func memoryPlaybackFeedback(
        _ playback: MemoryPlaybackViewModel,
        onEmit: ((SensoryFeedback?) -> Void)?
    ) -> some View {
        appSensoryFeedback(MemoryPlaybackFeedback.photo, trigger: playback.photoFeedbackTick, onEmit: onEmit)
            .appSensoryFeedback(MemoryPlaybackFeedback.memory, trigger: playback.memoryFeedbackTick, onEmit: onEmit)
    }
}

/// Full-screen memories: a vertical pager with one page per memory and a last
/// page, the epilogue. A swipe up / down moves between memories, a swipe past the
/// last photo of a memory moves on, the auto-play crosses memories silently and
/// stops on the epilogue ("Start Over" goes back to the first memory).
///
/// State lives in `MemoryPlaybackViewModel`; this view turns user gestures into
/// its `user*` calls (which are the only ones that emit a haptic) and model
/// changes into scrolling.
struct MemoryPlaybackView: View {
    let playback: MemoryPlaybackViewModel
    let vm: MemoriesViewModel
    let baseURL: URL
    let token: String?

    @Environment(\.dismiss) private var dismiss
    @PVReduceMotion private var reduceMotion

    /// Vertical pager position, kept in step with `playback.page`.
    @State private var visiblePage: MemoryPlaybackViewModel.Page?
    /// The page the playback was on when the last vertical gesture started: a
    /// gesture that ends there moved nothing.
    @State private var scrollStartPage: MemoryPlaybackViewModel.Page?
    @State private var fadeOpacity = 1.0
    @State private var appeared = false
    @State private var viewerItem: PhotoViewerItem?
    @State private var showingAddPhotos = false
    @State private var confirmingDelete = false
    @State private var probeHaptic = "none"

    init(playback: MemoryPlaybackViewModel, vm: MemoriesViewModel, baseURL: URL, token: String?) {
        self.playback = playback
        self.vm = vm
        self.baseURL = baseURL
        self.token = token
    }

    private var isPresenting: Bool {
        viewerItem != nil || showingAddPhotos || confirmingDelete
    }

    private struct AutoPlayKey: Equatable {
        let page: MemoryPlaybackViewModel.Page
        let assetIndex: Int
        let isAutoPlaying: Bool
        let videoActive: Bool
        let isPresenting: Bool
        let reduceMotion: Bool
    }

    private var autoPlayKey: AutoPlayKey {
        AutoPlayKey(
            page: playback.page,
            assetIndex: playback.assetIndex,
            isAutoPlaying: playback.isAutoPlaying,
            videoActive: playback.currentAsset?.type == "VIDEO",
            isPresenting: isPresenting,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                pager(insets: proxy.safeAreaInsets)
            }
        }
        .statusBarHidden(true)
        .photoViewer(item: $viewerItem, baseURL: baseURL, token: token)
        .sheet(isPresented: $showingAddPhotos) {
            if let memory = playback.currentMemory {
                AddPhotosToMemorySheet(
                    memoryId: memory.id,
                    existingAssetIds: Set(memory.assets.map(\.id)),
                    vm: vm
                )
            }
        }
        // An alert, not a confirmationDialog: on iOS 26 a confirmationDialog is a popover that drops Cancel.
        .alert(
            "Delete this memory?",
            isPresented: $confirmingDelete
        ) {
            Button("Delete Memory", role: .destructive) {
                Task {
                    let deleted = await playback.deleteCurrentMemory()
                    if !deleted { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos stay in your library — only this memory is removed.")
        }
        .appSensoryFeedback(.impact(flexibility: .soft), trigger: appeared)
        .memoryPlaybackFeedback(playback, onEmit: probeEmit)
        .overlay(alignment: .topLeading) { probeElement }
        .onAppear(perform: appear)
        .onChange(of: playback.page) { _, newPage in showModelPage(newPage) }
        .onChange(of: playback.isFinished) { _, finished in
            if finished { dismiss() }
        }
        .onChange(of: vm.memories.map(\.id)) { _, _ in playback.reconcile() }
        .onChange(of: playback.currentMemory?.assets.count) { _, _ in playback.reconcile() }
        .task(id: autoPlayKey) { await runAutoPlay() }
    }

    // MARK: - Pager

    private func pager(insets: EdgeInsets) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(playback.pages, id: \.self) { page in
                    pageView(page, insets: insets)
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $visiblePage)
        .onScrollPhaseChange { oldPhase, newPhase in
            if newPhase == .interacting {
                playback.stopAutoPlay()
                scrollStartPage = playback.page
            }
            if newPhase == .idle, oldPhase == .interacting || oldPhase == .decelerating,
               let page = visiblePage, page != scrollStartPage {
                playback.userShowedPage(page)
            }
        }
        .opacity(fadeOpacity)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func pageView(_ page: MemoryPlaybackViewModel.Page, insets: EdgeInsets) -> some View {
        switch page {
        case let .memory(id):
            if let memory = vm.memory(id: id) {
                MemoryMomentView(
                    memory: memory,
                    playback: playback,
                    isCurrent: playback.page == page,
                    chromeVisible: appeared,
                    safeInsets: insets,
                    vm: vm,
                    baseURL: baseURL,
                    token: token,
                    onOpenViewer: openViewer,
                    onAddPhotos: { showingAddPhotos = true },
                    onDelete: { confirmingDelete = true }
                )
            } else {
                Color.black
            }
        case .end:
            MemoryEpilogueView(playback: playback, safeInsets: insets)
        }
    }

    /// Moves the pager to a page the model chose. The user's own vertical swipe
    /// already lands there, so nothing moves in that case.
    private func showModelPage(_ page: MemoryPlaybackViewModel.Page) {
        guard visiblePage != page else { return }
        switch MemoryPlaybackMotion.pageChange(reduceMotion: reduceMotion) {
        case .slide:
            withAnimation(PVMotion.movement(.easeInOut(duration: 0.4), reduceMotion: reduceMotion)) {
                visiblePage = page
            }
        case .fade:
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.125)) { fadeOpacity = 0 }
                try? await Task.sleep(for: .milliseconds(125))
                var jump = Transaction()
                jump.disablesAnimations = true
                withTransaction(jump) { visiblePage = page }
                withAnimation(.easeIn(duration: 0.125)) { fadeOpacity = 1 }
            }
        }
    }

    private func openViewer(_ memory: MemoryResponseDto, at index: Int) {
        let items = memory.assets.map { AssetReactItem(from: $0) }
        guard !items.isEmpty else { return }
        viewerItem = PhotoViewerItem(assets: items, index: min(max(index, 0), items.count - 1))
    }

    private func appear() {
        // An initial `scrollPosition` value is ignored by the lazy pager (it lays
        // out from the top): the memory that was opened is jumped to once on screen.
        withTransaction(\.disablesAnimations, true) { visiblePage = playback.page }
        withAnimation(PVMotion.movement(.easeOut(duration: 0.4), reduceMotion: reduceMotion)) {
            appeared = true
        }
        if playback.isFinished { dismiss() }
    }

    // MARK: - Auto-play

    /// 3 s per photo, across memories, up to the epilogue. Re-armed (the task id)
    /// whenever the photo, the play state, a video, a presentation or Reduce
    /// Motion changes; it never runs under Reduce Motion or over a presentation.
    private func runAutoPlay() async {
        guard playback.isAutoPlaying, !reduceMotion, !isPresenting,
              playback.currentAsset?.type != "VIDEO",
              case .memory = playback.page else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        playback.autoAdvance()
    }

    // MARK: - Test probe

    private var probeEmit: ((SensoryFeedback?) -> Void)? {
        guard MemoryPlaybackProbe.isEnabled else { return nil }
        return { played in
            guard let label = MemoryPlaybackProbe.label(for: played) else { return }
            let serial = playback.lastFeedback?.serial ?? 0
            // Never write state while the view is being updated.
            Task { @MainActor in probeHaptic = "\(label)#\(serial)" }
        }
    }

    @ViewBuilder
    private var probeElement: some View {
        if MemoryPlaybackProbe.isEnabled {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("memoryPlaybackProbe")
                .accessibilityValue(Text(verbatim: probeValue))
        }
    }

    private var probeValue: String {
        let page: String
        switch playback.page {
        case let .memory(id): page = id
        case .end: page = "end"
        }
        let autoplay = playback.isAutoPlaying ? "on" : "off"
        return "page=\(page) photo=\(playback.assetIndex) haptic=\(probeHaptic) autoplay=\(autoplay)"
    }
}
