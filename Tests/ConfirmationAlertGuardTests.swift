import XCTest

/// Static guard (AC-801): no `confirmationDialog` is left in the app's sources.
///
/// On iOS 26 a `confirmationDialog` is a popover anchored to its source view and
/// it drops the Cancel button; an `.alert` always shows both actions. Every
/// destructive confirmation of the app is therefore an alert (L-31), and a later
/// one written as a dialog fails here.
final class ConfirmationAlertGuardTests: XCTestCase {

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

    /// Code lines (comment-only lines dropped) of every `.swift` file under
    /// `directory`, as `relative path:line` + text.
    private static func codeLines(under directory: String) throws -> [(site: String, text: String)] {
        let root = repoRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var lines: [(site: String, text: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, raw) in text.components(separatedBy: "\n").enumerated() {
                if raw.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("//") { continue }
                lines.append(("\(relative):\(index + 1)", raw))
            }
        }
        return lines
    }

    // AC-801: not one `confirmationDialog` in `Sources`, extensions and widgets included.
    func test_AC_801_noConfirmationDialogLeftInSources() throws {
        let lines = try Self.codeLines(under: "Sources")
        XCTAssertGreaterThan(lines.count, 1000, "the guard must actually read the sources")
        let offenders = lines.filter { $0.text.contains("confirmationDialog") }.map(\.site)
        XCTAssertEqual(offenders, [], "use `.alert` (Cancel stays visible on iOS 26)")
    }

    // AC-62: the four confirmations the criterion names are alerts that carry
    // their identifiers (the UI scenario targets them).
    func test_AC_62_namedConfirmationsKeepTheirCancelIdentifiers() throws {
        let expectations: [(file: String, identifiers: [String])] = [
            ("Sources/Features/Settings/PreferencesView.swift", ["preferencesResetConfirm", "preferencesResetCancel"]),
            ("Sources/Features/Partners/PartnersView.swift", ["confirmStopSharing", "cancelStopSharing"]),
            ("Sources/Features/Upload/UploadViewModel.swift", ["resetTrackingConfirm", "resetTrackingCancel"]),
            ("Sources/Features/SyncStatus/SyncStatusView.swift", ["syncStatusResetLedgerConfirm", "syncStatusResetLedgerCancel"]),
            ("Sources/Features/PhotoViewer/PhotoViewer.swift", ["viewerDeleteConfirm", "viewerDeleteCancel"]),
        ]
        for (file, identifiers) in expectations {
            let text = try String(contentsOf: Self.repoRoot.appendingPathComponent(file), encoding: .utf8)
            for identifier in identifiers {
                XCTAssertTrue(text.contains("accessibilityIdentifier(\"\(identifier)\")"), "\(file) lacks \(identifier)")
            }
        }
    }
}
