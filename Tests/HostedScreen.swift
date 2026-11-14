import SwiftUI
import UIKit
import XCTest
@testable import ImmichSwiftUI

/// Turns on the accessibility automation of the test host, once: SwiftUI only
/// builds the accessibility tree of a view when an assistive technology or the
/// UI automation asks for it, and a unit test is neither. The switch is the one
/// XCUITest flips from outside the app (`libAccessibility`), read from inside.
private enum AccessibilityAutomation {
    static let isOn: Bool = {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(library, "_AXSSetAutomationEnabled") else { return false }
        typealias Setter = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: Setter.self)(1)
        return true
    }()
}

/// A whole screen hosted in a window of its own, at a text size and in a
/// language, read through its accessibility tree: what a `DynamicTypeUITests`
/// scenario measures on a launched app (labels shown whole, nothing overlapping,
/// text inside the window), measured in a unit test, in milliseconds instead of
/// minutes. The rules are the scenario's, word for word (see `assertNoOverlap`).
///
/// The window is as wide as the device and much taller: a lazy list lays out
/// every row, so nothing has to be scrolled to before it is measured. What only a
/// launched app proves (the navigation between screens, "reachable by scrolling",
/// the sheets and menus of the system) stays with the scenarios.
@MainActor
final class HostedScreen {

    enum Kind: String { case staticText, button, textField, toggle, other }

    final class Node {
        let kind: Kind
        let frame: CGRect
        let identifier: String
        let label: String
        let scrolls: Bool
        let depth: Int
        let summary: String
        var children: [Node] = []

        init(kind: Kind, frame: CGRect, identifier: String, label: String, scrolls: Bool, depth: Int, summary: String) {
            self.kind = kind
            self.frame = frame
            self.identifier = identifier
            self.label = label
            self.scrolls = scrolls
            self.depth = depth
            self.summary = summary
        }

        var name: String { identifier.isEmpty ? label : identifier }

        var carriesText: Bool {
            children.contains { $0.kind == .staticText || $0.carriesText }
        }

        func first(where matches: (Node) -> Bool) -> Node? {
            if matches(self) { return self }
            for child in children {
                if let found = child.first(where: matches) { return found }
            }
            return nil
        }

        func forEach(_ visit: (Node) -> Void) {
            visit(self)
            for child in children { child.forEach(visit) }
        }
    }

    let window: UIWindow
    private let controller: UIViewController

    init(_ view: some View, size: DynamicTypeSize, language: String = "en", height: CGFloat = 3000) {
        _ = AccessibilityAutomation.isOn
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let width = scene?.screen.bounds.width ?? 402
        let locale = Locale(identifier: language == "de" ? "de_DE" : "en_US")
        controller = UIHostingController(rootView: AnyView(
            view
                .environment(\.dynamicTypeSize, size)
                .environment(\.locale, locale)
        ))
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: .zero)
        }
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.traitOverrides.preferredContentSizeCategory = UIContentSizeCategory(size)
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
    }

    var windowFrame: CGRect { window.frame }

    // MARK: - Reading the tree

    /// The accessibility tree of the window, read now.
    func tree() -> Node {
        window.layoutIfNeeded()
        var visited = Set<ObjectIdentifier>()
        return node(for: window, scrolls: false, depth: 0, visited: &visited)
            ?? Node(kind: .other, frame: window.frame, identifier: "", label: "", scrolls: false, depth: 0, summary: "window")
    }

    private func node(for object: NSObject, scrolls: Bool, depth: Int, visited: inout Set<ObjectIdentifier>) -> Node? {
        guard depth < 80, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
        if let view = object as? UIView, view.isHidden { return nil }
        if object is UITabBar || object.accessibilityElementsHidden { return nil }

        let traits = object.accessibilityTraits
        let kind: Kind
        if object is UITextField || object is UITextView || traits.rawValue & 0x40000 != 0 {
            kind = .textField
        } else if object is UISwitch || traits.contains(.toggleButton) {
            kind = .toggle
        } else if traits.contains(.button) {
            kind = .button
        } else if traits.contains(.staticText) || object is UILabel {
            kind = .staticText
        } else {
            kind = .other
        }
        var identifier = ""
        if object.responds(to: Selector(("accessibilityIdentifier"))) {
            identifier = object.value(forKey: "accessibilityIdentifier") as? String ?? ""
        }
        let frame: CGRect
        if let view = object as? UIView {
            frame = view.convert(view.bounds, to: nil)
        } else {
            frame = object.accessibilityFrame
        }
        let label = object.accessibilityLabel ?? ""
        let summary = "\(type(of: object)) \(kind.rawValue) el=\(object.isAccessibilityElement ? 1 : 0) "
            + "t=\(String(traits.rawValue, radix: 16)) id='\(identifier)' '\(label.prefix(40))' "
            + "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
        let result = Node(kind: kind, frame: frame, identifier: identifier, label: label,
                          scrolls: scrolls, depth: depth, summary: summary)

        var children: [NSObject] = []
        if let elements = object.accessibilityElements, !elements.isEmpty {
            children = elements.compactMap { $0 as? NSObject }
        } else {
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children = (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }
            } else if let view = object as? UIView {
                children = view.subviews
            }
        }
        let inside = scrolls || object is UIScrollView
        for child in children {
            if let childNode = node(for: child, scrolls: inside, depth: depth + 1, visited: &visited) {
                result.children.append(childNode)
            }
        }
        return result
    }

    /// The tree, one node per segment: what a failure prints.
    func dump(limit: Int = 400) -> String {
        var lines: [String] = ["automation=\(AccessibilityAutomation.isOn) window=\(window.frame)"]
        tree().forEach { node in
            if lines.count <= limit { lines.append("\(node.depth)> \(node.summary)") }
        }
        return lines.joined(separator: " | ")
    }

    func find(_ identifier: String) -> Node? {
        tree().first { $0.identifier == identifier }
    }

    /// Waits until `identifier` is in the tree (a screen loads in a `.task`).
    @discardableResult
    func waitFor(_ identifier: String, timeout: TimeInterval = 5,
                 file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if find(identifier) != nil { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while Date() < deadline
        XCTFail("no '\(identifier)' on the hosted screen — \(dump())", file: file, line: line)
        return false
    }

    // MARK: - Measuring text

    /// The frame of the text `identifier`: the static text carrying the id, else
    /// the first static text under the element carrying it, else the element.
    func textFrame(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> CGRect {
        let root = tree()
        if let direct = root.first(where: { $0.identifier == identifier && $0.kind == .staticText }) {
            return direct.frame
        }
        guard let holder = root.first(where: { $0.identifier == identifier }) else {
            XCTFail("no '\(identifier)' on the hosted screen", file: file, line: line)
            return .zero
        }
        return holder.first { $0.kind == .staticText }?.frame ?? holder.frame
    }

    /// The long label is shown whole: at least 1.8 times as tall as the short one
    /// (it wraps instead of being cut) and inside the window.
    func assertFullyShown(long: String, short: String, file: StaticString = #filePath, line: UInt = #line) {
        let longFrame = textFrame(long, file: file, line: line)
        let shortFrame = textFrame(short, file: file, line: line)
        XCTAssertGreaterThanOrEqual(longFrame.height, 1.8 * shortFrame.height,
                                    "\(long) (\(longFrame.height) pt) is not shown on more lines than \(short) (\(shortFrame.height) pt)",
                                    file: file, line: line)
        assertInWindow(long, file: file, line: line)
    }

    /// The text is inside the window's width.
    func assertInWindow(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let frame = textFrame(identifier, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(identifier) starts left of the window", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, windowFrame.width + 0.5,
                                 "\(identifier) runs past the window's right edge", file: file, line: line)
    }

    /// Texts, buttons, fields and switches of the screen: no two overlap by more
    /// than 1 pt both ways, unless one contains the other (a text in its button).
    /// The rule of `DynamicTypeUITests.assertNoOverlap`: a button that carries a
    /// text is measured by that text, scrolling content is compared with scrolling
    /// content and fixed chrome with fixed chrome, the tab bar is the system's.
    func assertNoOverlap(file: StaticString = #filePath, line: UInt = #line) {
        let kinds: Set<Kind> = [.staticText, .button, .textField, .toggle]
        var seen: [Node] = []
        let bounds = windowFrame
        tree().forEach { node in
            guard kinds.contains(node.kind), !node.frame.isEmpty, node.frame.intersects(bounds),
                  !(node.kind == .button && node.carriesText) else { return }
            seen.append(node)
        }
        XCTAssertGreaterThanOrEqual(seen.count, 2, "nothing to measure on the hosted screen — \(dump())", file: file, line: line)
        for (index, first) in seen.enumerated() {
            for second in seen[(index + 1)...] where first.scrolls == second.scrolls {
                let shared = first.frame.intersection(second.frame)
                guard !shared.isNull, shared.width > 1, shared.height > 1 else { continue }
                let nested = first.frame.insetBy(dx: -1, dy: -1).contains(second.frame)
                    || second.frame.insetBy(dx: -1, dy: -1).contains(first.frame)
                guard !nested else { continue }
                XCTFail("'\(first.name)' \(first.frame) overlaps '\(second.name)' \(second.frame)", file: file, line: line)
            }
        }
    }
}
