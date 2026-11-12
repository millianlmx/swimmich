import SwiftUI

/// A scroll the grid owes the viewer's close: bring `id` on screen at `anchor`.
/// `serial` makes two identical requests distinct for `onChange`.
struct ViewerRevealRequest: Equatable {
    let id: String
    let anchor: ViewerRevealAnchor
    let serial: Int
}

extension ViewerRevealAnchor {
    var unitPoint: UnitPoint {
        switch self {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        }
    }
}

/// What a grid tells the photo viewer so the photo can grow out of its thumbnail
/// and shrink back onto it (L-14). Owned by the grid (`@State`), never shared
/// between screens.
///
/// Only `hiddenID` and `revealRequest` are observed: they change when the viewer
/// opens, pages and closes. The thumbnail frames change on every scroll frame and
/// live in an unobserved dictionary, so scrolling or pinching the grid redraws
/// nothing because of this type.
@MainActor
@Observable
final class ViewerZoomSource {
    /// The thumbnail hidden while its photo flies or is shown above it.
    var hiddenID: String?
    /// The scroll the viewer asks of the grid; the grid performs it.
    var revealRequest: ViewerRevealRequest?

    /// `.global` frames of the instantiated thumbnails.
    @ObservationIgnored private(set) var frames: [String: CGRect] = [:]
    /// The grid's visible area in `.global`, bars excluded.
    @ObservationIgnored var visibleRect: CGRect?
    /// The grid's item ids in display order, read when needed (the list changes
    /// while the viewer is open: archive, delete, a newer month on top).
    @ObservationIgnored var orderedIDs: () -> [String] = { [] }

    func report(_ frame: CGRect, for id: String) { frames[id] = frame }
    func forget(_ id: String) { frames[id] = nil }
    func frame(for id: String) -> CGRect? { frames[id] }
    func contains(_ id: String) -> Bool { orderedIDs().contains(id) }

    func requestReveal(_ id: String, anchor: ViewerRevealAnchor) {
        revealRequest = ViewerRevealRequest(id: id, anchor: anchor, serial: (revealRequest?.serial ?? 0) &+ 1)
    }

    /// Runs `body` with no system animation: a `fullScreenCover` then appears
    /// at once, and the app's own zoom is the only motion.
    func presentInstantly(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    /// Brings the thumbnail of `id` entirely on screen and returns its frame, or
    /// `nil` when the grid stopped answering (no progress within `stepTimeout`)
    /// or `id` left the list. Each step scrolls to the instantiated cell
    /// nearest the target, then re-reads what the grid drew.
    func reveal(_ id: String, stepTimeout: Duration = ViewerZoomPlan.revealStepTimeout) async -> CGRect? {
        let ceiling = max(orderedIDs().count, 1)
        for _ in 0..<ceiling {
            let snapshot = tiles(targeting: id)
            let step = ViewerZoomPlan.revealStep(
                targetID: id,
                targetIndex: snapshot.targetIndex,
                targetFrame: frames[id],
                tiles: snapshot.tiles,
                visibleRect: visibleRect
            )
            switch step {
            case .done(let frame):
                return frame
            case .fail:
                return nil
            case .scroll(let scrollID, let anchor):
                let before = Signature(tiles: snapshot.tiles, targetFrame: frames[id])
                requestReveal(scrollID, anchor: anchor)
                guard await waitForChange(from: before, target: id, timeout: stepTimeout) else { return nil }
            }
        }
        return nil
    }

    // MARK: - Reveal internals

    private struct Signature: Equatable {
        let lowest: Int?
        let highest: Int?
        let targetFrame: CGRect?

        init(tiles: [ViewerRevealTile], targetFrame: CGRect?) {
            lowest = tiles.map(\.index).min()
            highest = tiles.map(\.index).max()
            self.targetFrame = targetFrame
        }
    }

    private func tiles(targeting id: String) -> (tiles: [ViewerRevealTile], targetIndex: Int?) {
        let ordered = orderedIDs()
        var indexByID = [String: Int](minimumCapacity: ordered.count)
        for (index, orderedID) in ordered.enumerated() { indexByID[orderedID] = index }
        let tiles = frames.compactMap { entry -> ViewerRevealTile? in
            indexByID[entry.key].map { ViewerRevealTile(id: entry.key, index: $0, frame: entry.value) }
        }
        return (tiles, indexByID[id])
    }

    private func waitForChange(from before: Signature, target id: String, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try? await Task.sleep(for: ViewerZoomPlan.revealPoll)
            if Task.isCancelled { return false }
            if Signature(tiles: tiles(targeting: id).tiles, targetFrame: frames[id]) != before { return true }
        }
        return false
    }
}

// MARK: - Grid modifiers

/// Marks a grid cell as a zoom source: reports its `.global` frame, forgets it
/// when the cell goes away, and hides it while its photo flies.
struct ViewerZoomTileModifier: ViewModifier {
    let id: String
    let source: ViewerZoomSource

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                source.report(frame, for: id)
            }
            .onDisappear { source.forget(id) }
            .opacity(source.hiddenID == id ? 0 : 1)
    }
}

/// Reports the grid's visible area (its frame minus the bars over it).
struct ViewerZoomViewportModifier: ViewModifier {
    let source: ViewerZoomSource

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { proxy in
            let frame = proxy.frame(in: .global)
            let insets = proxy.safeAreaInsets
            return CGRect(
                x: frame.minX + insets.leading,
                y: frame.minY + insets.top,
                width: max(frame.width - insets.leading - insets.trailing, 0),
                height: max(frame.height - insets.top - insets.bottom, 0)
            )
        } action: { visible in
            source.visibleRect = visible
        }
    }
}

extension View {
    /// Without a source the view is returned as is.
    @ViewBuilder
    func viewerZoomTile(id: String, source: ViewerZoomSource?) -> some View {
        if let source {
            modifier(ViewerZoomTileModifier(id: id, source: source))
        } else {
            self
        }
    }

    @ViewBuilder
    func viewerZoomViewport(_ source: ViewerZoomSource?) -> some View {
        if let source {
            modifier(ViewerZoomViewportModifier(source: source))
        } else {
            self
        }
    }

    /// Performs the viewer's scroll request on a grid's `ScrollViewProxy`,
    /// without animation: it happens under the viewer, still on screen.
    func viewerZoomReveal(_ source: ViewerZoomSource, proxy: ScrollViewProxy) -> some View {
        onChange(of: source.revealRequest) { _, request in
            guard let request else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(request.id, anchor: request.anchor.unitPoint)
            }
        }
    }
}
