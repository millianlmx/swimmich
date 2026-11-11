import Foundation

/// Editor of one server's custom HTTP headers (L-09): a draft the user fills in,
/// validated row by row, written to the registry only by an explicit `save()`.
///
/// Nothing here ever logs or displays a typed name or value: the messages say
/// why a row is refused, not what it contained.
@Observable
@MainActor
final class CustomHeadersViewModel {
    struct Row: Identifiable, Equatable {
        let id: UUID
        var name: String
        var value: String

        init(id: UUID = UUID(), name: String = "", value: String = "") {
            self.id = id
            self.name = name
            self.value = value
        }
    }

    /// The server the list belongs to. Fixed when the editor opens: typing in
    /// the address field behind the sheet cannot move the draft to another server.
    let serverKey: ServerKey
    var rows: [Row]
    private(set) var saveErrorMessage: String?

    private let registry: any CustomHeadersEditing
    private let onSaved: @MainActor (ServerKey) -> Void

    init(
        serverKey: ServerKey,
        registry: any CustomHeadersEditing,
        onSaved: @escaping @MainActor (ServerKey) -> Void
    ) {
        self.serverKey = serverKey
        self.registry = registry
        self.onSaved = onSaved
        self.rows = registry.headers(for: serverKey).map { Row(name: $0.name, value: $0.value) }
    }

    private var validation: (headers: [CustomHTTPHeader], issues: [Int: CustomHeaderIssue]) {
        CustomHeaderValidation.validate(rows.map { (name: $0.name, value: $0.value) })
    }

    /// Rows in error, by `Row.id`.
    var issues: [Row.ID: CustomHeaderIssue] {
        var result: [Row.ID: CustomHeaderIssue] = [:]
        for (index, issue) in validation.issues where rows.indices.contains(index) {
            result[rows[index].id] = issue
        }
        return result
    }

    /// What `save()` would write: the valid rows, trimmed, blank rows dropped.
    var pendingHeaders: [CustomHTTPHeader] { validation.headers }

    var canSave: Bool {
        let result = validation
        return result.issues.isEmpty && result.headers != registry.headers(for: serverKey)
    }

    func message(for issue: CustomHeaderIssue) -> String {
        switch issue {
        case .invalidName:
            String(localized: "Use only letters, digits and ! # $ % & ' * + - . ^ _ ` | ~ in a header name.")
        case .reservedName:
            String(localized: "The app sets this header itself.")
        case .duplicateName:
            String(localized: "This header is already in the list.")
        case .invalidValue:
            String(localized: "A header value cannot contain a line break or a control character.")
        }
    }

    func addRow() {
        rows.append(Row())
    }

    func removeRow(_ id: Row.ID) {
        rows.removeAll { $0.id == id }
    }

    /// Writes the draft. `false` when nothing was written: a row is in error,
    /// nothing changed, or the keychain refused (then `saveErrorMessage` says so).
    /// Removing the last row and saving writes an empty list, which removes the
    /// server's entry.
    @discardableResult
    func save() -> Bool {
        guard canSave else { return false }
        do {
            try registry.save(pendingHeaders, for: serverKey)
        } catch {
            saveErrorMessage = String(localized: "The headers could not be saved.")
            return false
        }
        saveErrorMessage = nil
        onSaved(serverKey)
        return true
    }
}
