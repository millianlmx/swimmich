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

    // MARK: - Accent contrast (AC-1, WCAG 2.x: glyph >= 3:1, text >= 4.5:1)

    private func luminance(_ rgb: [Double]) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2])
    }

    private func contrast(_ a: [Double], _ b: [Double]) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `foreground` at `alpha` over an opaque `background`.
    private func over(_ foreground: [Double], alpha: Double, _ background: [Double]) -> [Double] {
        zip(foreground, background).map { alpha * $0 + (1 - alpha) * $1 }
    }

    /// The real surfaces the accent is read on, per appearance: the app's own
    /// background tokens, the system backgrounds of lists and forms, and the
    /// tertiary fill of subtle buttons and cards.
    private func surfaces(_ style: UIUserInterfaceStyle) -> [(String, [Double])] {
        let trait = UITraitCollection(userInterfaceStyle: style)
        func system(_ color: UIColor) -> [Double] { components(Color(uiColor: color.resolvedColor(with: trait))) }
        return [
            ("immichBackground", components(Color.immichBackground, style)),
            ("immichGray", components(Color.immichGray, style)),
            ("systemBackground", system(.systemBackground)),
            ("secondarySystemBackground", system(.secondarySystemBackground)),
            ("systemGroupedBackground", system(.systemGroupedBackground)),
            ("secondarySystemGroupedBackground", system(.secondarySystemGroupedBackground))
        ]
    }

    /// Accent as text on every surface, and on the 12 % / 14 % accent washes
    /// behind icon tiles and selected rows, in light and in dark.
    func test_AC_1_accentAsTextMeetsTextContrastOnRealSurfaces() {
        for (styleName, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let accent = components(Color.immichPrimary, style)
            for (name, surface) in surfaces(style) {
                XCTAssertGreaterThanOrEqual(contrast(accent, surface), 4.5, "\(styleName) · accent on \(name)")
                for wash in [0.12, 0.14] {
                    let tinted = over(accent, alpha: wash, surface)
                    XCTAssertGreaterThanOrEqual(
                        contrast(accent, tinted), 4.5, "\(styleName) · accent on \(name) + \(wash) accent wash"
                    )
                }
            }
        }
    }

    /// Content on an accent fill (CTA label, counter badge, initials): white
    /// read 1.66:1 on the dark pale blue before `immichOnPrimary`.
    func test_AC_1_contentOnAccentFillMeetsTextContrastInBothAppearances() {
        for (styleName, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let ratio = contrast(components(Color.immichOnPrimary, style), components(Color.immichPrimary, style))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(styleName) · immichOnPrimary on immichPrimary: \(ratio):1")
        }
        let whiteOnDarkAccent = contrast([1, 1, 1], components(Color.immichPrimary, .dark))
        XCTAssertLessThan(whiteOnDarkAccent, 4.5, "white on the dark accent fill is the defect immichOnPrimary fixes")
    }

    /// Layers drawn on the viewer's black (OCR boxes): the light accent sat at
    /// 2.996:1 there, a hair under the glyph bar; the floating accent is fixed.
    func test_AC_1_accentGlyphOnViewerBlackMeetsGlyphContrastInBothAppearances() {
        let black = [0.0, 0.0, 0.0]
        XCTAssertLessThan(contrast(components(Color.immichPrimary, .light), black), 3.0)
        for (styleName, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let ratio = contrast(components(PVFloating.accent, style), black)
            XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(styleName) · PVFloating.accent on black: \(ratio):1")
        }
    }

    /// `.borderedProminent` fills with the root tint, the accent picked in
    /// Preferences, and keeps a white system label: 1.66:1 on the dark brand
    /// accent. Its label takes `AppAccent.onColor`: every preset, light and dark.
    func test_AC_1_prominentButtonLabelMeetsTextContrastOnEveryAccent() {
        for accent in AppAccent.allCases {
            for (styleName, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                let ratio = contrast(components(accent.onColor, style), components(accent.color, style))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(styleName) · label on the \(accent.rawValue) fill: \(ratio):1")
            }
        }
    }

    /// No `.borderedProminent` bypasses `pvProminentButtonStyle()`, which gives
    /// the label the tint's ink. The photo editor's Revert button is tinted red,
    /// not by the accent, and stays out of this feature.
    func test_AC_1_prominentButtonsTakeTheTintInk() throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("project.yml").path) {
            root.deleteLastPathComponent()
        }
        let allowed: Set<String> = ["Sources/Features/Editor/PhotoEditorView.swift"]
        var offenders: [String] = []
        var scanned = 0
        for folder in ["Sources", "ImmichShareExtension", "ImmichWidgets"] {
            let base = root.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let path as String in files where path.hasSuffix(".swift") {
                let relative = "\(folder)/\(path)"
                guard !relative.hasPrefix("Sources/DesignSystem/"), !allowed.contains(relative) else { continue }
                scanned += 1
                let source = try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
                for (index, line) in source.components(separatedBy: "\n").enumerated()
                where line.contains(".borderedProminent") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    offenders.append("\(relative):\(index + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the scan must reach the app's sources")
        XCTAssertEqual(offenders, [], "use `pvProminentButtonStyle()` so the label reads on the tint")
    }

    /// The identifiers that are not visible stay what they were: a renamed
    /// bundle ID, widget kind or URL scheme would orphan installs, widgets and
    /// the scheduled backup task. (The former mark's colour checks went with
    /// the mark: the app's logo is now its icon, `SwimmichLogo`.)
    func test_AC_29_3_identifiersStay() throws {
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
