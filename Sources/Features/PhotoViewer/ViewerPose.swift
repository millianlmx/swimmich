import SwiftUI
import UIKit

/// The viewer's pose: where a closing drag has taken the pager, and the
/// opacities of the backdrop, the pager and the controls through the drag and
/// the zoom open/close.
///
/// An observable of its own, read only by the small modifiers below. A drag
/// rewrites it at every touch move: as `@State` of `PhotoViewer` it re-ran the
/// whole viewer body at every frame — the pager's `ForEach` over every photo
/// of the list, the filmstrip, both bars — which is what made the swipe down
/// stutter. Only these modifiers depend on it now.
@MainActor
@Observable
final class ViewerPose {
    var backdropOpacity: CGFloat
    var chromeOpacity: CGFloat
    var pagerOpacity: CGFloat
    /// The pager's scale and move under a closing drag (zoom-source viewer).
    var dragTransform = ViewerDragTransform.identity
    /// The whole viewer's move under a closing drag (no zoom source).
    var dragOffset: CGSize = .zero

    /// `transitioning`: the viewer opens by its own zoom, from transparent.
    init(transitioning: Bool) {
        backdropOpacity = transitioning ? 0 : 1
        chromeOpacity = transitioning ? 0 : 1
        pagerOpacity = transitioning ? 0 : 1
    }

    /// 0…1 progress of a closing drag of the viewer without zoom source.
    var dismissProgress: CGFloat {
        min(max(dragOffset.height / 300, 0), 1)
    }
}

/// The black backdrop behind the pages.
struct ViewerBackdrop: View {
    let pose: ViewerPose

    var body: some View {
        Color.black.ignoresSafeArea().opacity(pose.backdropOpacity)
    }
}

/// The pager's opacity, scale and move.
struct ViewerPagerPose: ViewModifier {
    let pose: ViewerPose

    func body(content: Content) -> some View {
        content
            .opacity(pose.pagerOpacity)
            .scaleEffect(pose.dragTransform.scale)
            .offset(pose.dragTransform.offset)
    }
}

/// The controls' opacity.
struct ViewerChromeOpacity: ViewModifier {
    let pose: ViewerPose

    func body(content: Content) -> some View {
        content.opacity(pose.chromeOpacity)
    }
}

/// Without a zoom source the whole viewer follows the finger and fades.
struct ViewerFollowsFinger: ViewModifier {
    let pose: ViewerPose
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .offset(y: enabled ? pose.dragOffset.height : 0)
            .opacity(enabled ? 1 - pose.dismissProgress : 1)
    }
}

/// The viewer's vertical drag — down closes, up opens the info panel — as a
/// UIKit pan that only BEGINS on a vertical-dominant move and recognizes
/// alongside every other gesture.
///
/// As a SwiftUI `DragGesture` on the whole viewer it competed with the pan of
/// the pager's paging scroll view: a horizontal swipe no longer turned the
/// page. A horizontal move never starts this one, so the pager always gets it.
struct ViewerVerticalPan: UIGestureRecognizerRepresentable {

    /// What a drag reports, with the fields of `DragGesture.Value` the viewer reads.
    struct Value {
        var translation: CGSize
        var predictedEndTranslation: CGSize
        var startLocation: CGPoint
    }

    /// Seconds of travel at the release speed that make the predicted end:
    /// how far `UIScrollView`'s normal deceleration carries a flick.
    static let projection: CGFloat = 0.5

    var onChanged: (Value) -> Void
    var onEnded: (Value) -> Void

    /// Begins only when the move is clearly vertical (velocity weighed in, so
    /// a quick horizontal flick that wobbles is still the pager's).
    static func beginsVertically(translation: CGPoint, velocity: CGPoint) -> Bool {
        let horizontal = abs(translation.x) + abs(velocity.x) * 0.05
        let vertical = abs(translation.y) + abs(velocity.y) * 0.05
        return vertical > horizontal * 1.2
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var startLocation: CGPoint = .zero

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            return ViewerVerticalPan.beginsVertically(
                translation: pan.translation(in: pan.view),
                velocity: pan.velocity(in: pan.view)
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        let velocity = recognizer.velocity(in: recognizer.view)
        if recognizer.state == .began {
            let location = recognizer.location(in: recognizer.view)
            context.coordinator.startLocation = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
        }
        let value = Value(
            translation: CGSize(width: translation.x, height: translation.y),
            predictedEndTranslation: CGSize(
                width: translation.x + velocity.x * Self.projection,
                height: translation.y + velocity.y * Self.projection
            ),
            startLocation: context.coordinator.startLocation
        )
        switch recognizer.state {
        case .began, .changed:
            onChanged(value)
        case .ended:
            onEnded(value)
        case .cancelled, .failed:
            // Interrupted (a call, a system gesture): back to rest, never a close.
            onEnded(Value(translation: .zero, predictedEndTranslation: .zero, startLocation: value.startLocation))
        default:
            break
        }
    }
}
