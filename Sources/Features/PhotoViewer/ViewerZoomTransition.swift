import CoreGraphics
import Foundation
import UIKit

/// Pure decisions of the viewer's zoom open/close transition (L-14): which style
/// a transition takes, where the flying image starts and ends, how a downward
/// drag moves it, and how the grid is walked to a thumbnail that is out of
/// screen. No SwiftUI state — everything here is unit-tested directly.

/// Where the viewer is in its life: `opening` until the flying image has landed,
/// `closing` from the first close request. Without a zoom source it is `open`
/// from the start and the transition code never runs.
enum ViewerZoomPhase: Equatable { case opening, open, closing }

enum ViewerTransitionStyle: Equatable { case zoom, fade }

enum ViewerCloseRoute: Equatable {
    /// The thumbnail is entirely on screen: shrink the image onto this frame.
    case reduce(to: CGRect)
    /// The thumbnail is out of screen (or half of it is): scroll the grid first.
    case reveal(id: String)
    /// The photo is not in the grid's list any more: fade out.
    case fade
}

/// The pager's pose while a downward drag closes the viewer.
struct ViewerDragTransform: Equatable {
    var progress: CGFloat
    var scale: CGFloat
    var offset: CGSize

    static let identity = ViewerDragTransform(progress: 0, scale: 1, offset: .zero)

    /// The black backdrop and the controls fade by the same amount.
    var backdropOpacity: CGFloat { 1 - progress }
}

enum ViewerRevealAnchor: Equatable { case top, center, bottom }

struct ViewerRevealTile: Equatable {
    let id: String
    let index: Int
    let frame: CGRect
}

enum ViewerRevealStep: Equatable {
    case done(CGRect)
    case scroll(id: String, anchor: ViewerRevealAnchor)
    case fail
}

enum ViewerPosterHandoff: Equatable { case instant, crossFade }

enum ViewerZoomPlan {
    /// Finger travel that fully closes the viewer — the same course as the
    /// dismiss threshold maths (`PhotoViewerSwipeDecision`).
    static let dragTravel: CGFloat = 300
    static let minDragScale: CGFloat = 0.6
    /// A thumbnail whose frame overshoots the visible area by less than this is
    /// still "entirely visible" (layout rounding).
    static let visibilityTolerance: CGFloat = 0.5
    static let revealStepTimeout: Duration = .milliseconds(300)
    static let revealPoll: Duration = .milliseconds(16)
    /// Poster and video frames closer than this are the same frame.
    static let posterTolerance: CGFloat = 1
    /// Seconds after which a transition that never reported its end is forced.
    static let safetyTimeout: Double = 1.5

    // MARK: - Style

    /// The flight needs an image to fly and a frame to leave from; Reduce Motion
    /// never flies.
    static func openStyle(hasHeroImage: Bool, hasSourceFrame: Bool, reduceMotion: Bool) -> ViewerTransitionStyle {
        hasHeroImage && hasSourceFrame && !reduceMotion ? .zoom : .fade
    }

    static func closeStyle(route: ViewerCloseRoute, hasHeroImage: Bool, reduceMotion: Bool) -> ViewerTransitionStyle {
        if case .reduce = route, hasHeroImage, !reduceMotion { return .zoom }
        return .fade
    }

    // MARK: - Close route

    static func isFullyVisible(_ frame: CGRect, in visible: CGRect) -> Bool {
        frame.minX >= visible.minX - visibilityTolerance
            && frame.minY >= visible.minY - visibilityTolerance
            && frame.maxX <= visible.maxX + visibilityTolerance
            && frame.maxY <= visible.maxY + visibilityTolerance
    }

    /// `gridContains` is "the id is in the grid's list of items": a thumbnail
    /// frame left over from a removed item never counts.
    static func closeRoute(
        currentID: String?,
        gridContains: Bool,
        tileFrame: CGRect?,
        visibleRect: CGRect?
    ) -> ViewerCloseRoute {
        guard let currentID, gridContains else { return .fade }
        if let tileFrame, let visibleRect, isFullyVisible(tileFrame, in: visibleRect) {
            return .reduce(to: tileFrame)
        }
        return .reveal(id: currentID)
    }

    // MARK: - Drag

    static func dragTransform(translation: CGSize, reduceMotion: Bool) -> ViewerDragTransform {
        let progress = min(max(translation.height / dragTravel, 0), 1)
        let scale = reduceMotion ? 1 : 1 - (1 - minDragScale) * progress
        return ViewerDragTransform(progress: progress, scale: scale, offset: translation)
    }

    /// `rect` as the pager draws it under `transform`: scaled about `anchor`
    /// (the pager's centre — the rect's own centre when omitted), then moved.
    static func draggedRect(_ rect: CGRect, transform: ViewerDragTransform, anchor: CGPoint? = nil) -> CGRect {
        let pivot = anchor ?? CGPoint(x: rect.midX, y: rect.midY)
        let centre = CGPoint(
            x: pivot.x + (rect.midX - pivot.x) * transform.scale + transform.offset.width,
            y: pivot.y + (rect.midY - pivot.y) * transform.scale + transform.offset.height
        )
        let size = CGSize(width: rect.width * transform.scale, height: rect.height * transform.scale)
        return CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Where the image is when a closing drag is released: its rest frame
    /// (`displayed`, recorded before the drag) as the pager's scale and move
    /// carry it. `pager` is the pager's REST frame — scaling is about its centre.
    static func dragStartFrame(displayed: CGRect, pager: CGRect, drag: ViewerDragTransform) -> CGRect {
        draggedRect(displayed, transform: drag, anchor: CGPoint(x: pager.midX, y: pager.midY))
    }

    // MARK: - Displayed frame

    /// The frame, in the page's global space, a photo page draws its image in:
    /// `fitted` (the `.fit` rectangle in page coordinates) scaled about the page
    /// centre by `scale`, then moved by `offset` — what `.scaleEffect(scale)`
    /// followed by `.offset(offset)` does to the full-page image.
    static func displayedRect(fitted: CGRect, scale: CGFloat, offset: CGSize, in page: CGRect) -> CGRect {
        let centre = CGPoint(
            x: page.minX + page.width / 2 + (fitted.midX - page.width / 2) * scale + offset.width,
            y: page.minY + page.height / 2 + (fitted.midY - page.height / 2) * scale + offset.height
        )
        let size = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        return CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: - Flying image

    /// The first image found for `urls` (in order), else the ThumbHash image,
    /// else nothing. Both lookups are synchronous: the flight must start on the
    /// next frame, never wait for a request.
    static func heroImage(
        urls: [URL],
        thumbhash: String?,
        cached: (URL) -> UIImage?,
        thumbhashImage: (String) -> UIImage?
    ) -> UIImage? {
        for url in urls {
            if let image = cached(url) { return image }
        }
        if let thumbhash, !thumbhash.isEmpty { return thumbhashImage(thumbhash) }
        return nil
    }

    /// A poster drawn on the frame the flight lands on is replaced by the video
    /// in place when the video fills that same frame, else cross-faded (the
    /// announced ratio was wrong, or the video is rotated).
    static func posterHandoff(posterRect: CGRect, videoRect: CGRect) -> ViewerPosterHandoff {
        let close = abs(posterRect.minX - videoRect.minX) <= posterTolerance
            && abs(posterRect.minY - videoRect.minY) <= posterTolerance
            && abs(posterRect.width - videoRect.width) <= posterTolerance
            && abs(posterRect.height - videoRect.height) <= posterTolerance
        return close ? .instant : .crossFade
    }

    // MARK: - Reveal

    /// One step towards a thumbnail the grid has not (or not entirely) drawn.
    /// A lazy grid only scrolls reliably to a cell it has instantiated, so the
    /// walk goes from the extreme instantiated cell towards the target — one
    /// window at a time — and aims at the target itself once its frame is known.
    static func revealStep(
        targetID: String,
        targetIndex: Int?,
        targetFrame: CGRect?,
        tiles: [ViewerRevealTile],
        visibleRect: CGRect?
    ) -> ViewerRevealStep {
        guard let visibleRect else { return .fail }
        if let targetFrame {
            return isFullyVisible(targetFrame, in: visibleRect)
                ? .done(targetFrame)
                : .scroll(id: targetID, anchor: .center)
        }
        guard let targetIndex, let first = tiles.first else { return .fail }
        var lowest = first
        var highest = first
        var nearest = first
        for tile in tiles {
            if tile.index < lowest.index { lowest = tile }
            if tile.index > highest.index { highest = tile }
            if abs(tile.index - targetIndex) < abs(nearest.index - targetIndex) { nearest = tile }
        }
        if targetIndex > highest.index { return .scroll(id: highest.id, anchor: .top) }
        if targetIndex < lowest.index { return .scroll(id: lowest.id, anchor: .bottom) }
        return .scroll(id: nearest.id, anchor: .center)
    }
}
