import XCTest
import SwiftUI
import UIKit
@testable import ImmichSwiftUI

/// Guards for the floating-control style (`PVFloatingControl.swift`): one dark
/// glass per role, drawn by `.pvFloating(…)` and nowhere else. The static
/// tests read the sources (so a later merge that writes a glass, a material or
/// a translucent black on the spot fails here), the contrast tests measure the
/// style's own tokens.
final class FloatingControlStyleTests: XCTestCase {

    // MARK: - Source reading

    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return url
    }

    private struct SourceLine {
        let number: Int
        let text: String
    }

    /// Every `.swift` file under `Sources/` (path relative to the repo root).
    private static func sourceFiles() -> [String] {
        let sources = repoRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return [] }
        var files: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(String(url.path.dropFirst(repoRoot.path.count + 1)))
        }
        return files.sorted()
    }

    /// A comment-only line is dropped; a trailing ` //` comment (outside a string
    /// literal) is cut. Lines keep their original number.
    private static func normalizedLines(_ relativePath: String) throws -> [SourceLine] {
        let url = repoRoot.appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines: [SourceLine] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            if raw.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") { continue }
            lines.append(SourceLine(number: index + 1, text: strippingTrailingComment(raw)))
        }
        return lines
    }

    private static func strippingTrailingComment(_ line: String) -> String {
        let chars = Array(line)
        var inString = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if c == "\\" { i += 2; continue }
                if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == " ", i + 2 < chars.count, chars[i + 1] == "/", chars[i + 2] == "/" {
                return String(chars[..<i])
            }
            i += 1
        }
        return line
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func matchCount(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Name of the member (`func` or `var`) declared on a line, nil if none.
    private static let declarationPattern =
        #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|public|internal|static|override|nonisolated|mutating)\s+)*(?:func|var)\s+(\w+)"#

    private static func declaredName(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: declarationPattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The nearest declaration above line `index`, or `<file>`.
    private static func enclosingMember(of index: Int, in lines: [SourceLine]) -> String {
        var j = index - 1
        while j >= 0 {
            if let name = declaredName(in: lines[j].text) { return name }
            j -= 1
        }
        return "<file>"
    }

    // MARK: - Counts per role and file

    private struct RoleCounts: Equatable {
        let circle: Int
        let pill: Int
        let bar: Int
    }

    /// The closed table of the style's call sites (29 + 22 + 9).
    private static let expectedCounts: [String: RoleCounts] = [
        "Sources/Features/PhotoViewer/PhotoViewer.swift": RoleCounts(circle: 8, pill: 5, bar: 1),
        "Sources/Features/PhotoViewer/PhotoInfoPanel.swift": RoleCounts(circle: 1, pill: 0, bar: 0),
        "Sources/Features/PhotoViewer/AssetLocationMapSheet.swift": RoleCounts(circle: 1, pill: 0, bar: 0),
        "Sources/Features/PhotoViewer/SlideshowView.swift": RoleCounts(circle: 4, pill: 2, bar: 0),
        "Sources/Features/PhotoViewer/VideoPlayerView.swift": RoleCounts(circle: 2, pill: 1, bar: 0),
        "Sources/Features/Memories/MemoryMomentView.swift": RoleCounts(circle: 3, pill: 3, bar: 0),
        "Sources/Features/Memories/MemoryEpilogueView.swift": RoleCounts(circle: 1, pill: 0, bar: 0),
        "Sources/Features/Memories/MemoriesView.swift": RoleCounts(circle: 1, pill: 1, bar: 0),
        "Sources/Features/RoadTrip/RoadTripView.swift": RoleCounts(circle: 2, pill: 2, bar: 2),
        "Sources/Features/SharedLinks/SharedLinkViewerView.swift": RoleCounts(circle: 1, pill: 1, bar: 0),
        "Sources/Features/Timeline/TimelineView.swift": RoleCounts(circle: 3, pill: 1, bar: 0),
        "Sources/Features/Timeline/TimelineScrubber.swift": RoleCounts(circle: 0, pill: 2, bar: 0),
        "Sources/Features/Search/MapView.swift": RoleCounts(circle: 2, pill: 2, bar: 1),
        "Sources/Features/Search/MapSettingsSheet.swift": RoleCounts(circle: 0, pill: 0, bar: 1),
        "Sources/Features/Search/SearchModeGlassBar.swift": RoleCounts(circle: 0, pill: 0, bar: 1),
        "Sources/Features/Albums/AlbumsView.swift": RoleCounts(circle: 0, pill: 1, bar: 0),
        "Sources/Features/Albums/ActivityFeedSheet.swift": RoleCounts(circle: 0, pill: 0, bar: 1),
        "Sources/Features/Auth/Onboarding/OnboardingFlowView.swift": RoleCounts(circle: 0, pill: 0, bar: 1),
        "Sources/Features/DownloadPanel/DownloadProgressPanel.swift": RoleCounts(circle: 0, pill: 1, bar: 0),
        "Sources/Features/Settings/LanguageToast.swift": RoleCounts(circle: 0, pill: 0, bar: 1)
    ]

    private static func counts(in relativePath: String) throws -> RoleCounts {
        let text = try normalizedLines(relativePath).map(\.text).joined(separator: "\n")
        return RoleCounts(
            circle: matchCount(#"\.pvFloating\(\.circle\)"#, in: text),
            pill: matchCount(#"\.pvFloating\(\.pill\)"#, in: text),
            bar: matchCount(#"\.pvFloating\(\.bar\)"#, in: text)
        )
    }

    private static let mediaScreens: Set<String> = [
        "Sources/Features/PhotoViewer/PhotoViewer.swift",
        "Sources/Features/PhotoViewer/SlideshowView.swift",
        "Sources/Features/Memories/MemoryMomentView.swift",
        "Sources/Features/Memories/MemoryEpilogueView.swift",
        "Sources/Features/Memories/MemoriesView.swift",
        "Sources/Features/Search/MapView.swift",
        "Sources/Features/RoadTrip/RoadTripView.swift"
    ]

    func test_AC_30_mediaScreensShareOneCircleStyle() throws {
        for path in Self.mediaScreens.sorted() {
            let expected = try XCTUnwrap(Self.expectedCounts[path])
            let actual = try Self.counts(in: path)
            XCTAssertEqual(actual.circle, expected.circle, "\(path): round buttons must use .pvFloating(.circle)")
        }
    }

    func test_AC_30_1_everyRoundButtonUsesTheCircleStyle() throws {
        var total = 0
        for path in Self.sourceFiles() {
            let actual = try Self.counts(in: path)
            total += actual.circle
            guard !Self.mediaScreens.contains(path) else { continue }
            let expected = Self.expectedCounts[path]?.circle ?? 0
            XCTAssertEqual(actual.circle, expected, "\(path): .pvFloating(.circle) count")
        }
        XCTAssertEqual(total, 29, "29 round buttons float in the app")
    }

    func test_AC_30_2_pillsAndBarsUseTheirStyle() throws {
        var pills = 0
        var bars = 0
        for path in Self.sourceFiles() {
            let actual = try Self.counts(in: path)
            pills += actual.pill
            bars += actual.bar
            let expected = Self.expectedCounts[path] ?? RoleCounts(circle: 0, pill: 0, bar: 0)
            XCTAssertEqual(actual.pill, expected.pill, "\(path): .pvFloating(.pill) count")
            XCTAssertEqual(actual.bar, expected.bar, "\(path): .pvFloating(.bar) count")
        }
        XCTAssertEqual(pills, 22)
        XCTAssertEqual(bars, 9)

        let roadTrip = try Self.normalizedLines("Sources/Features/RoadTrip/RoadTripView.swift")
        XCTAssertFalse(roadTrip.contains { $0.text.contains(".black.opacity(0.5)") },
                       "RoadTrip's export state is a floating bar, not a hand-made black fill")
        let root = try Self.normalizedLines("Sources/RootView.swift")
        XCTAssertFalse(root.contains { $0.text.contains(".presentationBackground(") },
                       "the map photo sheet keeps the system background")
    }

    // MARK: - No ad-hoc material outside the design system

    private static let materialPatterns: [(name: String, pattern: String)] = [
        ("P1", #"\.glassEffect\("#),
        ("P2", #"\.(ultraThin|thin|regular|thick|ultraThick)Material\b"#),
        ("P3", #"\.background\(\s*\.bar\b"#),
        ("P4", #"\.presentationBackground\("#),
        ("P5", #"\.background\(\s*(Color\.|\.)?(black|white)\.opacity\("#)
    ]

    /// Sites that are not floating controls (thumbnail badges, section chrome,
    /// the transparent cover of the zoom transition): file, member, pattern → max.
    private static let allowedSites: [String: Int] = [
        // L-13 moved the video tile's duration pill out of `videoBadge` into
        // `VideoDurationBadge.body` (same file, same single site).
        "AssetThumbnailCell.swift|body|P5": 1,
        "AssetThumbnailCell.swift|compactPlayIcon|P5": 1,
        "AssetThumbnailCell.swift|topLeadingBadges|P5": 2,
        "OfflineAssetsView.swift|storageUsageCard|P2": 1,
        "OfflineAssetsView.swift|searchField|P2": 1,
        "OfflineAssetsView.swift|videoBadge|P5": 1,
        "PhotoViewer.swift|body|P4": 1,
        "PhotoViewer.swift|filmstrip|P2": 1,
        "CreateAlbumSheet.swift|coverPreview|P2": 1,
        "AlbumDetailView.swift|collaboratorAvatars|P5": 1,
        "TrashView.swift|body|P2": 1
    ]

    func test_AC_30_3_noAdHocMaterialOutsideDesignSystem() throws {
        var seen: [String: Int] = [:]
        var offenders: [String] = []
        for path in Self.sourceFiles()
        where !path.hasPrefix("Sources/DesignSystem/") && !path.hasPrefix("Sources/ImmichSharedKit/") {
            let lines = try Self.normalizedLines(path)
            let file = (path as NSString).lastPathComponent
            for (index, line) in lines.enumerated() {
                for (name, pattern) in Self.materialPatterns where Self.matches(pattern, in: line.text) {
                    let member = Self.enclosingMember(of: index, in: lines)
                    let key = "\(file)|\(member)|\(name)"
                    seen[key, default: 0] += 1
                    if seen[key]! > (Self.allowedSites[key] ?? 0) {
                        offenders.append("\(path):\(line.number) \(member) \(name)")
                    }
                }
            }
        }
        XCTAssertEqual(offenders, [], "Floating controls go through .pvFloating(…) in Sources/DesignSystem")
    }

    // MARK: - Contrast (WCAG 2.x)

    static let minimumGlyphContrast = 3.0
    static let minimumTextContrast = 4.5

    private struct RGBA {
        let r: Double, g: Double, b: Double, a: Double
    }

    private static func rgba(_ color: Color, _ style: UIUserInterfaceStyle) -> RGBA {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }

    /// `foreground` composed over an opaque `background`, per sRGB component.
    private static func composite(_ foreground: RGBA, over background: RGBA) -> RGBA {
        RGBA(
            r: foreground.a * foreground.r + (1 - foreground.a) * background.r,
            g: foreground.a * foreground.g + (1 - foreground.a) * background.g,
            b: foreground.a * foreground.b + (1 - foreground.a) * background.b,
            a: 1
        )
    }

    private static func luminance(_ c: RGBA) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private struct Pair {
        let name: String
        let color: Color
        let onSelection: Bool
        let threshold: Double
        /// Ratio expected on a white photo, light appearance (the table of the specs).
        let onWhite: Double
    }

    private static let pairs: [Pair] = [
        Pair(name: "content (glyph)", color: PVFloating.content, onSelection: false, threshold: minimumGlyphContrast, onWhite: 5.74),
        Pair(name: "content (text)", color: PVFloating.content, onSelection: false, threshold: minimumTextContrast, onWhite: 5.74),
        Pair(name: "secondaryContent (text)", color: PVFloating.secondaryContent, onSelection: false, threshold: minimumTextContrast, onWhite: 4.69),
        Pair(name: "accent (glyph)", color: PVFloating.accent, onSelection: false, threshold: minimumGlyphContrast, onWhite: 3.47),
        Pair(name: "content on selection (text)", color: PVFloating.content, onSelection: true, threshold: minimumTextContrast, onWhite: 4.59)
    ]

    func test_AC_30_4_contentContrastMeetsWCAG() {
        XCTAssertEqual(Self.minimumGlyphContrast, 3.0)
        XCTAssertEqual(Self.minimumTextContrast, 4.5)
        let white = RGBA(r: 1, g: 1, b: 1, a: 1)
        let black = RGBA(r: 0, g: 0, b: 0, a: 1)

        let styles: [(String, UIUserInterfaceStyle)] = [("light", .light), ("dark", .dark)]
        for (styleName, style) in styles {
            for (photoName, photo) in [("white photo", white), ("black photo", black)] {
                let glass = Self.composite(Self.rgba(PVFloating.tint, style), over: photo)
                let selection = Self.composite(Self.rgba(PVFloating.selection, style), over: glass)
                for pair in Self.pairs {
                    let support = pair.onSelection ? selection : glass
                    let foreground = Self.composite(Self.rgba(pair.color, style), over: support)
                    let ratio = Self.contrast(foreground, support)
                    XCTAssertGreaterThanOrEqual(
                        ratio, pair.threshold,
                        "\(styleName) · \(photoName) · \(pair.name): \(ratio):1 < \(pair.threshold):1"
                    )
                    if styleName == "light", photoName == "white photo" {
                        XCTAssertEqual(ratio, pair.onWhite, accuracy: 0.02, "\(pair.name) on a white photo")
                    }
                }
            }
        }
    }

    func test_AC_30_4_accentIsThePrimaryAccentResolvedInDark() {
        let accent = Self.rgba(PVFloating.accent, .light)
        let primaryDark = Self.rgba(Color.immichPrimary, .dark)
        XCTAssertEqual(accent.r, primaryDark.r, accuracy: 1.0 / 255)
        XCTAssertEqual(accent.g, primaryDark.g, accuracy: 1.0 / 255)
        XCTAssertEqual(accent.b, primaryDark.b, accuracy: 1.0 / 255)
        // The same value in both appearances.
        let accentDark = Self.rgba(PVFloating.accent, .dark)
        XCTAssertEqual(accent.r, accentDark.r, accuracy: 1.0 / 255)
        XCTAssertEqual(accent.b, accentDark.b, accuracy: 1.0 / 255)
    }

    // MARK: - Floating members draw only floating colours

    private static let floatingMembers: [String: [String]] = [
        "Sources/Features/PhotoViewer/PhotoViewer.swift": ["actions", "topBarPill", "bottomBar", "header", "ocrStatusCapsule"],
        "Sources/Features/Albums/ActivityFeedSheet.swift": ["composer"],
        "Sources/Features/Timeline/TimelineView.swift": ["backupProgressRing"],
        "Sources/Features/Search/SearchModeGlassBar.swift": ["body", "segmentButton"],
        "Sources/Features/Settings/LanguageToast.swift": ["body"],
        "Sources/Features/Search/MapView.swift": ["activeFilterBadge", "settingsButton", "myLocationButton", "filteredEmptyOverlay"],
        "Sources/Features/PhotoViewer/AssetLocationMapSheet.swift": ["doneButton"],
        "Sources/Features/DownloadPanel/DownloadProgressPanel.swift": ["body"]
    ]

    private static let foreignColorPatterns = [
        #"\b(immichPrimary|immichError|immichSuccess|immichWarning|textPrimaryPV|textSecondaryPV|textTertiaryPV|bgPrimary|bgSecondary|bgTertiary)\b"#,
        #"Color\.(primary|secondary)\b"#,
        #"\(\s*\.(primary|secondary)\s*\)"#
    ]

    func test_AC_30_4_floatingMembersDrawOnlyFloatingColors() throws {
        var offenders: [String] = []
        for (path, members) in Self.floatingMembers.sorted(by: { $0.key < $1.key }) {
            let lines = try Self.normalizedLines(path)
            for member in members {
                let starts = lines.indices.filter { Self.declaredName(in: lines[$0].text) == member }
                XCTAssertFalse(starts.isEmpty, "\(path): member \(member) not found — update the table after a rename")
                for start in starts {
                    var end = start + 1
                    while end < lines.count, Self.declaredName(in: lines[end].text) == nil { end += 1 }
                    for index in start..<end {
                        for pattern in Self.foreignColorPatterns where Self.matches(pattern, in: lines[index].text) {
                            offenders.append("\(path):\(lines[index].number) \(member)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(offenders, [], "Colours on the glass come from PVFloating")
    }
}
