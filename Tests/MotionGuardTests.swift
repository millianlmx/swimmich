import XCTest
@testable import ImmichSwiftUI

/// Static guard (AC-173): every site of the app that starts an animation, a
/// transition, a loop or a full-screen presentation goes through the motion gate
/// (`PVMotion`, `@PVReduceMotion`, `.pvFullScreenCover`, `.pvScrollEffect`,
/// `.pvSymbolBounce`), or is a named exclusion with its reason. The test reads
/// the sources, so a later site that animates on its own fails here.
///
/// Scope: every `.swift` file of `Sources/`, except `Sources/ImmichSharedKit/`
/// (widgets, live activity and share extension are out of the setting) and the
/// three files of the gate itself.
final class MotionGuardTests: XCTestCase {

    // MARK: - Tables

    /// Sites that do not pass their rule but are allowed, with the reason.
    /// Key: `<File.swift>|<enclosing member>|<label>`; value: exact count.
    private static let exclusions: [String: Int] = [
        // Body of the viewer's `animate` helper; its callers are checked by the `animate` rule.
        "PhotoViewer.swift|animate|withAnimation": 1,
        // `animate(PVMotion.standard)` of the `.zoom` branches only: `ViewerZoomPlan.openStyle`
        // and `closeStyle` never rule `.zoom` under Reduce Motion (test_AC_163).
        "PhotoViewer.swift|runOpeningTransition|animate": 1,
        "PhotoViewer.swift|route|animate": 1,
        // `performClose`: opacity only (`backdropOpacity`, 0.1 s).
        "PhotoViewer.swift|route|withAnimation": 1,
        // Fade of the video poster: `posterOpacity`, opacity only.
        "VideoPlayerView.swift|handOffPoster|withAnimation": 1,
        // The `.fade` page change of the memory player: `fadeOpacity`, opacity only,
        // chosen under Reduce Motion.
        "MemoryPlaybackView.swift|showModelPage|withAnimation": 2,
        // Slideshow, already conformant: `slideTransition` is `.opacity` under the setting and
        // `transitionAnimation` goes through `PVMotion.fading`.
        "SlideshowView.swift|body|transition": 1,
        "SlideshowView.swift|body|animation": 1,
        // `window.alpha` only, in the branch where `PVMotion.isReduced` is false.
        "AppLockWindowController.swift|apply|UIView.animate": 1,
    ]

    /// Every use of `PVMotion.fading(` / `PVMotion.fade`: opacity-only sites.
    private static let fades: [String: Int] = [
        "PVRatingBar.swift|body|fading": 1,
        "AuthenticatedAsyncImage.swift|body|fading": 1,
        "PhotoViewer.swift|topBarPill|fading": 1,
        "SlideshowView.swift|transitionAnimation|fading": 2,
        "TimelineScrubber.swift|scheduleLabelFade|fading": 1,
        // `animate(PVMotion.fade)` of the viewer's fade open and close, opacities only.
        "PhotoViewer.swift|runOpeningTransition|fade": 1,
        "PhotoViewer.swift|route|fade": 1,
    ]

    private static let gateFiles: Set<String> = [
        "Sources/DesignSystem/Tokens/Motion+PhotoVault.swift",
        "Sources/DesignSystem/Components/PVMotionModifiers.swift",
        "Sources/DesignSystem/Components/PVFullScreenCover.swift",
    ]

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

    /// Every `.swift` file under `Sources/` in scope, as (relative path, text).
    private static func scopedFiles() throws -> [(name: String, text: String)] {
        let sources = repoRoot.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else { return [] }
        var files: [(name: String, text: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            if relative.hasPrefix("Sources/ImmichSharedKit/") || gateFiles.contains(relative) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            files.append((relative, text))
        }
        return files.sorted { $0.name < $1.name }
    }

    /// A comment-only line is dropped; a trailing ` //` comment (outside a string
    /// literal) is cut. Lines keep their original number.
    private static func normalizedLines(_ text: String) -> [SourceLine] {
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

    // MARK: - Argument reading (UTF-16 units of the joined, normalized text)

    private static let quote: UInt16 = 34
    private static let backslash: UInt16 = 92

    /// The text between the parenthesis at `open` and its match, string literals skipped.
    private static func balancedArguments(in units: [UInt16], openAt open: Int) -> String? {
        var depth = 0
        var inString = false
        var j = open
        while j < units.count {
            let c = units[j]
            if inString {
                if c == backslash { j += 2; continue }
                if c == quote { inString = false }
            } else if c == quote {
                inString = true
            } else if c == 40 || c == 91 || c == 123 {            // ( [ {
                depth += 1
            } else if c == 41 || c == 93 || c == 125 {            // ) ] }
                depth -= 1
                if depth == 0 { return String(utf16CodeUnits: Array(units[(open + 1)..<j]), count: j - open - 1) }
            }
            j += 1
        }
        return nil
    }

    /// Text up to the first comma of the top level, trimmed.
    private static func firstArgument(_ arguments: String) -> String {
        let units = Array(arguments.utf16)
        var depth = 0
        var inString = false
        var j = 0
        while j < units.count {
            let c = units[j]
            if inString {
                if c == backslash { j += 2; continue }
                if c == quote { inString = false }
            } else if c == quote {
                inString = true
            } else if c == 40 || c == 91 || c == 123 {
                depth += 1
            } else if c == 41 || c == 93 || c == 125 {
                depth -= 1
            } else if c == 44, depth == 0 {                       // ,
                return String(utf16CodeUnits: Array(units[..<j]), count: j).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            j += 1
        }
        return arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func startsWithGateToken(_ argument: String) -> Bool {
        argument.hasPrefix("PVMotion.movement(")
            || argument.hasPrefix("PVMotion.fading(")
            || argument.hasPrefix("PVMotion.shimmerLoop(")
            || argument.range(of: #"^PVMotion\.fade\b"#, options: .regularExpression) != nil
    }

    private static func gateTokenOrNil(_ argument: String) -> Bool {
        argument == "nil" || startsWithGateToken(argument)
    }

    // MARK: - Rules

    private enum Rule {
        case withAnimation, animation, animate, transaction, animationAssignment
        case transition, contentTransition, never, reduceMotionFlagLine
    }

    private static let rules: [(label: String, pattern: String, rule: Rule)] = [
        ("withAnimation", #"\bwithAnimation\b"#, .withAnimation),
        ("animation", #"\.animation\("#, .animation),
        ("animate", #"(?<![\w.])animate\("#, .animate),
        ("Transaction", #"\bTransaction\("#, .transaction),
        (".animation =", #"\.animation\s*=(?!=)"#, .animationAssignment),
        ("UIView.animate", #"\bUIView\.(?:animate|transition)\b|\bUIViewPropertyAnimator\b"#, .never),
        ("transition", #"\.transition\("#, .transition),
        ("contentTransition", #"\.contentTransition\("#, .contentTransition),
        ("scrollTransition", #"\.scrollTransition\b"#, .never),
        ("repeatForever", #"\brepeatForever\b"#, .never),
        // `.contentTransition(PVMotion.contentChange(.symbolEffect(.replace), …))` is the gated form.
        ("symbolEffect", #"(?<!contentChange\()\.symbolEffect\("#, .never),
        ("fullScreenCover", #"\.fullScreenCover\("#, .never),
        ("accessibilityReduceMotion", #"accessibilityReduceMotion"#, .never),
        ("isReduceMotionEnabled", #"isReduceMotionEnabled"#, .reduceMotionFlagLine),
        ("reduceMotion literal", #"\breduceMotion:\s*(?:true|false)\b"#, .never),
        ("adaptive", #"PVMotion\.adaptive"#, .never),
    ]

    struct AuditResult {
        /// `path:line member label`, one per fault.
        var faults: [String] = []
        /// Count of sites that did not pass their rule, by `<File>|<member>|<label>`.
        var unpassed: [String: Int] = [:]
        /// Count of `PVMotion.fading(` / `PVMotion.fade`, by the same key.
        var fadeUses: [String: Int] = [:]
    }

    /// Audits (name, text) pairs. Exposed for the self-test of the rules.
    static func audit(_ files: [(name: String, text: String)]) -> AuditResult {
        var result = AuditResult()
        var unpassedSites: [String: [String]] = [:]
        var fadeSites: [String: [String]] = [:]

        for file in files {
            let lines = normalizedLines(file.text)
            let joined = lines.map(\.text).joined(separator: "\n")
            let units = Array(joined.utf16)
            let nsJoined = joined as NSString
            // Start offset (UTF-16) of each normalized line.
            var starts: [Int] = []
            var offset = 0
            for line in lines {
                starts.append(offset)
                offset += (line.text as NSString).length + 1
            }
            func lineIndex(of location: Int) -> Int {
                var low = 0, high = starts.count - 1
                while low < high {
                    let mid = (low + high + 1) / 2
                    if starts[mid] <= location { low = mid } else { high = mid - 1 }
                }
                return low
            }
            let base = (file.name as NSString).lastPathComponent
            func key(_ index: Int, _ label: String) -> String {
                "\(base)|\(enclosingMember(of: index, in: lines))|\(label)"
            }
            func site(_ index: Int, _ label: String) -> String {
                "\(file.name):\(lines[index].number) \(enclosingMember(of: index, in: lines)) \(label)"
            }

            for (label, pattern, rule) in rules {
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    result.faults.append("bad pattern \(pattern)")
                    continue
                }
                for match in regex.matches(in: joined, range: NSRange(location: 0, length: nsJoined.length)) {
                    let index = lineIndex(of: match.range.location)
                    let lineText = lines[index].text
                    let end = match.range.location + match.range.length
                    var passes = false
                    switch rule {
                    case .withAnimation:
                        var k = end
                        while k < units.count, units[k] == 32 || units[k] == 10 || units[k] == 9 { k += 1 }
                        if k < units.count, units[k] == 40, let args = balancedArguments(in: units, openAt: k) {
                            passes = gateTokenOrNil(firstArgument(args))
                        }
                    case .animation:
                        if let args = balancedArguments(in: units, openAt: end - 1) {
                            let first = firstArgument(args)
                            passes = gateTokenOrNil(first) || first.hasPrefix("minimumInterval:")
                        }
                    case .animate:
                        if lineText.contains("func animate(") { continue }
                        if let args = balancedArguments(in: units, openAt: end - 1) {
                            let first = firstArgument(args)
                            passes = first == "PVMotion.fade" || first.hasPrefix("PVMotion.fading(")
                        }
                    case .transaction:
                        guard let args = balancedArguments(in: units, openAt: end - 1) else { continue }
                        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("animation:") else { continue }      // `Transaction()` alone
                        let value = firstArgument(String(trimmed.dropFirst("animation:".count)))
                        passes = gateTokenOrNil(value)
                    case .animationAssignment:
                        let rest = nsJoined.substring(from: end)
                            .prefix(while: { $0 != "\n" })
                            .trimmingCharacters(in: .whitespaces)
                        passes = rest.hasPrefix("nil") || startsWithGateToken(rest)
                    case .transition:
                        if let args = balancedArguments(in: units, openAt: end - 1) {
                            let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
                            passes = trimmed == ".opacity" || trimmed.hasPrefix("PVMotion.appearance(")
                        }
                    case .contentTransition:
                        if let args = balancedArguments(in: units, openAt: end - 1) {
                            let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
                            passes = trimmed == ".opacity" || trimmed == ".identity"
                                || trimmed.hasPrefix("PVMotion.contentChange(")
                        }
                    case .reduceMotionFlagLine:
                        passes = lineText.contains("PVMotion.isReduced(")
                    case .never:
                        passes = false
                    }
                    if !passes {
                        let k = key(index, label)
                        result.unpassed[k, default: 0] += 1
                        unpassedSites[k, default: []].append(site(index, label))
                    }
                }
            }

            // Opacity-only sites: every use is counted, whether or not it passed a rule.
            for (label, pattern) in [("fading", #"PVMotion\.fading\("#), ("fade", #"\bPVMotion\.fade\b"#)] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: joined, range: NSRange(location: 0, length: nsJoined.length)) {
                    let index = lineIndex(of: match.range.location)
                    let k = key(index, label)
                    result.fadeUses[k, default: 0] += 1
                    fadeSites[k, default: []].append(site(index, label))
                }
            }
        }

        for (k, count) in result.unpassed where count > (exclusions[k] ?? 0) {
            result.faults.append(contentsOf: unpassedSites[k] ?? [k])
        }
        for (k, count) in result.fadeUses where count > (fades[k] ?? 0) {
            result.faults.append(contentsOf: fadeSites[k] ?? [k])
        }
        result.faults.sort()
        return result
    }

    // MARK: - Tests

    func test_AC_173_everyMotionSiteGoesThroughTheGate() throws {
        let files = try Self.scopedFiles()
        XCTAssertFalse(files.isEmpty, "no sources found under \(Self.repoRoot.path)")
        let faults = Self.audit(files).faults
        XCTAssertTrue(
            faults.isEmpty,
            "Motion sites that bypass the gate (path:line member label):\n" + faults.joined(separator: "\n")
        )
    }

    func test_AC_173_exclusionsAreAllUsed() throws {
        let result = Self.audit(try Self.scopedFiles())
        for (k, allowed) in Self.exclusions {
            XCTAssertEqual(result.unpassed[k] ?? 0, allowed, "exclusion \(k) is not reached exactly \(allowed) time(s)")
        }
        for (k, allowed) in Self.fades {
            XCTAssertEqual(result.fadeUses[k] ?? 0, allowed, "fade site \(k) is not reached exactly \(allowed) time(s)")
        }
    }

    func test_AC_173_ruleCatchesUngatedSites() {
        let mustFail = [
            "withAnimation(PVMotion.snappy) {",
            "withAnimation { x = 1 }",
            "withAnimation(PVMotion.fading(PVMotion.snappy, reduceMotion: reduceMotion)) { scale = 3 }",
            ".animation(PVMotion.fade, value: x)",
            "withAnimation(PVMotion.movement(PVMotion.snappy, reduceMotion: false)) {",
            "withAnimation(flag ? PVMotion.movement(.snappy, reduceMotion: reduceMotion) : .spring()) {",
            "await animate(PVMotion.standard) {",
            "UIView.animate(withDuration: 0.2) {",
            "withTransaction(Transaction(animation: .spring())) {",
            "t.animation = .spring()",
            ".transition(.scale)",
            ".contentTransition(.numericText())",
            ".fullScreenCover(item: $x) {",
            ".scrollTransition { c, p in",
        ]
        for snippet in mustFail {
            let faults = Self.audit([("Snippet.swift", snippet)]).faults
            XCTAssertFalse(faults.isEmpty, "should fail: \(snippet)")
        }
        let mustPass = [
            ".animation(PVMotion.movement(PVMotion.snappy, reduceMotion: reduceMotion), value: x)",
            ".transition(.opacity)",
            "withAnimation(nil) {",
            "t.animation = nil",
            "withTransaction(Transaction(animation: PVMotion.movement(.spring(), reduceMotion: reduceMotion))) {",
            "SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30.0))",
            "private func animate(_ animation: Animation, _ body: @escaping () -> Void) async {",
        ]
        for snippet in mustPass {
            let faults = Self.audit([("Snippet.swift", snippet)]).faults
            XCTAssertTrue(faults.isEmpty, "should pass: \(snippet) — \(faults)")
        }
    }

    func test_AC_171_fiveCoversUseTheGate() throws {
        let owners = [
            "PhotoViewer.swift", "AlbumDetailView.swift", "MemoriesView.swift",
            "OfflineAssetsView.swift", "SharedLinkViewerView.swift",
        ]
        var counts: [String: Int] = [:]
        // The gate's own file is outside `scopedFiles()`: only presenters are counted here.
        for file in try Self.scopedFiles() {
            let text = Self.normalizedLines(file.text).map(\.text).joined(separator: "\n")
            let count = text.components(separatedBy: ".pvFullScreenCover(").count - 1
            if count > 0 { counts[(file.name as NSString).lastPathComponent] = count }
        }
        for owner in owners {
            XCTAssertEqual(counts[owner], 1, "\(owner) must present through .pvFullScreenCover exactly once")
        }
        let others = counts.keys.filter { !owners.contains($0) }.sorted()
        XCTAssertTrue(others.isEmpty, "full-screen covers outside the five known presenters: \(others)")
    }
}
