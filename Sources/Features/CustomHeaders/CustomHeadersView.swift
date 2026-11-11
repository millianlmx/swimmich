import SwiftUI

/// The editor of one server's custom HTTP headers: one section per header, a
/// name field and a value field, the reason a row is refused under it, and a
/// "Save" in the bar.
///
/// It has no `NavigationStack` of its own, so the same view serves the sheet
/// opened from the server step (which wraps it) and the screen pushed from the
/// Me hub. `onFinish` is how the host closes it after a successful save.
struct CustomHeadersView: View {
    @Bindable var vm: CustomHeadersViewModel
    let onFinish: () -> Void

    var body: some View {
        Form {
            ForEach(Array(vm.rows.enumerated()), id: \.element.id) { index, row in
                Section {
                    TextField("Name", text: nameBinding(for: row.id))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("customHeaderName_\(index)")

                    TextField("Value", text: valueBinding(for: row.id))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("customHeaderValue_\(index)")

                    if let issue = vm.issues[row.id] {
                        Text(vm.message(for: issue))
                            .font(.pvCaption)
                            .foregroundStyle(Color.immichError)
                            .accessibilityIdentifier("customHeaderIssue_\(index)")
                    }

                    Button(role: .destructive) {
                        vm.removeRow(row.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Remove header")
                    .accessibilityIdentifier("customHeaderDelete_\(index)")
                }
            }

            Section {
                Button {
                    vm.addRow()
                } label: {
                    Label("Add Header", systemImage: "plus")
                }
                .accessibilityIdentifier("customHeaderAddButton")

                if let message = vm.saveErrorMessage {
                    InlineErrorBadge(message: message)
                        .accessibilityIdentifier("customHeadersSaveError")
                }
            } footer: {
                Text("Sent with every request to \(vm.serverKey.displayName), from the app, widgets and the share extension.")
                    .accessibilityIdentifier("customHeadersServer")
            }
        }
        .navigationTitle("Custom HTTP Headers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if vm.save() { onFinish() }
                }
                .disabled(!vm.canSave)
                .accessibilityIdentifier("customHeadersSaveButton")
            }
        }
    }

    private func nameBinding(for id: CustomHeadersViewModel.Row.ID) -> Binding<String> {
        Binding(
            get: { vm.rows.first { $0.id == id }?.name ?? "" },
            set: { newValue in
                if let index = vm.rows.firstIndex(where: { $0.id == id }) { vm.rows[index].name = newValue }
            }
        )
    }

    private func valueBinding(for id: CustomHeadersViewModel.Row.ID) -> Binding<String> {
        Binding(
            get: { vm.rows.first { $0.id == id }?.value ?? "" },
            set: { newValue in
                if let index = vm.rows.firstIndex(where: { $0.id == id }) { vm.rows[index].value = newValue }
            }
        )
    }
}

/// The screen pushed from the Me hub's "Advanced" section (B-2): the headers of
/// the active account's server. The view model is built once, here, with the
/// server the hub showed when it was opened.
struct CustomHeadersScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm: CustomHeadersViewModel

    init(serverKey: ServerKey, onSaved: @escaping @MainActor (ServerKey) -> Void) {
        _vm = State(initialValue: DependencyContainer.shared.makeCustomHeadersViewModel(
            serverKey: serverKey, onSaved: onSaved
        ))
    }

    var body: some View {
        CustomHeadersView(vm: vm, onFinish: { dismiss() })
    }
}
