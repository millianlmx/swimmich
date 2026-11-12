import XCTest
import SwiftUI
@testable import ImmichSwiftUI

/// Token + foundation sanity tests for the PhotoVault Design System.
/// These exercise compile-time + value correctness of the non-UI tokens;
/// SwiftUI View/ButtonStyle bodies are covered structurally by build + the
/// component AC grep checks.
final class DesignSystemTokensTests: XCTestCase {

    func testSpacingValues() {
        XCTAssertEqual(PVSpacing.s0, 0)
        XCTAssertEqual(PVSpacing.s2, 2)
        XCTAssertEqual(PVSpacing.s4, 4)
        XCTAssertEqual(PVSpacing.s8, 8)
        XCTAssertEqual(PVSpacing.s12, 12)
        XCTAssertEqual(PVSpacing.s16, 16)
        XCTAssertEqual(PVSpacing.s24, 24)
        XCTAssertEqual(PVSpacing.s32, 32)
        XCTAssertEqual(PVSpacing.s48, 48)
    }

    func testRadiusValues() {
        // Immich-aligned radius scale: none/xs/sm/md/lg/xl/xxl/full.
        XCTAssertEqual(PVRadius.none, 0)
        XCTAssertEqual(PVRadius.xs, 4)
        XCTAssertEqual(PVRadius.sm, 8)
        XCTAssertEqual(PVRadius.md, 12)
        XCTAssertEqual(PVRadius.lg, 16)
        XCTAssertEqual(PVRadius.xl, 20)
        XCTAssertEqual(PVRadius.xxl, 24)
        XCTAssertEqual(PVRadius.full, 999)
    }

    /// AC-020 (partial): ensure color tokens initialize without throwing /
    /// crashing. Asset resolution is lazy; init merely registers the asset name.
    func testColorTokenResolution() {
        let indigo: Color? = Color.brandIndigo
        XCTAssertNotNil(indigo)

        let text: Color? = Color.textPrimaryPV
        XCTAssertNotNil(text)
    }

    // MARK: - Brand (AC-29.3)

    private func components(_ color: Color, _ style: UIUserInterfaceStyle? = nil) -> [Double] {
        var ui = UIColor(color)
        if let style { ui = ui.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)) }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b)]
    }

    private func assertSame(_ lhs: [Double], _ rhs: [Double], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for (l, r) in zip(lhs, rhs) {
            XCTAssertEqual(l, r, accuracy: 1.0 / 255, message, file: file, line: line)
        }
    }

    /// The mark is drawn in the app's accent, not in Immich's official colours,
    /// and the identifiers that are not visible stay what they were: a renamed
    /// bundle ID, widget kind or URL scheme would orphan installs, widgets and
    /// the scheduled backup task.
    func test_AC_29_3_markUsesTheAccentAndIdentifiersStay() throws {
        let primaryLight = components(Color.immichPrimary, .light)
        let primaryDark = components(Color.immichPrimary, .dark)
        assertSame(components(Color.immichLogoDeep), primaryLight, "immichLogoDeep is immichPrimary in light appearance")
        assertSame(components(Color.immichLogoLight), primaryDark, "immichLogoLight is immichPrimary in dark appearance")

        let official: [(String, [Double])] = [
            ("#FA2921", [250.0 / 255, 41.0 / 255, 33.0 / 255]),
            ("#ED79B5", [237.0 / 255, 121.0 / 255, 181.0 / 255]),
            ("#FFB400", [255.0 / 255, 180.0 / 255, 0.0 / 255]),
            ("#1E83F7", [30.0 / 255, 131.0 / 255, 247.0 / 255]),
            ("#18C249", [24.0 / 255, 194.0 / 255, 73.0 / 255])
        ]
        for (name, rgb) in official {
            for color in [Color.immichLogoLight, Color.immichLogoDeep] {
                let c = components(color)
                let isOfficial = zip(c, rgb).allSatisfy { abs($0 - $1) <= 1.0 / 255 }
                XCTAssertFalse(isOfficial, "the mark must not use the official Immich colour \(name)")
            }
        }

        XCTAssertNotNil(AppAccent(rawValue: "immich"), "a stored accent `immich` must stay valid")

        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path) {
            root.deleteLastPathComponent()
        }
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let lines = Set(project.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        for expected in [
            "PRODUCT_BUNDLE_IDENTIFIER: fr.millianlmx.immich-ios",
            "PRODUCT_BUNDLE_IDENTIFIER: fr.millianlmx.immich-ios.widgets",
            "PRODUCT_BUNDLE_IDENTIFIER: fr.millianlmx.immich-ios.share-extension",
            "PRODUCT_BUNDLE_IDENTIFIER: fr.millianlmx.immich-ios.sharedkit",
            "- app.immich",
            "- app.immich.background-backup"
        ] {
            XCTAssertTrue(lines.contains(expected), "project.yml must still declare `\(expected)`")
        }
    }
}
