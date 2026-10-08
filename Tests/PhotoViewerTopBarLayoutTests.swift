import UIKit
import XCTest
@testable import ImmichSwiftUI

/// The viewer's top-bar layout decision (`PhotoViewerTopBarLayout`): which
/// trailing actions collapse behind "⋯" and whether the badge is two lines or
/// one truncated line. Vectors are the contract's SP-3 / SP-5 unit criteria.
/// Each test name carries the acceptance criterion it proves (`AC-<n>`, written
/// `AC<n>` in the identifier since Swift names cannot contain a hyphen).
final class PhotoViewerTopBarLayoutTests: XCTestCase {

    private typealias Layout = PhotoViewerTopBarLayout

    // MARK: - AC-1 : the badge is rigid and as wide as its widest line

    /// AC-1 : Given « Ogre » and « 2 mai 2025 », the badge reserves at least the
    /// rounded-up width of its widest line (plus the 32 pt padding), so neither
    /// line is squeezed below its own width.
    func testAC1_badgeWidthReservesWidestLineWithPadding() {
        let placeWidth = ("Ogre" as NSString)
            .size(withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]).width
        let dateWidth = ("2 mai 2025" as NSString)
            .size(withAttributes: [.font: UIFont.systemFont(ofSize: 13)]).width
        let width = Layout.badgeWidth(place: "Ogre", date: "2 mai 2025")
        XCTAssertGreaterThanOrEqual(width, ceil(max(placeWidth, dateWidth)) + Layout.badgeHorizontalPadding)
    }

    /// AC-1 : Without a place the badge is the date alone plus padding.
    func testAC1_badgeWidthWithoutPlaceIsPaddingOnlyForEmptyDate() {
        XCTAssertEqual(Layout.badgeWidth(place: nil, date: ""), 32)
    }

    // MARK: - AC-2 : trailing actions collapse behind "⋯" as the row narrows

    /// AC-2 : At 402 pt with a 104 pt badge and four actions, the two trailing
    /// actions (cast, details) are the ones collapsed.
    func testAC2_rowNarrowerThanFullCollapsesTrailingActions() {
        XCTAssertEqual(Layout.plan(availableWidth: 402, badgeWidth: 104, actionCount: 4),
                       .init(collapsedActions: 2, badge: .twoLine))
    }

    /// AC-2 : Narrower rows collapse more actions, from the end of the row.
    func testAC2_narrowerRowsCollapseMoreActions() {
        XCTAssertEqual(Layout.plan(availableWidth: 375, badgeWidth: 104, actionCount: 4),
                       .init(collapsedActions: 3, badge: .twoLine))
        XCTAssertEqual(Layout.plan(availableWidth: 320, badgeWidth: 104, actionCount: 4),
                       .init(collapsedActions: 4, badge: .twoLine))
    }

    /// AC-2 : The row arithmetic is pinned: two collapsed actions with a 104 pt
    /// badge add up to 392 pt (pill + "⋯" + spacers + gaps).
    func testAC2_rowWidthArithmeticIsPinned() {
        XCTAssertEqual(Layout.rowWidth(collapsed: 2, badgeWidth: 104, actionCount: 4), 392)
    }

    // MARK: - AC-3 : nothing collapses when the whole row fits

    /// AC-3 : When the full row (four live pills) fits exactly, nothing collapses.
    func testAC3_fullRowFittingKeepsEveryActionLive() {
        XCTAssertEqual(Layout.plan(availableWidth: 448, badgeWidth: 104, actionCount: 4),
                       .init(collapsedActions: 0, badge: .twoLine))
    }

    /// AC-3 : One pixel under the full row, the collapse begins (`<=` boundary).
    func testAC3_oneUnderFullRowCollapses() {
        XCTAssertEqual(Layout.plan(availableWidth: 447, badgeWidth: 104, actionCount: 4),
                       .init(collapsedActions: 2, badge: .twoLine))
    }

    /// AC-3 : Three actions fit at 402 pt, so the viewer shows them all live.
    func testAC3_threeActionsFitAt402WithoutCollapsing() {
        XCTAssertEqual(Layout.plan(availableWidth: 402, badgeWidth: 104, actionCount: 3),
                       .init(collapsedActions: 0, badge: .twoLine))
    }

    /// AC-3 : No action means nothing to collapse; the two-line badge still
    /// needs its width to fit (224 pt = 32 padding + 40 back + 104 badge + 48 for the three gaps).
    func testAC3_noActionsNothingToCollapse() {
        XCTAssertEqual(Layout.plan(availableWidth: 224, badgeWidth: 104, actionCount: 0),
                       .init(collapsedActions: 0, badge: .twoLine))
    }

    /// AC-3 : Across the whole width range the collapsed count never grows as the
    /// row gets wider, never exceeds the action count, and any collapse really
    /// fits the width it was chosen for. Not permanent, not forced.
    func testAC3_collapseIsMonotoneAndFitsItsWidth() {
        var previous = Int.max
        for width in stride(from: CGFloat(280), through: 480, by: 4) {
            let plan = Layout.plan(availableWidth: width, badgeWidth: 104, actionCount: 4)
            XCTAssertLessThanOrEqual(plan.collapsedActions, 4)
            XCTAssertLessThanOrEqual(plan.collapsedActions, previous, "collapse grew at width \(width)")
            if plan.badge == .twoLine, plan.collapsedActions < 4 {
                XCTAssertLessThanOrEqual(
                    Layout.rowWidth(collapsed: plan.collapsedActions, badgeWidth: 104, actionCount: 4),
                    width
                )
            }
            previous = plan.collapsedActions
        }
    }

    // MARK: - AC-4 : two lines, then one truncated line when even that cannot fit

    /// AC-4 : At 279 pt even the "⋯"-only row (280 pt) overflows: the badge
    /// falls back to one truncated line with every action collapsed.
    func testAC4_belowCollapsedRowFallsBackToSingleLine() {
        XCTAssertEqual(Layout.plan(availableWidth: 279, badgeWidth: 104, actionCount: 4),
                       .init(collapsedActions: 4, badge: .singleLineTruncated))
    }

    /// AC-4 : A badge too wide for any row (300 pt) at 402 pt drops to one line.
    func testAC4_overwideBadgeFallsBackToSingleLine() {
        XCTAssertEqual(Layout.plan(availableWidth: 402, badgeWidth: 300, actionCount: 4),
                       .init(collapsedActions: 4, badge: .singleLineTruncated))
    }

    // MARK: - AC-5 : the trash bar (three actions, not squeezed) keeps its layout

    /// AC-5 : The trash viewer (three actions, 99 pt badge) at 402 pt keeps every
    /// action live and the two-line badge — no "⋯", no changed badge.
    func testAC5_trashBarAt402KeepsEveryActionLive() {
        XCTAssertEqual(Layout.plan(availableWidth: 402, badgeWidth: 99, actionCount: 3),
                       .init(collapsedActions: 0, badge: .twoLine))
    }

    /// AC-5 : At 440 pt the four-action row (443 pt) does not fit, so two actions
    /// collapse; this is the boundary the trash bar must not reach by mistake.
    func testAC5_fourActionRowAt440CollapsesTwo() {
        XCTAssertEqual(Layout.plan(availableWidth: 440, badgeWidth: 99, actionCount: 4),
                       .init(collapsedActions: 2, badge: .twoLine))
    }
}
