import XCTest
import UIKit
@testable import ImmichSwiftUI

/// L-14: the viewer opens by growing out of its thumbnail and closes by shrinking
/// back onto it. These are the decisions behind that, with no view: which style
/// a transition takes, where the flying image starts and ends, how a drag moves
/// it, and how the grid is walked to a thumbnail that is out of screen.
@MainActor
final class ViewerZoomTransitionTests: XCTestCase {

    private let visible = CGRect(x: 0, y: 100, width: 393, height: 600)

    private func tile(_ index: Int, y: CGFloat = 200) -> ViewerRevealTile {
        ViewerRevealTile(id: "t\(index)", index: index, frame: CGRect(x: 0, y: y, width: 120, height: 120))
    }

    private func tiles(_ range: ClosedRange<Int>) -> [ViewerRevealTile] {
        range.map { tile($0) }
    }

    private func image(_ width: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: 3)).image { _ in }
    }

    private func assertRect(
        _ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.001,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }

    // MARK: - AC-27.1

    func test_AC_27_1_openZoomsOnlyWithImageAndSourceFrame() {
        XCTAssertEqual(ViewerZoomPlan.openStyle(hasHeroImage: true, hasSourceFrame: true, reduceMotion: false), .zoom)
        XCTAssertEqual(ViewerZoomPlan.openStyle(hasHeroImage: false, hasSourceFrame: true, reduceMotion: false), .fade)
        XCTAssertEqual(ViewerZoomPlan.openStyle(hasHeroImage: true, hasSourceFrame: false, reduceMotion: false), .fade)
    }

    func test_AC_27_1_tileForgottenWhenItDisappears() {
        let source = ViewerZoomSource()
        let frame = CGRect(x: 4, y: 120, width: 120, height: 120)
        source.report(frame, for: "a")
        XCTAssertEqual(source.frame(for: "a"), frame)
        source.forget("a")
        XCTAssertNil(source.frame(for: "a"))
    }

    func test_AC_27_1_posterHandoffCrossFadesOnRatioMismatch() {
        let window = CGSize(width: 393, height: 852)
        let poster = ZoomGeometry.fittedRect(aspect: 16.0 / 9.0, in: window)
        XCTAssertEqual(
            ViewerZoomPlan.posterHandoff(posterRect: poster, videoRect: poster.insetBy(dx: -0.25, dy: -0.25)),
            .instant, "the same frame to half a point is replaced in place"
        )
        let fourThree = ZoomGeometry.fittedRect(aspect: 4.0 / 3.0, in: window)
        XCTAssertEqual(ViewerZoomPlan.posterHandoff(posterRect: poster, videoRect: fourThree), .crossFade)
        let square = ZoomGeometry.fittedRect(aspect: 1, in: window)
        XCTAssertEqual(ViewerZoomPlan.posterHandoff(posterRect: square, videoRect: poster), .crossFade)
    }

    // MARK: - AC-27.2

    func test_AC_27_2_heroImageLadder() {
        let thumbURL = URL(string: "https://x.test/thumb")!
        let pageURL = URL(string: "https://x.test/preview")!
        let thumb = image(1), page = image(2), hash = image(3)

        // The thumbnail in the cache wins over the ThumbHash.
        let opened = ViewerZoomPlan.heroImage(
            urls: [thumbURL], thumbhash: "h",
            cached: { $0 == thumbURL ? thumb : nil },
            thumbhashImage: { _ in hash }
        )
        XCTAssertTrue(opened === thumb)

        // No cached image: the ThumbHash.
        let hashed = ViewerZoomPlan.heroImage(
            urls: [thumbURL], thumbhash: "h", cached: { _ in nil }, thumbhashImage: { _ in hash }
        )
        XCTAssertTrue(hashed === hash)

        // Nothing at all: no image, so the open fades.
        XCTAssertNil(ViewerZoomPlan.heroImage(
            urls: [thumbURL], thumbhash: nil, cached: { _ in nil }, thumbhashImage: { _ in hash }
        ))
        XCTAssertNil(ViewerZoomPlan.heroImage(
            urls: [thumbURL], thumbhash: "h", cached: { _ in nil }, thumbhashImage: { _ in nil }
        ))

        // Closing: what the page displays comes before the thumbnail.
        let closed = ViewerZoomPlan.heroImage(
            urls: [pageURL, thumbURL], thumbhash: "h",
            cached: { $0 == pageURL ? page : thumb },
            thumbhashImage: { _ in hash }
        )
        XCTAssertTrue(closed === page)
    }

    // MARK: - AC-27.3

    func test_AC_27_3_closeReducesToFullyVisibleTile() {
        let frame = CGRect(x: 135, y: 300, width: 123, height: 123)
        XCTAssertEqual(
            ViewerZoomPlan.closeRoute(currentID: "a", gridContains: true, tileFrame: frame, visibleRect: visible),
            .reduce(to: frame)
        )
        XCTAssertEqual(
            ViewerZoomPlan.closeStyle(route: .reduce(to: frame), hasHeroImage: true, reduceMotion: false), .zoom
        )
        XCTAssertEqual(
            ViewerZoomPlan.closeStyle(route: .reduce(to: frame), hasHeroImage: false, reduceMotion: false), .fade,
            "no image to fly: fade"
        )
        XCTAssertEqual(ViewerZoomPlan.closeStyle(route: .fade, hasHeroImage: true, reduceMotion: false), .fade)
    }

    func test_AC_27_3_displayedRectFollowsZoomAndOffset() {
        let page = CGRect(x: 0, y: 59, width: 393, height: 700)
        let fitted = CGRect(x: 0, y: 202.625, width: 393, height: 294.75)

        let rest = ViewerZoomPlan.displayedRect(fitted: fitted, scale: 1, offset: .zero, in: page)
        assertRect(rest, CGRect(x: 0, y: 261.625, width: 393, height: 294.75))

        let zoomed = ViewerZoomPlan.displayedRect(fitted: fitted, scale: 2, offset: CGSize(width: 10, height: -20), in: page)
        XCTAssertEqual(zoomed.width, 786, accuracy: 0.001)
        XCTAssertEqual(zoomed.height, 589.5, accuracy: 0.001)
        XCTAssertEqual(zoomed.midX, 206.5, accuracy: 0.001)
        XCTAssertEqual(zoomed.midY, 389.0, accuracy: 0.001)
    }

    // MARK: - AC-27.4

    func test_AC_27_4_dragShrinksAndFollowsFinger() {
        let half = ViewerZoomPlan.dragTransform(translation: CGSize(width: 30, height: 150), reduceMotion: false)
        XCTAssertEqual(half.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.scale, 0.8, accuracy: 0.0001)
        XCTAssertEqual(half.offset, CGSize(width: 30, height: 150))
        XCTAssertEqual(half.backdropOpacity, 0.5, accuracy: 0.0001)

        let far = ViewerZoomPlan.dragTransform(translation: CGSize(width: 0, height: 600), reduceMotion: false)
        XCTAssertEqual(far.progress, 1, accuracy: 0.0001)
        XCTAssertEqual(far.scale, 0.6, accuracy: 0.0001)

        let up = ViewerZoomPlan.dragTransform(translation: CGSize(width: 0, height: -50), reduceMotion: false)
        XCTAssertEqual(up.progress, 0, accuracy: 0.0001)
        XCTAssertEqual(up.scale, 1, accuracy: 0.0001)
    }

    func test_AC_27_4_draggedRectScalesAboutCenter() {
        let rect = CGRect(x: 100, y: 200, width: 200, height: 100)
        let transform = ViewerZoomPlan.dragTransform(translation: CGSize(width: 30, height: 150), reduceMotion: false)
        assertRect(
            ViewerZoomPlan.draggedRect(rect, transform: transform),
            CGRect(x: 150, y: 360, width: 160, height: 80)
        )
        assertRect(ViewerZoomPlan.draggedRect(rect, transform: .identity), rect)

        // Scaled about another point (the pager's centre), then moved.
        let scaledOnly = ViewerDragTransform(progress: 0.5, scale: 0.8, offset: .zero)
        let about = ViewerZoomPlan.draggedRect(rect, transform: scaledOnly, anchor: CGPoint(x: 200, y: 500))
        XCTAssertEqual(about.midX, 200, accuracy: 0.001)
        XCTAssertEqual(about.midY, 500 + (250 - 500) * 0.8, accuracy: 0.001)
    }

    /// The close starts from where the pager has carried the image: scaled about
    /// the pager's REST centre. The pager's frame read during the drag is the
    /// transformed one (its centre moved by the offset), which would shift the
    /// start by offset × (1 − scale) — 160 pt for a 400 pt drag.
    func test_AC_27_4_dragStartPivotsOnRestPagerFrame() {
        let pagerRest = CGRect(x: 0, y: 0, width: 393, height: 852)
        let displayed = CGRect(x: 0, y: 100, width: 393, height: 300)
        let drag = ViewerZoomPlan.dragTransform(translation: CGSize(width: 0, height: 400), reduceMotion: false)

        let start = ViewerZoomPlan.dragStartFrame(displayed: displayed, pager: pagerRest, drag: drag)
        XCTAssertEqual(start.midX, 196.5, accuracy: 0.001)
        XCTAssertEqual(start.midY, 426 + (250 - 426) * 0.6 + 400, accuracy: 0.001)
        XCTAssertEqual(start.width, 393 * 0.6, accuracy: 0.001)
        XCTAssertEqual(start.height, 300 * 0.6, accuracy: 0.001)

        let pagerMoved = ViewerZoomPlan.draggedRect(pagerRest, transform: drag)
        let shifted = ViewerZoomPlan.dragStartFrame(displayed: displayed, pager: pagerMoved, drag: drag)
        XCTAssertEqual(shifted.midY - start.midY, 400 * (1 - 0.6), accuracy: 0.001)
    }

    /// A pager frame reported while a closing drag holds is ignored, so the rest
    /// frame recorded before the drag stays the pivot.
    func test_AC_27_4_pagerFrameFrozenWhileClosingDrag() {
        let book = ViewerFrameBook()
        let rest = CGRect(x: 0, y: 0, width: 393, height: 852)
        book.reportPager(rest, frozen: false)
        let drag = ViewerZoomPlan.dragTransform(translation: CGSize(width: 0, height: 400), reduceMotion: false)
        book.reportPager(ViewerZoomPlan.draggedRect(rest, transform: drag), frozen: true)
        assertRect(book.pagerFrame ?? .zero, rest)
        // Once the drag has ended (reset to rest), reports are taken again.
        book.reportPager(CGRect(x: 0, y: 59, width: 393, height: 700), frozen: false)
        assertRect(book.pagerFrame ?? .zero, CGRect(x: 0, y: 59, width: 393, height: 700))
    }

    func test_AC_27_4_releaseUsesUnchangedThresholds() {
        let under = ViewerZoomPlan.dragTransform(translation: CGSize(width: 0, height: 75), reduceMotion: false)
        XCTAssertFalse(PhotoViewerSwipeDecision.shouldClose(progress: under.progress, velocity: 0))
        let over = ViewerZoomPlan.dragTransform(translation: CGSize(width: 0, height: 78), reduceMotion: false)
        XCTAssertTrue(PhotoViewerSwipeDecision.shouldClose(progress: over.progress, velocity: 0))
        XCTAssertTrue(PhotoViewerSwipeDecision.shouldClose(progress: under.progress, velocity: 901))
    }

    // MARK: - AC-27.5

    func test_AC_27_5_closeRevealsLoadedTileOutOfView() {
        XCTAssertEqual(
            ViewerZoomPlan.closeRoute(currentID: "a", gridContains: true, tileFrame: nil, visibleRect: visible),
            .reveal(id: "a"), "loaded in the list, not drawn"
        )
        let straddling = CGRect(x: 0, y: 650, width: 120, height: 120)
        XCTAssertEqual(
            ViewerZoomPlan.closeRoute(currentID: "a", gridContains: true, tileFrame: straddling, visibleRect: visible),
            .reveal(id: "a"), "half under the bottom edge"
        )
        XCTAssertEqual(
            ViewerZoomPlan.closeRoute(currentID: "a", gridContains: true, tileFrame: CGRect(x: 0, y: 300, width: 120, height: 120), visibleRect: nil),
            .reveal(id: "a"), "the visible area is unknown"
        )
    }

    func test_AC_27_5_fullyVisibleBoundaries() {
        let inside = CGRect(x: 10, y: 150, width: 100, height: 100)
        XCTAssertTrue(ViewerZoomPlan.isFullyVisible(inside, in: visible))
        let overshootSmall = CGRect(x: 10, y: 99.6, width: 100, height: 100)
        XCTAssertTrue(ViewerZoomPlan.isFullyVisible(overshootSmall, in: visible), "0.4 pt over is layout rounding")
        let overshoot = CGRect(x: 10, y: 99, width: 100, height: 100)
        XCTAssertFalse(ViewerZoomPlan.isFullyVisible(overshoot, in: visible))
        let right = CGRect(x: 294, y: 150, width: 100, height: 100)
        XCTAssertFalse(ViewerZoomPlan.isFullyVisible(right, in: visible), "1 pt past the right edge")
    }

    func test_AC_27_5_revealStepWalksTowardTarget() {
        // Target far below the instantiated cells: aim at the last one, at the top.
        XCTAssertEqual(
            ViewerZoomPlan.revealStep(targetID: "t74", targetIndex: 74, targetFrame: nil, tiles: tiles(0...20), visibleRect: visible),
            .scroll(id: "t20", anchor: .top)
        )
        // Target far above: aim at the first one, at the bottom.
        XCTAssertEqual(
            ViewerZoomPlan.revealStep(targetID: "t2", targetIndex: 2, targetFrame: nil, tiles: tiles(40...60), visibleRect: visible),
            .scroll(id: "t40", anchor: .bottom)
        )
        // Between the extremes, not drawn: the nearest drawn cell, centred.
        let sparse = [tile(10), tile(30)]
        XCTAssertEqual(
            ViewerZoomPlan.revealStep(targetID: "t27", targetIndex: 27, targetFrame: nil, tiles: sparse, visibleRect: visible),
            .scroll(id: "t30", anchor: .center)
        )
        // Drawn but straddling the bottom edge: scroll to the target itself.
        let straddling = CGRect(x: 0, y: 650, width: 120, height: 120)
        XCTAssertEqual(
            ViewerZoomPlan.revealStep(targetID: "t5", targetIndex: 5, targetFrame: straddling, tiles: tiles(0...20), visibleRect: visible),
            .scroll(id: "t5", anchor: .center)
        )
        // Drawn and entirely visible: done, with its frame.
        let inside = CGRect(x: 0, y: 300, width: 120, height: 120)
        XCTAssertEqual(
            ViewerZoomPlan.revealStep(targetID: "t5", targetIndex: 5, targetFrame: inside, tiles: tiles(0...20), visibleRect: visible),
            .done(inside)
        )
        // Nothing to go on.
        XCTAssertEqual(
            ViewerZoomPlan.revealStep(targetID: "t5", targetIndex: 5, targetFrame: nil, tiles: [], visibleRect: visible), .fail
        )
        XCTAssertEqual(
            ViewerZoomPlan.revealStep(targetID: "t5", targetIndex: 5, targetFrame: inside, tiles: tiles(0...20), visibleRect: nil), .fail
        )
        XCTAssertEqual(
            ViewerZoomPlan.revealStep(targetID: "gone", targetIndex: nil, targetFrame: nil, tiles: tiles(0...20), visibleRect: visible), .fail,
            "an id the list no longer has"
        )
    }

    /// A lazy grid, as SwiftUI builds one: only the rows that touch the window,
    /// widened by one row, exist; `scrollTo` works on a cell that exists.
    private struct LazyGridSim {
        let count: Int
        let columns = 3
        let rowHeight: CGFloat = 122
        let window: CGFloat = 650
        let top: CGFloat = 100
        var scrollY: CGFloat = 0

        var rows: Int { (count + columns - 1) / columns }
        var maxScroll: CGFloat { max(CGFloat(rows) * rowHeight - window, 0) }
        var visibleRect: CGRect { CGRect(x: 0, y: top, width: 393, height: window) }

        func id(_ index: Int) -> String { "t\(index)" }

        func index(of id: String) -> Int? { Int(id.dropFirst()) }

        var instantiatedRows: ClosedRange<Int> {
            let first = max(Int(floor((scrollY - rowHeight) / rowHeight)), 0)
            let last = min(Int(floor((scrollY + window + rowHeight) / rowHeight)), rows - 1)
            return first...max(last, first)
        }

        func frame(of index: Int) -> CGRect? {
            let row = index / columns
            guard instantiatedRows.contains(row), index < count else { return nil }
            return CGRect(
                x: CGFloat(index % columns) * 131,
                y: top + CGFloat(row) * rowHeight - scrollY,
                width: 128,
                height: rowHeight
            )
        }

        var tiles: [ViewerRevealTile] {
            instantiatedRows.flatMap { row in
                (0..<columns).compactMap { col -> ViewerRevealTile? in
                    let index = row * columns + col
                    return frame(of: index).map { ViewerRevealTile(id: id(index), index: index, frame: $0) }
                }
            }
        }

        func isInstantiated(_ id: String) -> Bool {
            index(of: id).map { frame(of: $0) != nil } ?? false
        }

        mutating func scrollTo(_ id: String, anchor: ViewerRevealAnchor) {
            guard let index = index(of: id) else { return }
            let cellTop = CGFloat(index / columns) * rowHeight
            switch anchor {
            case .top: scrollY = cellTop
            case .center: scrollY = cellTop + rowHeight / 2 - window / 2
            case .bottom: scrollY = cellTop + rowHeight - window
            }
            scrollY = min(max(scrollY, 0), maxScroll)
        }
    }

    /// Leads `sim` to `target` by `revealStep` alone; returns the frame and the
    /// number of scrolls, and checks every scroll on the way.
    private func walk(_ sim: inout LazyGridSim, to target: Int) -> (frame: CGRect?, steps: Int) {
        let targetID = sim.id(target)
        var steps = 0
        while steps < 1_000 {
            let tiles = sim.tiles
            let step = ViewerZoomPlan.revealStep(
                targetID: targetID,
                targetIndex: target,
                targetFrame: sim.frame(of: target),
                tiles: tiles,
                visibleRect: sim.visibleRect
            )
            switch step {
            case .done(let frame):
                return (frame, steps)
            case .fail:
                XCTFail("the walk failed after \(steps) steps")
                return (nil, steps)
            case .scroll(let id, let anchor):
                XCTAssertTrue(sim.isInstantiated(id), "step \(steps) aims at \(id), which the grid has not built")
                let highestBefore = tiles.map(\.index).max() ?? 0
                let lowestBefore = tiles.map(\.index).min() ?? 0
                sim.scrollTo(id, anchor: anchor)
                let after = sim.tiles.map(\.index)
                if anchor == .top {
                    XCTAssertGreaterThan(after.max() ?? 0, highestBefore, "step \(steps) did not advance")
                } else if anchor == .bottom {
                    XCTAssertLessThan(after.min() ?? 0, lowestBefore, "step \(steps) did not advance")
                }
                steps += 1
            }
        }
        XCTFail("the walk did not converge")
        return (nil, steps)
    }

    func test_AC_27_5_revealConvergesAtAnyDistance() {
        var sim = LazyGridSim(count: 3_000)
        let rowsPerWindow = Int(sim.window / sim.rowHeight)

        func bound(rows: Int) -> Int {
            Int(ceil(Double(max(rows, 0)) / Double(rowsPerWindow))) + 2
        }

        // From the top to the 75th photo.
        var result = walk(&sim, to: 74)
        XCTAssertNotNil(result.frame)
        XCTAssertTrue(result.frame.map { ViewerZoomPlan.isFullyVisible($0, in: sim.visibleRect) } ?? false)
        XCTAssertLessThanOrEqual(result.steps, bound(rows: 74 / sim.columns))

        // Back to the top, then to the very last photo.
        sim.scrollY = 0
        result = walk(&sim, to: 2_999)
        XCTAssertTrue(result.frame.map { ViewerZoomPlan.isFullyVisible($0, in: sim.visibleRect) } ?? false)
        XCTAssertLessThanOrEqual(result.steps, bound(rows: 2_999 / sim.columns))

        // From the bottom back to the first photo.
        result = walk(&sim, to: 0)
        XCTAssertTrue(result.frame.map { ViewerZoomPlan.isFullyVisible($0, in: sim.visibleRect) } ?? false)
        XCTAssertLessThanOrEqual(result.steps, bound(rows: 2_999 / sim.columns))
    }

    // MARK: Reveal with the real source

    /// Waits (at most 2 s) until `condition` holds.
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func reportTiles(_ source: ViewerZoomSource, ids: [String], range: ClosedRange<Int>) {
        for id in ids { source.forget(id) }
        for index in range {
            source.report(CGRect(x: 0, y: 100 + CGFloat(index - range.lowerBound) * 10, width: 120, height: 120), for: ids[index])
        }
    }

    func test_AC_27_5_revealFollowsReportedTiles() async {
        let source = ViewerZoomSource()
        let ids = (0..<100).map { "p\($0)" }
        source.orderedIDs = { ids }
        source.visibleRect = visible
        reportTiles(source, ids: ids, range: 0...20)

        let revealing = Task { await source.reveal("p74") }

        await wait { source.revealRequest != nil }
        XCTAssertEqual(source.revealRequest, ViewerRevealRequest(id: "p20", anchor: .top, serial: 1))

        reportTiles(source, ids: ids, range: 18...41)
        await wait { source.revealRequest?.serial == 2 }
        XCTAssertEqual(source.revealRequest, ViewerRevealRequest(id: "p41", anchor: .top, serial: 2))

        // The target is drawn, entirely inside the visible area.
        for id in ids { source.forget(id) }
        source.report(CGRect(x: 0, y: 150, width: 120, height: 120), for: "p73")
        source.report(CGRect(x: 131, y: 150, width: 120, height: 120), for: "p74")
        let frame = await revealing.value
        XCTAssertEqual(frame, CGRect(x: 131, y: 150, width: 120, height: 120))
    }

    func test_AC_27_5_revealIgnoresPartiallyVisibleTile() async {
        let source = ViewerZoomSource()
        let ids = (0..<10).map { "p\($0)" }
        source.orderedIDs = { ids }
        source.visibleRect = visible
        // Straddles the bottom edge (700).
        source.report(CGRect(x: 0, y: 650, width: 120, height: 120), for: "p5")

        let frame = await source.reveal("p5", stepTimeout: .milliseconds(100))

        XCTAssertEqual(source.revealRequest, ViewerRevealRequest(id: "p5", anchor: .center, serial: 1))
        XCTAssertNil(frame, "a half-visible thumbnail is not a place to land on")
    }

    func test_AC_27_5_revealGivesUpWithoutProgress() async {
        let source = ViewerZoomSource()
        let ids = (0..<100).map { "p\($0)" }
        source.orderedIDs = { ids }
        source.visibleRect = visible
        reportTiles(source, ids: ids, range: 0...20)

        let frame = await source.reveal("p74", stepTimeout: .milliseconds(100))

        XCTAssertNotNil(source.revealRequest)
        XCTAssertNil(frame)
    }

    // MARK: - AC-27.6

    func test_AC_27_6_closeFadesWhenPhotoLeftGrid() {
        let frame = CGRect(x: 135, y: 300, width: 123, height: 123)
        XCTAssertEqual(
            ViewerZoomPlan.closeRoute(currentID: "gone", gridContains: false, tileFrame: frame, visibleRect: visible),
            .fade, "a thumbnail frame left behind by a removed item does not count"
        )
        XCTAssertEqual(
            ViewerZoomPlan.closeRoute(currentID: nil, gridContains: false, tileFrame: nil, visibleRect: visible),
            .fade
        )
        let source = ViewerZoomSource()
        source.orderedIDs = { ["a", "b"] }
        XCTAssertTrue(source.contains("a"))
        XCTAssertFalse(source.contains("c"))
    }

    // MARK: - AC-28.2

    func test_AC_28_2_reduceMotionAlwaysFades() {
        XCTAssertEqual(ViewerZoomPlan.openStyle(hasHeroImage: true, hasSourceFrame: true, reduceMotion: true), .fade)
        XCTAssertEqual(
            ViewerZoomPlan.closeStyle(route: .reduce(to: CGRect(x: 0, y: 0, width: 100, height: 100)), hasHeroImage: true, reduceMotion: true),
            .fade
        )
        XCTAssertTrue(ViewerZoomPlan.reduceMotion(system: true))
    }

    func test_AC_28_2_dragNeverScalesUnderReduceMotion() {
        let half = ViewerZoomPlan.dragTransform(translation: CGSize(width: 30, height: 150), reduceMotion: true)
        XCTAssertEqual(half.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.scale, 1)
        XCTAssertEqual(half.offset, CGSize(width: 30, height: 150))
        XCTAssertEqual(half.backdropOpacity, 0.5, accuracy: 0.0001)

        let far = ViewerZoomPlan.dragTransform(translation: CGSize(width: 0, height: 600), reduceMotion: true)
        XCTAssertEqual(far.scale, 1)

        let rect = CGRect(x: 100, y: 200, width: 200, height: 100)
        assertRect(ViewerZoomPlan.draggedRect(rect, transform: half), rect.offsetBy(dx: 30, dy: 150))
    }
}
