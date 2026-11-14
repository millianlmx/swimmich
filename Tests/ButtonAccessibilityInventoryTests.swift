import XCTest
@testable import ImmichSwiftUI

// MARK: - Source text

private enum Ch {
    static let quote: UInt16 = 34
    static let backslash: UInt16 = 92
    static let lparen: UInt16 = 40
    static let rparen: UInt16 = 41
    static let lbrace: UInt16 = 123
    static let rbrace: UInt16 = 125
    static let lbracket: UInt16 = 91
    static let rbracket: UInt16 = 93
    static let slash: UInt16 = 47
    static let star: UInt16 = 42
    static let comma: UInt16 = 44
    static let newline: UInt16 = 10
    static let space: UInt16 = 32
    static let tab: UInt16 = 9
    static let cr: UInt16 = 13
    static let dot: UInt16 = 46
}

/// A source text as UTF-16 units: the offsets of `NSRegularExpression` matches
/// are then the indices of the array.
private struct Text16 {
    let u: [UInt16]

    init(_ s: String) { u = Array(s.utf16) }
    init(units: [UInt16]) { u = units }

    var count: Int { u.count }
    var string: String { String(decoding: u, as: UTF16.self) }

    func at(_ i: Int) -> UInt16 { (i >= 0 && i < u.count) ? u[i] : 0 }

    func sub(_ a: Int, _ b: Int) -> String {
        let lo = max(0, min(a, u.count))
        let hi = max(lo, min(b, u.count))
        return String(decoding: u[lo..<hi], as: UTF16.self)
    }

    func has(_ s: String, at i: Int) -> Bool {
        let p = Array(s.utf16)
        if i < 0 || i + p.count > u.count { return false }
        for k in 0..<p.count where u[i + k] != p[k] { return false }
        return true
    }

    func find(_ s: String, from start: Int) -> Int? {
        let p = Array(s.utf16)
        if p.isEmpty || u.count < p.count { return nil }
        var i = max(0, start)
        while i + p.count <= u.count {
            var same = true
            for k in 0..<p.count where u[i + k] != p[k] { same = false; break }
            if same { return i }
            i += 1
        }
        return nil
    }

    func isWS(_ c: UInt16) -> Bool { c == Ch.space || c == Ch.newline || c == Ch.tab || c == Ch.cr }
    func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    func isIdent(_ c: UInt16) -> Bool { isLetter(c) || (c >= 48 && c <= 57) || c == 95 }

    func skipWS(_ i: Int) -> Int {
        var k = i
        while k < u.count && isWS(u[k]) { k += 1 }
        return k
    }

    /// `start` is the opening quote; returns the index after the closing one.
    func skipString(_ start: Int) -> Int {
        if has("\"\"\"", at: start) {
            if let e = find("\"\"\"", from: start + 3) { return e + 3 }
            return u.count
        }
        var i = start + 1
        while i < u.count {
            let c = u[i]
            if c == Ch.backslash {
                if at(i + 1) == Ch.lparen {
                    i = skipBalanced(i + 1, Ch.lparen, Ch.rparen)
                    continue
                }
                i += 2
                continue
            }
            if c == Ch.quote { return i + 1 }
            if c == Ch.newline { return i }
            i += 1
        }
        return i
    }

    /// `start` is the opening delimiter; returns the index after the matching
    /// closing one. String literals (and their interpolations) are skipped.
    func skipBalanced(_ start: Int, _ open: UInt16, _ close: UInt16) -> Int {
        var depth = 0
        var i = start
        while i < u.count {
            let c = u[i]
            if c == Ch.quote {
                i = skipString(i)
                continue
            }
            if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 { return i + 1 }
            }
            i += 1
        }
        return u.count
    }

    /// Splits at the commas of the first nesting level.
    func splitTop() -> [String] {
        var parts: [String] = []
        var depth = 0
        var start = 0
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == Ch.quote {
                i = skipString(i)
                continue
            }
            if c == Ch.lparen || c == Ch.lbracket || c == Ch.lbrace {
                depth += 1
            } else if c == Ch.rparen || c == Ch.rbracket || c == Ch.rbrace {
                depth -= 1
            } else if c == Ch.comma && depth == 0 {
                parts.append(sub(start, i))
                start = i + 1
            }
            i += 1
        }
        parts.append(sub(start, u.count))
        return parts
    }

    struct Mod {
        let name: String
        let args: String?
        let start: Int
        let end: Int
    }

    /// The modifiers (`.name(args) { closure }`) that follow `from`, across lines.
    func parseChain(_ from: Int) -> (mods: [Mod], end: Int) {
        var mods: [Mod] = []
        var i = from
        while true {
            let j = skipWS(i)
            guard at(j) == Ch.dot, isLetter(at(j + 1)) else { return (mods, i) }
            var k = j + 1
            while k < u.count && isIdent(u[k]) { k += 1 }
            let name = sub(j + 1, k)
            var args: String?
            if at(k) == Ch.lparen {
                let e = skipBalanced(k, Ch.lparen, Ch.rparen)
                args = sub(k + 1, e - 1)
                k = e
            }
            var m = k
            while at(m) == Ch.space || at(m) == Ch.tab { m += 1 }
            if at(m) == Ch.lbrace { k = skipBalanced(m, Ch.lbrace, Ch.rbrace) }
            mods.append(Mod(name: name, args: args, start: j, end: k))
            i = k
        }
    }

    struct Literal {
        let raw: String
        let start: Int
        let verbatim: Bool
    }

    /// The string literals of an expression, outside of the nested ones.
    func literals() -> [Literal] {
        var result: [Literal] = []
        var i = 0
        while i < u.count {
            if u[i] == Ch.quote {
                let e = skipString(i)
                let before = sub(max(0, i - 40), i)
                let verbatim = before.range(of: #"verbatim:\s*$"#, options: .regularExpression) != nil
                result.append(Literal(raw: sub(i, e), start: i, verbatim: verbatim))
                i = e
                continue
            }
            i += 1
        }
        return result
    }
}

// MARK: - Scanner

/// Pure scanner of the SwiftUI sources: every `Button`, `Menu`, `ShareLink`,
/// `NavigationLink` and `Link` whose label shows no text, and every tap
/// gesture, must carry a translated accessibility label (L-19, AC-34.1).
enum ButtonScanner {

    struct Finding: Equatable, CustomStringConvertible {
        let path: String
        let line: Int
        let reason: String
        var description: String { "\(path):\(line) \(reason)" }
    }

    struct Count {
        let count: Int
        let reason: String
    }

    enum Carrier {
        /// A modifier chain with this identifier prefix carries the label and the button trait.
        case identifierPrefix(String)
        /// A view of the same file whose body carries the label.
        case viewBody(String)
    }

    struct Elsewhere {
        let count: Int
        let carrier: Carrier
        let reason: String
    }

    /// The closed tables. A key is `<file name>|<member>`, the member being the
    /// nearest `func` or `var` declared above the site (a local `var` becomes
    /// the member: the key is what the scanner reads, not what a human would).
    struct Tables {
        /// Tap gestures that open nothing: the exact number of gestures of the member, with the why.
        var tapExemptions: [String: Count]
        /// Sites whose label lives on another element: gesture → identifier prefix, control → view body.
        var labelledElsewhere: [String: Elsewhere]
        /// `<file name>|<expression>` of a label built from translated pieces, typed `String`.
        var stringLabelBuilders: [String: String]
        /// Controls whose label view shows the name of what they open (a view, or a verbatim name).
        var opaqueTextBearing: [String: Count]
        /// `<file name>|<member>` of controls whose announced label differs from their visible text.
        var visibleTextExceptions: [String: String]
    }

    struct TitleCheck {
        let path: String
        let line: Int
        let member: String
        let titleKey: String
        let labelKey: String
    }

    struct Analysis {
        var findings: [Finding] = []
        /// Catalog keys that the labels resolve to.
        var keys: Set<String> = []
        /// Tap gestures per `<file name>|<member>`.
        var gestureSites: [String: Int] = [:]
        /// Icon or opaque controls without label of their own, per `<file name>|<member>`.
        var unlabelledControls: [String: Int] = [:]
        /// Builders of `stringLabelBuilders` that a site used.
        var usedBuilders: Set<String> = []
        var titleChecks: [TitleCheck] = []
    }

    static let production = Tables(
        tapExemptions: [
            "TimelineView.swift|auth": Count(count: 1, reason: "Fond de la grille : un toucher quitte la sélection, déjà proposé par le bouton Cancel de la barre."),
            "AlbumDetailView.swift|content": Count(count: 1, reason: "Fond de la grille : un toucher quitte la sélection, déjà proposé par le bouton Cancel de la barre."),
            "SlideshowView.swift|body": Count(count: 1, reason: "Affiche ou masque les commandes du diaporama ; sous VoiceOver elles restent affichées et le toucher n'a aucun effet."),
            "KenBurnsImageView.swift|body": Count(count: 1, reason: "Même toucher que celui du diaporama : affiche ou masque les commandes, sans effet sous VoiceOver."),
            "VideoPlayerView.swift|body": Count(count: 1, reason: "Toucher sur le média : ferme le panneau d'infos (doublé par Close details), avance d'une photo (doublé par le balayage et le filmstrip) ou bascule l'habillage que le même toucher rend."),
            "ZoomableImageView.swift|body": Count(count: 4, reason: "Deux sites par branche : le double toucher zoome, le toucher simple fait ce que fait VideoPlayerView."),
        ],
        labelledElsewhere: [
            "AssetThumbnailCell.swift|body": Elsewhere(count: 1, carrier: .identifierPrefix("assetTile_"), reason: "La couche image de la vignette porte le libellé et le trait bouton ; les badges restent des éléments distincts."),
            "OfflineAssetsView.swift|body": Elsewhere(count: 1, carrier: .identifierPrefix("offlineAsset_"), reason: "Même vignette, même couche image."),
            "MapView.swift|body": Elsewhere(count: 1, carrier: .identifierPrefix("mapPhotoThumb_"), reason: "La couche image de MapThumb porte le libellé et le trait bouton."),
            "WidgetViews.swift|tile": Elsewhere(count: 1, carrier: .viewBody("WidgetPhotoTile"), reason: "Link dont la vue de label est une tuile libellée ; le rôle système « lien » est gardé."),
            "WidgetViews.swift|mosaic": Elsewhere(count: 1, carrier: .viewBody("WidgetPhotoTile"), reason: "Link dont la vue de label est une tuile libellée ; le rôle système « lien » est gardé."),
        ],
        stringLabelBuilders: [
            "LocalAssetCell.swift|accessibilityLabel": "Texte composé de String(localized:) (type, sélection, état serveur).",
            "DownloadProgressPanel.swift|vm.panelAccessibilityLabel": "Texte composé de String(localized:) par le modèle de vue.",
            "PVRatingBar.swift|Self.starLabel(": "Fonction pure : String(localized:) de la note, accord par le catalogue.",
            "SearchFilterSheet.swift|PVRatingBar.starLabel(": "Même fonction pure que la barre de notation.",
            "PhotoViewer.swift|Self.filmstripAccessibilityLabel(": "Fonction pure : Photo N of M ou Video N of M, en clés du catalogue.",
        ],
        opaqueTextBearing: [
            "AddToAlbumPickerSheet.swift|body": Count(count: 1, reason: "La ligne d'album affiche son nom."),
            "AlbumsView.swift|albumGrid": Count(count: 1, reason: "La carte d'album affiche son titre."),
            "AppLogView.swift|body": Count(count: 1, reason: "La ligne du journal affiche son message."),
            "FolderView.swift|folderRows": Count(count: 1, reason: "La ligne de dossier affiche son nom."),
            "FreeUpSpaceView.swift|keepSection": Count(count: 1, reason: "La ligne d'album affiche son nom."),
            "LocalLibraryView.swift|body": Count(count: 1, reason: "La ligne d'album de l'appareil affiche son nom (Text passé en paramètre) et son nombre."),
            "MemoriesView.swift|body": Count(count: 1, reason: "La carte de souvenir affiche son titre."),
            "PartnerRow.swift|body": Count(count: 1, reason: "La zone d'identité affiche le nom du partenaire."),
            "AssetTagsSheet.swift|tagList": Count(count: 1, reason: "La ligne affiche le chemin du tag (Text(verbatim:), donnée du serveur)."),
            "ProfileView.swift|body": Count(count: 1, reason: "La ligne de compte affiche le nom du compte."),
            "SearchView.swift|filterChip": Count(count: 1, reason: "La puce affiche la contrainte de filtre."),
            "SearchView.swift|exploreView": Count(count: 1, reason: "La carte d'exploration affiche le nom du lieu."),
            "StackView.swift|stackList": Count(count: 1, reason: "La ligne de pile affiche son titre."),
            "CreateTagSheet.swift|parentRow": Count(count: 1, reason: "La ligne affiche le nom du tag parent (Text passé en paramètre)."),
            "TagsView.swift|tagList": Count(count: 1, reason: "La ligne affiche le nom du tag (Text(verbatim:), donnée du serveur)."),
            "UploadViewModel.swift|vm": Count(count: 3, reason: "Les liens du réglage de sauvegarde affichent leur titre."),
        ],
        visibleTextExceptions: [
            "PhotoViewer.swift|livePhotoOverlay": "Badge LIVE : le libellé dit l'action (lire ou arrêter la Live Photo), le texte visible n'est qu'un badge.",
        ]
    )

    // MARK: Scan

    private static let openerPattern = #"(?<![A-Za-z_.])(Button|Menu|ShareLink|NavigationLink|Link)\s*[({]|\.onTapGesture\b|TapGesture\(\)"#
    private static let declarationPattern =
        #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|public|internal|static|override|nonisolated|mutating)\s+)*(?:func|var)\s+(\w+)"#
    private static let specifier = #"%(\d+\$)?(@|lld|ld|d|lu|llu)"#

    /// The comments of a source replaced by blanks: offsets and lines stay.
    private static func strip(_ s: String) -> Text16 {
        let t = Text16(s)
        var out: [UInt16] = []
        out.reserveCapacity(t.count)
        var i = 0
        while i < t.count {
            let c = t.u[i]
            if c == Ch.quote {
                let e = t.skipString(i)
                out.append(contentsOf: t.u[i..<e])
                i = e
                continue
            }
            if c == Ch.slash && t.at(i + 1) == Ch.slash {
                while i < t.count && t.u[i] != Ch.newline {
                    out.append(Ch.space)
                    i += 1
                }
                continue
            }
            if c == Ch.slash && t.at(i + 1) == Ch.star {
                var end = t.count
                if let e = t.find("*/", from: i + 2) { end = e + 2 }
                for k in i..<end { out.append(t.u[k] == Ch.newline ? Ch.newline : Ch.space) }
                i = end
                continue
            }
            out.append(c)
            i += 1
        }
        return Text16(units: out)
    }

    private static func regexMatches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func lineStarts(_ t: Text16) -> [Int] {
        var starts = [0]
        for (i, c) in t.u.enumerated() where c == Ch.newline { starts.append(i + 1) }
        return starts
    }

    /// 1-based line of an offset.
    private static func lineOf(_ starts: [Int], _ offset: Int) -> Int {
        var lo = 0
        var hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    private static let declarationRegex = try? NSRegularExpression(pattern: declarationPattern)

    private static func enclosingMember(_ lines: [String], _ lineIndex: Int) -> String {
        var j = lineIndex - 1
        while j >= 0 {
            let line = lines[j]
            if line.contains("func ") || line.contains("var "),
               let m = declarationRegex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: line) {
                return String(line[r])
            }
            j -= 1
        }
        return "<file>"
    }

    // MARK: Literals and catalog keys

    private static func literalParts(_ raw: String) -> (key: String, interpolations: [String]) {
        let t = Text16(raw)
        var lo = 1
        var hi = t.count
        if t.has("\"\"\"", at: 0) {
            lo = 3
            hi = max(lo, t.count - 3)
        } else if t.count >= 2 && t.at(t.count - 1) == Ch.quote {
            hi = t.count - 1
        }
        var key: [UInt16] = []
        var interpolations: [String] = []
        var i = lo
        while i < hi {
            let c = t.u[i]
            if c == Ch.backslash && t.at(i + 1) == Ch.lparen {
                let e = t.skipBalanced(i + 1, Ch.lparen, Ch.rparen)
                interpolations.append(t.sub(i + 2, e - 1))
                key.append(1)
                i = e
                continue
            }
            if c == Ch.backslash {
                let next = t.at(i + 1)
                key.append(next == 110 ? Ch.newline : next)
                i += 2
                continue
            }
            key.append(c)
            i += 1
        }
        return (String(decoding: key, as: UTF16.self), interpolations)
    }

    private static func hasLetter(_ template: String) -> Bool {
        var s = template.replacingOccurrences(of: "\u{1}", with: "")
        s = s.replacingOccurrences(of: specifier, with: "", options: .regularExpression)
        return s.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func catalogMatches(_ template: String, keys: [String]) -> [String] {
        let pieces = template.components(separatedBy: "\u{1}").map { NSRegularExpression.escapedPattern(for: $0) }
        let pattern = "^" + pieces.joined(separator: specifier) + "$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return keys.filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }

    /// Problems and catalog keys of one string literal of a label.
    private static func checkLiteral(_ raw: String, keys: [String]) -> (errors: [String], keys: [String]) {
        let parts = literalParts(raw)
        var errors: [String] = []
        var found: [String] = []
        for interpolation in parts.interpolations {
            let interpolationText = Text16(interpolation)
            for lit in interpolationText.literals() {
                let before = interpolationText.sub(0, lit.start)
                if before.range(of: #"String\(\s*localized\s*:\s*$"#, options: .regularExpression) != nil {
                    let r = checkLiteral(lit.raw, keys: keys)
                    errors.append(contentsOf: r.errors)
                    found.append(contentsOf: r.keys)
                } else if !lit.verbatim {
                    errors.append("littéral non traduit interpolé \(lit.raw)")
                }
            }
        }
        if !hasLetter(parts.key) { return (errors, found) }
        let matched = catalogMatches(parts.key, keys: keys)
        if matched.isEmpty {
            errors.append("clé absente du catalogue : \"\(parts.key.replacingOccurrences(of: "\u{1}", with: "%@"))\"")
        } else {
            found.append(contentsOf: matched)
        }
        return (errors, found)
    }

    private static func checkExpression(_ expr: String, keys: [String]) -> (errors: [String], keys: [String]) {
        var errors: [String] = []
        var found: [String] = []
        for lit in Text16(expr).literals() where !lit.verbatim {
            let r = checkLiteral(lit.raw, keys: keys)
            errors.append(contentsOf: r.errors)
            found.append(contentsOf: r.keys)
        }
        return (errors, found)
    }

    // MARK: Parameters typed as localized text

    private struct Param {
        let external: String
        let name: String
    }

    private static func parseParams(_ text: String) -> [Param] {
        Text16(text).splitTop().compactMap { piece in
            guard let colon = piece.firstIndex(of: ":") else { return nil }
            let names = piece[..<colon].split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
            guard let name = names.last, let external = names.first else { return nil }
            return Param(external: external, name: name)
        }
    }

    /// Catalog keys of the literals passed, at every call site of the same file, to
    /// the parameter (or stored property) `name` typed as localized text.
    private static func callSiteKeys(_ source: Text16, name: String, keys: [String]) -> (errors: [String], keys: [String]) {
        let text = source.string
        var errors: [String] = []
        var found: [String] = []
        let escaped = NSRegularExpression.escapedPattern(for: name)
        if text.range(of: #"\b"# + escaped + #"\s*:\s*String\b"#, options: .regularExpression) != nil {
            return (["paramètre \(name) typé String"], [])
        }
        let declarations = regexMatches(#"\b"# + escaped + #"\s*:\s*(LocalizedStringKey|LocalizedStringResource|Text)\b"#, in: text)
        if declarations.isEmpty { return (["aucune déclaration LocalizedStringKey pour \(name)"], []) }
        let funcMatches = regexMatches(#"\bfunc\s+(\w+)\s*(?:<[^>]*>)?\s*\("#, in: text)
        let structMatches = regexMatches(#"\bstruct\s+(\w+)"#, in: text)
        for declaration in declarations {
            let idx = declaration.range.location
            var ownerName: String?
            var params: [Param] = []
            for fm in funcMatches.reversed() where fm.range.location < idx {
                let open = fm.range.location + fm.range.length - 1
                let end = source.skipBalanced(open, Ch.lparen, Ch.rparen)
                if open < idx && idx < end {
                    ownerName = source.sub(fm.range(at: 1).location, fm.range(at: 1).location + fm.range(at: 1).length)
                    params = parseParams(source.sub(open + 1, end - 1))
                    break
                }
            }
            if ownerName == nil, let st = structMatches.last(where: { $0.range.location < idx }) {
                ownerName = source.sub(st.range(at: 1).location, st.range(at: 1).location + st.range(at: 1).length)
                let braceStart = source.find("{", from: st.range.location) ?? st.range.location
                let braceEnd = source.skipBalanced(braceStart, Ch.lbrace, Ch.rbrace)
                let body = source.sub(braceStart + 1, braceEnd - 1)
                params = regexMatches(#"^\s{0,8}(?:let|var)\s+(\w+)\s*:\s*([^=\n]+)"#, in: body, options: [.anchorsMatchLines]).compactMap { m in
                    guard let r = Range(m.range(at: 1), in: body) else { return nil }
                    let n = String(body[r])
                    return Param(external: n, name: n)
                }
            }
            guard let owner = ownerName else {
                errors.append("déclaration englobante de \(name) introuvable")
                continue
            }
            guard let paramIndex = params.firstIndex(where: { $0.name == name }) else { continue }
            let calls = regexMatches(#"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: owner) + #"\s*\("#, in: text)
            var callCount = 0
            for cm in calls {
                let before = source.sub(max(0, cm.range.location - 8), cm.range.location)
                if before.range(of: #"(func|struct)\s+$"#, options: .regularExpression) != nil { continue }
                let open = cm.range.location + cm.range.length - 1
                let end = source.skipBalanced(open, Ch.lparen, Ch.rparen)
                let args = Text16(source.sub(open + 1, end - 1)).splitTop()
                callCount += 1
                var p = 0
                var argument: String?
                for a in args {
                    var label: String?
                    var value = a
                    if let lm = regexMatches(#"^\s*(\w+)\s*:"#, in: a).first, let lr = Range(lm.range(at: 1), in: a), let whole = Range(lm.range, in: a) {
                        label = String(a[lr])
                        value = String(a[whole.upperBound...])
                    }
                    while p < params.count && params[p].external != (label ?? "_") { p += 1 }
                    if p == paramIndex { argument = value; break }
                    p += 1
                }
                guard let given = argument else { continue }
                if Text16(given).literals().isEmpty {
                    errors.append("appel de \(owner) : argument \(name) non littéral : \(given.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                let r = checkExpression(given, keys: keys)
                errors.append(contentsOf: r.errors)
                found.append(contentsOf: r.keys)
            }
            if callCount == 0 { errors.append("aucun appel de \(owner) dans le fichier") }
        }
        return (errors, found)
    }

    // MARK: Classification

    private enum Kind { case text, icon, opaque }

    private static func textCarriesText(region: Text16, argsEnd: Int, args: String) -> Bool {
        let first = Text16(args).splitTop().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if first.range(of: #"^verbatim\s*:"#, options: .regularExpression) != nil { return false }
        if first.hasPrefix("\"") {
            guard let lit = Text16(first).literals().first else { return false }
            return hasLetter(literalParts(lit.raw).key)
        }
        if matches(#"Formatter|\.formatted\(|format:|\.count\b|[Dd]uration|Int\(|Double\("#, first) { return false }
        let names = region.parseChain(argsEnd).mods.map(\.name)
        return !names.contains("monospacedDigit")
    }

    private static func classify(args: String?, region: Text16?) -> Kind {
        if let args {
            let first = Text16(args).splitTop().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !first.isEmpty && !matches(#"^[A-Za-z_]\w*\s*:"#, first) { return .text }
        }
        guard let region else { return .opaque }
        let text = region.string
        var hasLabelPlain = false
        var hasLabelIcon = false
        for m in regexMatches(#"(?<![A-Za-z_.])Label\s*[({]"#, in: text) {
            let open = m.range.location + m.range.length - 1
            var end: Int
            if region.at(open) == Ch.lparen {
                end = region.skipBalanced(open, Ch.lparen, Ch.rparen)
                var q = end
                while region.at(q) == Ch.space { q += 1 }
                if region.at(q) == Ch.lbrace { end = region.skipBalanced(q, Ch.lbrace, Ch.rbrace) }
            } else {
                end = region.skipBalanced(open, Ch.lbrace, Ch.rbrace)
            }
            let mods = region.parseChain(end).mods
            if mods.contains(where: { $0.name == "labelStyle" && ($0.args ?? "").contains(".iconOnly") }) {
                hasLabelIcon = true
            } else {
                hasLabelPlain = true
            }
        }
        if hasLabelPlain { return .text }
        var carriesText = false
        for m in regexMatches(#"(?<![A-Za-z_.])Text\s*\("#, in: text) {
            let open = m.range.location + m.range.length - 1
            let end = region.skipBalanced(open, Ch.lparen, Ch.rparen)
            if textCarriesText(region: region, argsEnd: end, args: region.sub(open + 1, end - 1)) { carriesText = true }
        }
        if carriesText { return .text }
        let hasImage = matches(#"(?<![A-Za-z_.])Image\s*\("#, text) || hasLabelIcon
        return hasImage ? .icon : .opaque
    }

    // MARK: Analysis

    private struct Opener {
        let isGesture: Bool
        let keyword: String
        let args: String?
        let region: Text16?
        let end: Int
    }

    private static func parseOpener(_ t: Text16, _ m: NSTextCheckingResult, text: String) -> Opener {
        let matched = (text as NSString).substring(with: m.range)
        if matched.hasPrefix(".onTapGesture") || matched == "TapGesture()" {
            return Opener(isGesture: true, keyword: matched, args: nil, region: nil, end: m.range.location)
        }
        let keyword = (text as NSString).substring(with: m.range(at: 1))
        var i = m.range.location + m.range.length - 1
        var args: String?
        if t.at(i) == Ch.lparen {
            let e = t.skipBalanced(i, Ch.lparen, Ch.rparen)
            args = t.sub(i + 1, e - 1)
            i = e
        }
        var closures: [(label: Bool, body: String)] = []
        while true {
            let j = t.skipWS(i)
            if t.at(j) == Ch.lbrace {
                let e = t.skipBalanced(j, Ch.lbrace, Ch.rbrace)
                closures.append((false, t.sub(j + 1, e - 1)))
                i = e
                continue
            }
            if !closures.isEmpty, t.has("label", at: j) {
                var k = t.skipWS(j + 5)
                if t.at(k) == 58 {
                    k = t.skipWS(k + 1)
                    if t.at(k) == Ch.lbrace {
                        let e = t.skipBalanced(k, Ch.lbrace, Ch.rbrace)
                        closures.append((true, t.sub(k + 1, e - 1)))
                        i = e
                        continue
                    }
                }
            }
            break
        }
        var region: String?
        if let labelled = closures.first(where: { $0.label }) {
            region = labelled.body
        } else if let first = closures.first {
            region = first.body
        }
        if let args, let m = regexMatches(#"\blabel\s*:\s*\{"#, in: args).first {
            let a = Text16(args)
            let open = a.find("{", from: m.range.location) ?? m.range.location
            region = a.sub(open + 1, a.skipBalanced(open, Ch.lbrace, Ch.rbrace) - 1)
        }
        return Opener(isGesture: false, keyword: keyword, args: args, region: region.map { Text16($0) }, end: i)
    }

    private static func base(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    /// Lines around `index` that start with a dot (a modifier chain written one modifier per line).
    private static func chainLines(around index: Int, in lines: [String]) -> String {
        var lo = index
        while lo - 1 >= 0 && lines[lo - 1].trimmingCharacters(in: .whitespaces).hasPrefix(".") { lo -= 1 }
        var hi = index
        while hi + 1 < lines.count && lines[hi + 1].trimmingCharacters(in: .whitespaces).hasPrefix(".") { hi += 1 }
        return lines[lo...hi].joined(separator: "\n")
    }

    private static func isButtonTrait(_ chain: String) -> Bool {
        matches(#"\.accessibilityAddTraits\([^)]*\.isButton"#, chain)
    }

    /// The carrier of a gesture labelled elsewhere: its chain has the label and the button trait.
    private static func identifierCarrierProblem(prefix: String, lines: [String]) -> String? {
        guard let idx = lines.firstIndex(where: { $0.contains("accessibilityIdentifier(\"\(prefix)") }) else {
            return "aucun identifiant \(prefix) dans le fichier"
        }
        let chain = chainLines(around: idx, in: lines)
        if !chain.contains(".accessibilityLabel(") { return "la chaîne de \(prefix) n'a pas de libellé" }
        if !isButtonTrait(chain) { return "la chaîne de \(prefix) n'a pas le trait bouton" }
        return nil
    }

    private static func bodyCarrierProblem(type: String, source: Text16) -> String? {
        guard let start = source.find("struct \(type)", from: 0),
              let open = source.find("{", from: start) else { return "aucune vue \(type) dans le fichier" }
        let end = source.skipBalanced(open, Ch.lbrace, Ch.rbrace)
        if !source.sub(open, end).contains(".accessibilityLabel(") { return "la vue \(type) n'a pas de libellé" }
        return nil
    }

    static func analyze(source: String, path: String, catalogKeys: [String], tables: Tables) -> Analysis {
        let t = strip(source)
        let text = t.string
        let starts = lineStarts(t)
        let lines = text.components(separatedBy: "\n")
        let file = base(path)
        var analysis = Analysis()
        var carrierChecked = Set<String>()

        for m in regexMatches(openerPattern, in: text) {
            let opener = parseOpener(t, m, text: text)
            let line = lineOf(starts, m.range.location)
            let member = enclosingMember(lines, line - 1)
            let key = "\(file)|\(member)"
            var reasons: [String] = []
            var mods: [Text16.Mod] = []
            var gestureChain = ""

            if opener.isGesture {
                let lineText = lines[line - 1]
                let firstNonBlank = lineText.firstIndex(where: { $0 != " " && $0 != "\t" })
                var chainStart = m.range.location
                if let firstNonBlank, lineText[firstNonBlank] == "." {
                    chainStart = starts[line - 1] + lineText.utf16.distance(from: lineText.startIndex, to: firstNonBlank)
                }
                mods = t.parseChain(chainStart).mods
                var back: [String] = []
                var b = line - 2
                while b >= 0 && lines[b].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                    back.insert(lines[b], at: 0)
                    b -= 1
                }
                let forward = mods.isEmpty ? "" : t.sub(mods[0].start, mods[mods.count - 1].end)
                gestureChain = (back + [forward]).joined(separator: "\n")
                analysis.gestureSites[key, default: 0] += 1
            } else {
                mods = t.parseChain(opener.end).mods
            }

            let labelMod = mods.first(where: { $0.name == "accessibilityLabel" })

            if opener.isGesture {
                if tables.tapExemptions[key] != nil {
                    // exempt: the count is checked against the table
                } else if let elsewhere = tables.labelledElsewhere[key], case .identifierPrefix(let prefix) = elsewhere.carrier {
                    if carrierChecked.insert(key).inserted, let problem = identifierCarrierProblem(prefix: prefix, lines: lines) {
                        reasons.append(problem)
                    }
                } else if !gestureChain.contains(".accessibilityLabel(") || !isButtonTrait(gestureChain) {
                    reasons.append("onTapGesture sans libellé ni trait bouton")
                }
            } else {
                let kind = classify(args: opener.args, region: opener.region)
                var iconOnlyLabel = false
                if let region = opener.region {
                    let regionText = region.string
                    if matches(#"(?<![A-Za-z_.])Label\s*\(\s*""#, regionText), matches(#"labelStyle\(\.iconOnly\)"#, regionText),
                       let lm = regexMatches(#"(?<![A-Za-z_.])Label\s*\("#, in: regionText).first {
                        let open = lm.range.location + lm.range.length - 1
                        let end = region.skipBalanced(open, Ch.lparen, Ch.rparen)
                        let inner = Text16(region.sub(open + 1, end - 1)).splitTop().first ?? ""
                        let r = checkExpression(inner, keys: catalogKeys)
                        reasons.append(contentsOf: r.errors)
                        analysis.keys.formUnion(r.keys)
                        iconOnlyLabel = true
                    }
                }
                if kind != .text && labelMod == nil && !iconOnlyLabel {
                    analysis.unlabelledControls[key, default: 0] += 1
                    if tables.opaqueTextBearing[key] != nil {
                        // text-bearing view: the count is checked against the table
                    } else if let elsewhere = tables.labelledElsewhere[key], case .viewBody(let type) = elsewhere.carrier {
                        if carrierChecked.insert(key).inserted, let problem = bodyCarrierProblem(type: type, source: t) {
                            reasons.append(problem)
                        }
                    } else {
                        reasons.append(kind == .icon ? "bouton à icône sans libellé d'accessibilité" : "contrôle opaque sans libellé d'accessibilité")
                    }
                }
            }

            if let labelMod {
                let expression = (labelMod.args ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let builder = tables.stringLabelBuilders.keys.first(where: { entry in
                    let parts = entry.components(separatedBy: "|")
                    return parts.count == 2 && parts[0] == file && expression.hasPrefix(parts[1])
                }) {
                    analysis.usedBuilders.insert(builder)
                } else if !Text16(expression).literals().isEmpty {
                    let r = checkExpression(expression, keys: catalogKeys)
                    reasons.append(contentsOf: r.errors)
                    analysis.keys.formUnion(r.keys)
                } else if matches(#"^[A-Za-z_][\w.]*$"#, expression) {
                    let name = expression.components(separatedBy: ".").last ?? expression
                    let r = callSiteKeys(t, name: name, keys: catalogKeys)
                    reasons.append(contentsOf: r.errors)
                    analysis.keys.formUnion(r.keys)
                } else {
                    reasons.append("libellé non résolu : \(String(expression.prefix(80)))")
                }

                // The visible title of a text button must open the announced label (AC-34.8).
                if !opener.isGesture, classify(args: opener.args, region: opener.region) == .text {
                    var title: String?
                    if let first = opener.args.flatMap({ Text16($0).splitTop().first?.trimmingCharacters(in: .whitespacesAndNewlines) }), first.hasPrefix("\"") {
                        title = first
                    } else if let region = opener.region,
                              let tm = regexMatches(#"(?<![A-Za-z_.])(?:Label|Text)\s*\(\s*("(?:[^"\\]|\\.)*")"#, in: region.string).first,
                              let tr = Range(tm.range(at: 1), in: region.string) {
                        title = String(region.string[tr])
                    }
                    let labelLiteral = Text16(expression).literals().first(where: { !$0.verbatim })
                    if let title, let labelLiteral {
                        let tp = literalParts(title)
                        let lp = literalParts(labelLiteral.raw)
                        if tp.interpolations.isEmpty && lp.interpolations.isEmpty {
                            analysis.titleChecks.append(TitleCheck(path: path, line: line, member: member, titleKey: tp.key, labelKey: lp.key))
                        }
                    }
                }
            }

            if !reasons.isEmpty {
                analysis.findings.append(Finding(path: path, line: line, reason: reasons.joined(separator: " ; ")))
            }
        }
        return analysis
    }

    static func scan(source: String, path: String, catalogKeys: [String], tables: Tables = production) -> [Finding] {
        analyze(source: source, path: path, catalogKeys: catalogKeys, tables: tables).findings
    }

    /// Differences between a table and the real sites, named by key with both counts.
    static func tableMismatches(tables: Tables, gestureSites: [String: Int], unlabelledControls: [String: Int], usedBuilders: Set<String>) -> [String] {
        var out: [String] = []
        for (key, entry) in tables.tapExemptions where gestureSites[key, default: 0] != entry.count {
            out.append("tapExemptions \(key) : attendu \(entry.count), réel \(gestureSites[key, default: 0])")
        }
        for (key, entry) in tables.labelledElsewhere {
            let real: Int
            switch entry.carrier {
            case .identifierPrefix: real = gestureSites[key, default: 0]
            case .viewBody: real = unlabelledControls[key, default: 0]
            }
            if real != entry.count { out.append("labelledElsewhere \(key) : attendu \(entry.count), réel \(real)") }
        }
        for (key, entry) in tables.opaqueTextBearing where unlabelledControls[key, default: 0] != entry.count {
            out.append("opaqueTextBearing \(key) : attendu \(entry.count), réel \(unlabelledControls[key, default: 0])")
        }
        for builder in tables.stringLabelBuilders.keys where !usedBuilders.contains(builder) {
            out.append("stringLabelBuilders \(builder) : attendu 1 site au moins, réel 0")
        }
        return out.sorted()
    }
}

// MARK: - Tests

/// AC-34.1 / AC-34.2 / AC-34.8 (L-19): the inventory of the buttons of the app, of
/// the widgets and of the share extension. It reads the sources, so a later
/// icon-only button, tap gesture or untranslated label fails here.
final class ButtonAccessibilityInventoryTests: XCTestCase {

    // MARK: Sources and catalog

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

    private static let sourceFolders = ["Sources", "ImmichWidgets", "ImmichShareExtension"]

    /// Every `.swift` file of the three products, relative to the repo root.
    private static func sourceFiles() throws -> [String] {
        var files: [String] = []
        for folder in sourceFolders {
            let url = repoRoot.appendingPathComponent(folder)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("\(folder) is not readable from \(repoRoot.path)")
            }
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                files.append(String(file.path.dropFirst(repoRoot.path.count + 1)))
            }
        }
        return files.sorted()
    }

    private static func catalogStrings() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["strings"] as? [String: Any], "Localizable.xcstrings has no strings")
    }

    private struct RealScan {
        var findings: [ButtonScanner.Finding] = []
        var keys: Set<String> = []
        var gestureSites: [String: Int] = [:]
        var unlabelledControls: [String: Int] = [:]
        var usedBuilders: Set<String> = []
        var titleChecks: [ButtonScanner.TitleCheck] = []
    }

    private func scanRealSources() throws -> RealScan {
        let catalogKeys = try Self.catalogStrings().keys.sorted()
        var result = RealScan()
        for path in try Self.sourceFiles() {
            let url = Self.repoRoot.appendingPathComponent(path)
            let source: String
            do {
                source = try String(contentsOf: url, encoding: .utf8)
            } catch {
                XCTFail("\(path) cannot be read: \(error)")
                continue
            }
            let a = ButtonScanner.analyze(source: source, path: path, catalogKeys: catalogKeys, tables: ButtonScanner.production)
            result.findings.append(contentsOf: a.findings)
            result.keys.formUnion(a.keys)
            result.usedBuilders.formUnion(a.usedBuilders)
            result.titleChecks.append(contentsOf: a.titleChecks)
            for (k, v) in a.gestureSites { result.gestureSites[k, default: 0] += v }
            for (k, v) in a.unlabelledControls { result.unlabelledControls[k, default: 0] += v }
        }
        return result
    }

    // MARK: AC-34.1

    func test_AC_34_1_everyButtonInSourcesIsLabelled() throws {
        let scan = try scanRealSources()
        XCTAssertTrue(scan.findings.isEmpty, "Boutons sans libellé explicite :\n" + scan.findings.map(\.description).joined(separator: "\n"))
        XCTAssertFalse(scan.keys.isEmpty, "the scanner resolved no label key: it reads nothing")
    }

    func test_AC_34_1_tablesMatchRealSites() throws {
        let scan = try scanRealSources()
        let mismatches = ButtonScanner.tableMismatches(
            tables: ButtonScanner.production,
            gestureSites: scan.gestureSites,
            unlabelledControls: scan.unlabelledControls,
            usedBuilders: scan.usedBuilders
        )
        XCTAssertTrue(mismatches.isEmpty, mismatches.joined(separator: "\n"))
    }

    func test_AC_34_1_tablesMismatchNamesKeyAndBothCounts() {
        var tables = ButtonScanner.Tables(tapExemptions: [:], labelledElsewhere: [:], stringLabelBuilders: [:], opaqueTextBearing: [:], visibleTextExceptions: [:])
        tables.tapExemptions["Sample.swift|body"] = ButtonScanner.Count(count: 1, reason: "test")
        // The table says 1, the member carries 2 gestures — and the other way round.
        XCTAssertEqual(
            ButtonScanner.tableMismatches(tables: tables, gestureSites: ["Sample.swift|body": 2], unlabelledControls: [:], usedBuilders: []),
            ["tapExemptions Sample.swift|body : attendu 1, réel 2"]
        )
        tables.tapExemptions["Sample.swift|body"] = ButtonScanner.Count(count: 2, reason: "test")
        XCTAssertEqual(
            ButtonScanner.tableMismatches(tables: tables, gestureSites: ["Sample.swift|body": 1], unlabelledControls: [:], usedBuilders: []),
            ["tapExemptions Sample.swift|body : attendu 2, réel 1"]
        )
        // An entry without any real site is a stale entry.
        XCTAssertEqual(
            ButtonScanner.tableMismatches(tables: tables, gestureSites: [:], unlabelledControls: [:], usedBuilders: []),
            ["tapExemptions Sample.swift|body : attendu 2, réel 0"]
        )
        XCTAssertEqual(
            ButtonScanner.tableMismatches(tables: tables, gestureSites: ["Sample.swift|body": 2], unlabelledControls: [:], usedBuilders: []),
            []
        )
    }

    // MARK: Scanner on injected sources

    private let samplePath = "Sources/Features/Sample/Sample.swift"
    private let sampleCatalog = ["Play", "Smart", "Metadata", "Mode: %@", "Open"]

    private func findings(_ source: String) -> [ButtonScanner.Finding] {
        ButtonScanner.scan(source: source, path: samplePath, catalogKeys: sampleCatalog)
    }

    func test_AC_34_1_scannerFlagsEachUnlabelledForm() {
        // (name, bad source, line of the opener in it, corrected source)
        let forms: [(String, String, Int, String)] = [
            ("Button(action:) { Image }",
             "struct V: View {\n    var body: some View {\n        Button(action: go) {\n            Image(systemName: \"play\")\n        }\n    }\n}",
             3,
             "struct V: View {\n    var body: some View {\n        Button(action: go) {\n            Image(systemName: \"play\")\n        }\n        .accessibilityLabel(\"Play\")\n    }\n}"),
            ("Button { } label: { Image }",
             "struct V: View {\n    var body: some View {\n        Button { go() } label: {\n            Image(systemName: \"play\")\n        }\n    }\n}",
             3,
             "struct V: View {\n    var body: some View {\n        Button { go() } label: {\n            Image(systemName: \"play\")\n        }\n        .accessibilityLabel(\"Play\")\n    }\n}"),
            ("Button(intent:) { Image }",
             "struct V: View {\n    var body: some View {\n        Button(intent: ToggleIntent()) {\n            Image(systemName: \"play\")\n        }\n    }\n}",
             3,
             "struct V: View {\n    var body: some View {\n        Button(intent: ToggleIntent()) {\n            Image(systemName: \"play\")\n        }\n        .accessibilityLabel(\"Play\")\n    }\n}"),
            ("Menu { } label: { Image }",
             "struct V: View {\n    var body: some View {\n        Menu {\n            Button(\"Open\") { go() }\n        } label: {\n            Image(systemName: \"ellipsis\")\n        }\n    }\n}",
             3,
             "struct V: View {\n    var body: some View {\n        Menu {\n            Button(\"Open\") { go() }\n        } label: {\n            Image(systemName: \"ellipsis\")\n        }\n        .accessibilityLabel(\"Play\")\n    }\n}"),
            ("ShareLink(item:) { Image }",
             "struct V: View {\n    var body: some View {\n        ShareLink(item: url) {\n            Image(systemName: \"square.and.arrow.up\")\n        }\n    }\n}",
             3,
             "struct V: View {\n    var body: some View {\n        ShareLink(item: url) {\n            Image(systemName: \"square.and.arrow.up\")\n        }\n        .accessibilityLabel(\"Play\")\n    }\n}"),
            ("NavigationLink { } label: { Image }",
             "struct V: View {\n    var body: some View {\n        NavigationLink {\n            Detail()\n        } label: {\n            Image(systemName: \"chevron.right\")\n        }\n    }\n}",
             3,
             "struct V: View {\n    var body: some View {\n        NavigationLink {\n            Detail()\n        } label: {\n            Image(systemName: \"chevron.right\")\n        }\n        .accessibilityLabel(\"Open\")\n    }\n}"),
            ("Link(destination:) { Image }",
             "struct V: View {\n    var body: some View {\n        Link(destination: url) {\n            Image(systemName: \"safari\")\n        }\n    }\n}",
             3,
             "struct V: View {\n    var body: some View {\n        Link(destination: url) {\n            Image(systemName: \"safari\")\n        }\n        .accessibilityLabel(\"Open\")\n    }\n}"),
            (".onTapGesture without label and button trait",
             "struct V: View {\n    var body: some View {\n        Color.clear\n            .onTapGesture { go() }\n    }\n}",
             4,
             "struct V: View {\n    var body: some View {\n        Color.clear\n            .onTapGesture { go() }\n            .accessibilityLabel(\"Open\")\n            .accessibilityAddTraits(.isButton)\n    }\n}"),
            ("label helper typed String",
             "struct V: View {\n    func tile(label: String) -> some View {\n        Button(action: go) {\n            Image(systemName: \"play\")\n        }\n        .accessibilityLabel(label)\n    }\n    var body: some View { tile(label: \"Play\") }\n}",
             3,
             "struct V: View {\n    func tile(label: LocalizedStringKey) -> some View {\n        Button(action: go) {\n            Image(systemName: \"play\")\n        }\n        .accessibilityLabel(label)\n    }\n    var body: some View { tile(label: \"Play\") }\n}"),
            ("literal whose key is not in the catalog",
             "struct V: View {\n    var body: some View {\n        Button(action: go) {\n            Image(systemName: \"play\")\n        }\n        .accessibilityLabel(\"Unknown label\")\n    }\n}",
             3,
             "struct V: View {\n    var body: some View {\n        Button(action: go) {\n            Image(systemName: \"play\")\n        }\n        .accessibilityLabel(\"Play\")\n    }\n}"),
            ("untranslated literal inside an interpolation",
             "struct V: View {\n    var body: some View {\n        Button(action: go) {\n            Image(systemName: \"play\")\n        }\n        .accessibilityLabel(\"Mode: \\(flag ? \"Smart\" : \"Metadata\")\")\n    }\n}",
             3,
             "struct V: View {\n    var body: some View {\n        Button(action: go) {\n            Image(systemName: \"play\")\n        }\n        .accessibilityLabel(\"Mode: \\(modeTitle)\")\n    }\n}"),
            ("icon and a duration, no label",
             "struct V: View {\n    var body: some View {\n        Button {\n            go()\n        } label: {\n            Image(systemName: \"play\")\n            Text(VideoDurationFormatter.string(milliseconds: d))\n        }\n    }\n}",
             3,
             "struct V: View {\n    var body: some View {\n        Button {\n            go()\n        } label: {\n            Image(systemName: \"play\")\n            Text(\"Play\")\n        }\n    }\n}"),
        ]
        for (name, bad, line, good) in forms {
            let found = findings(bad)
            XCTAssertEqual(found.count, 1, "\(name): \(found)")
            XCTAssertEqual(found.first?.path, samplePath, name)
            XCTAssertEqual(found.first?.line, line, name)
            XCTAssertEqual(findings(good), [], "\(name) corrected")
        }
    }

    func test_AC_34_1_scannerKeepsTextualLabelsOutOfTheInventory() {
        let source = "struct V: View {\n    var body: some View {\n        Button(\"Open\") { go() }\n        Button { go() } label: { Label(\"Open\", systemImage: \"play\") }\n    }\n}"
        XCTAssertEqual(findings(source), [])
    }

    // MARK: AC-34.1 / AC-34.2 — keys in the shipped languages

    func test_AC_34_1_labelKeysResolveInEveryShippedLanguage() throws {
        let scan = try scanRealSources()
        let strings = try Self.catalogStrings()
        var problems: [String] = []
        for key in scan.keys.sorted() {
            let entry = strings[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any]
            for code in ["fr", "de", "es", "it"] {
                let localization = localizations?[code] as? [String: Any]
                if localization?["stringUnit"] == nil && localization?["variations"] == nil {
                    problems.append("clé « \(key) » absente de \(code) dans le catalogue")
                }
                let (bundle, _) = try language(code)
                if bundle.localizedString(forKey: key, value: "\u{1}absent", table: nil) == "\u{1}absent" {
                    problems.append("clé « \(key) » absente du bundle \(code)")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        XCTAssertGreaterThan(scan.keys.count, 50, "the labels of the app resolve to well over fifty keys")
    }

    // MARK: AC-34.8

    func test_AC_34_8_textButtonsAnnounceTheirVisibleText() throws {
        let scan = try scanRealSources()
        var problems: [String] = []
        var skipped = Set<String>()
        for check in scan.titleChecks {
            let key = "\(check.path.split(separator: "/").last.map(String.init) ?? "")|\(check.member)"
            if ButtonScanner.production.visibleTextExceptions[key] != nil {
                skipped.insert(key)
                continue
            }
            for code in ["fr", "de", "es", "it"] {
                let (bundle, _) = try language(code)
                let title = bundle.localizedString(forKey: check.titleKey, value: nil, table: nil)
                let label = bundle.localizedString(forKey: check.labelKey, value: nil, table: nil)
                if !label.trimmingCharacters(in: .whitespaces).hasPrefix(title.trimmingCharacters(in: .whitespaces)) {
                    problems.append("\(check.path):\(check.line) \(code) : « \(label) » ne commence pas par « \(title) »")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        for key in ButtonScanner.production.visibleTextExceptions.keys {
            XCTAssertTrue(skipped.contains(key), "visibleTextExceptions \(key) : aucun site réel")
        }
    }

    func test_AC_34_8_touchedIdentifiersKept() throws {
        var all = ""
        for path in try Self.sourceFiles() {
            all += try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
            all += "\n"
        }
        let identifiers = [
            "deviceSessionsMenuButton", "rotate90CCWButton", "rotate90CWButton", "personBirthdayAction",
            "mirrorHorizontalButton", "mirrorVerticalButton",
            "assetRatingStar_", "searchFilterStar1", "searchFilterStar2", "searchFilterStar3", "searchFilterStar4", "searchFilterStar5",
            "viewerOcrToggle", "assetTile_", "offlineAsset_", "pickerAsset_", "sharedLinkAsset_",
            "viewerFavoriteButton", "videoPlayerPlayPause", "memoryMomentClose", "shareExtensionItemRow_",
        ]
        for identifier in identifiers {
            XCTAssertTrue(all.contains("\"\(identifier)"), "identifiant \(identifier) retiré des sources")
        }
    }
}
