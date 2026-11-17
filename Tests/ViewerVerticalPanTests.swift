import XCTest
@testable import ImmichSwiftUI

/// The viewer's vertical drag leaves every horizontal swipe to the pager, and
/// its pose lives outside the viewer's body.
@MainActor
final class ViewerVerticalPanTests: XCTestCase {

    func test_horizontalSwipeNeverStartsTheVerticalDrag() {
        XCTAssertFalse(ViewerVerticalPan.beginsVertically(translation: CGPoint(x: -14, y: 2), velocity: CGPoint(x: -900, y: 40)))
        XCTAssertFalse(ViewerVerticalPan.beginsVertically(translation: CGPoint(x: 12, y: -6), velocity: CGPoint(x: 600, y: -200)))
        XCTAssertFalse(ViewerVerticalPan.beginsVertically(translation: CGPoint(x: 10, y: 10), velocity: .zero), "a diagonal is not vertical")
    }

    func test_verticalDragStartsIt() {
        XCTAssertTrue(ViewerVerticalPan.beginsVertically(translation: CGPoint(x: 2, y: 14), velocity: CGPoint(x: 30, y: 800)))
        XCTAssertTrue(ViewerVerticalPan.beginsVertically(translation: CGPoint(x: -3, y: -12), velocity: CGPoint(x: 0, y: -500)))
    }

    func test_poseStartsTransparentOnlyForAZoomOpening() {
        let zoomed = ViewerPose(transitioning: true)
        XCTAssertEqual(zoomed.backdropOpacity, 0)
        XCTAssertEqual(zoomed.chromeOpacity, 0)
        XCTAssertEqual(zoomed.pagerOpacity, 0)

        let plain = ViewerPose(transitioning: false)
        XCTAssertEqual(plain.backdropOpacity, 1)
        XCTAssertEqual(plain.pagerOpacity, 1)
        XCTAssertEqual(plain.dragTransform, .identity)
    }

    func test_dismissProgressFollowsTheDrag() {
        let pose = ViewerPose(transitioning: false)
        pose.dragOffset = CGSize(width: 0, height: 150)
        XCTAssertEqual(pose.dismissProgress, 0.5, accuracy: 1e-9)
        pose.dragOffset = CGSize(width: 0, height: 900)
        XCTAssertEqual(pose.dismissProgress, 1)
        pose.dragOffset = CGSize(width: 0, height: -40)
        XCTAssertEqual(pose.dismissProgress, 0)
    }
}
