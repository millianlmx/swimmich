import Foundation

/// Playback state of the full-screen memories: which memory and which photo are
/// on screen, and the one thing the screen emits besides pictures — haptic
/// feedback.
///
/// It reads the memory list live from `MemoriesViewModel` (`source.memories`
/// fixes the order), so a delete or a photo removal is reflected at once; the
/// parent creates it (`MemoriesViewModel.makePlayback`), nothing is shared.
///
/// Feedback rule: only changes made **by the user** (`user*` methods and
/// `restart()`) emit — auto-play, a finished video and the consequences of a
/// delete / photo removal stay silent. The view turns `photoFeedbackTick` /
/// `memoryFeedbackTick` into a light / medium haptic; `lastFeedback` is what the
/// tests (and the UI-test probe) read.
@MainActor
@Observable
final class MemoryPlaybackViewModel: Identifiable {

    enum Page: Hashable {
        case memory(String)
        case end
    }

    enum FeedbackKind: Equatable {
        case photo
        case memory
    }

    struct Feedback: Equatable {
        let kind: FeedbackKind
        let serial: Int
    }

    let id = UUID()
    /// False under the UI-test switch: the playback is then created (and
    /// restarted) with the auto-play off.
    let autoPlays: Bool

    private let source: MemoriesViewModel

    private(set) var page: Page
    private(set) var assetIndex = 0
    private(set) var isAutoPlaying: Bool
    private(set) var lastFeedback: Feedback?
    private(set) var photoFeedbackTick = 0
    private(set) var memoryFeedbackTick = 0
    private(set) var isFinished = false

    /// Index in `source.memories` of the current memory page — what `reconcile`
    /// falls back on once that memory is gone.
    private var currentPageIndex = 0

    init(source: MemoriesViewModel, startingAt memoryId: String, autoPlays: Bool) {
        self.source = source
        self.autoPlays = autoPlays
        self.isAutoPlaying = autoPlays
        let memories = source.memories
        if memories.isEmpty {
            page = .end
            isFinished = true
        } else {
            let index = memories.firstIndex { $0.id == memoryId } ?? 0
            page = .memory(memories[index].id)
            currentPageIndex = index
        }
    }

    // MARK: - Derived

    /// The memories in list order, then the end screen.
    var pages: [Page] {
        source.memories.map { Page.memory($0.id) } + [.end]
    }

    var currentMemory: MemoryResponseDto? {
        guard case let .memory(id) = page else { return nil }
        return source.memory(id: id)
    }

    var currentAsset: AssetResponseDto? {
        guard let assets = currentMemory?.assets, assets.indices.contains(assetIndex) else { return nil }
        return assets[assetIndex]
    }

    // MARK: - User-made changes (emit a haptic)

    /// The user landed on photo `index` of the current memory.
    func userShowedPhoto(at index: Int) {
        guard case .memory = page,
              let count = currentMemory?.assets.count,
              (0..<count).contains(index), index != assetIndex else { return }
        assetIndex = index
        emit(.photo)
        isAutoPlaying = false
    }

    /// The user swiped past the last photo of the current memory.
    func userAdvancedPastLastPhoto() {
        guard case .memory = page else { return }
        go(to: nextPage())
        emit(.memory)
        isAutoPlaying = false
    }

    /// The user paged vertically onto `p`.
    func userShowedPage(_ p: Page) {
        guard p != page, pages.contains(p) else { return }
        go(to: p)
        emit(.memory)
        isAutoPlaying = false
    }

    /// "Start Over": back to the first memory of the list.
    func restart() {
        if let first = source.memories.first {
            go(to: .memory(first.id))
        } else {
            page = .end
            assetIndex = 0
            isFinished = true
        }
        emit(.memory)
        isAutoPlaying = autoPlays
    }

    /// The user touched the screen to browse: the auto-play stops (no restart
    /// until `restart()`).
    func stopAutoPlay() {
        isAutoPlaying = false
    }

    // MARK: - Automatic changes (silent)

    func autoAdvance() {
        advanceOnePhoto()
    }

    func videoDidEnd() {
        advanceOnePhoto()
    }

    private func advanceOnePhoto() {
        guard case .memory = page else { return }
        if let count = currentMemory?.assets.count, assetIndex < count - 1 {
            assetIndex += 1
        } else {
            go(to: nextPage())
        }
    }

    // MARK: - Source changes

    /// Realigns the playback on the source after a mutation. Idempotent, silent.
    func reconcile() {
        let memories = source.memories
        guard !memories.isEmpty else {
            isFinished = true
            return
        }
        guard case let .memory(id) = page else { return }
        if let index = memories.firstIndex(where: { $0.id == id }) {
            currentPageIndex = index
            assetIndex = min(assetIndex, max(memories[index].assets.count - 1, 0))
        } else if currentPageIndex < memories.count {
            go(to: .memory(memories[currentPageIndex].id))
        } else {
            go(to: .end)
        }
    }

    /// Drops the photo on screen from its memory. The photo id is captured
    /// before the first `await`: the screen may move on while the request runs.
    func removeCurrentPhoto() async {
        stopAutoPlay()
        guard let memory = currentMemory, let asset = currentAsset else { return }
        _ = await source.removeAssets(fromMemoryId: memory.id, assetIds: [asset.id])
        reconcile()
    }

    /// Deletes the memory on screen. `false` when it is still in the source (the
    /// request failed): the view closes the screen, the error shows on the list.
    func deleteCurrentMemory() async -> Bool {
        stopAutoPlay()
        guard case let .memory(id) = page else { return false }
        await source.deleteMemory(id: id)
        if source.memory(id: id) != nil { return false }
        reconcile()
        return true
    }

    // MARK: - Internals

    private func nextPage() -> Page {
        let memories = source.memories
        guard case let .memory(id) = page, let index = memories.firstIndex(where: { $0.id == id }) else {
            return .end
        }
        return index + 1 < memories.count ? .memory(memories[index + 1].id) : .end
    }

    private func go(to p: Page) {
        page = p
        assetIndex = 0
        if case let .memory(id) = p, let index = source.memories.firstIndex(where: { $0.id == id }) {
            currentPageIndex = index
        }
    }

    private func emit(_ kind: FeedbackKind) {
        lastFeedback = Feedback(kind: kind, serial: (lastFeedback?.serial ?? 0) + 1)
        switch kind {
        case .photo: photoFeedbackTick &+= 1
        case .memory: memoryFeedbackTick &+= 1
        }
    }
}
