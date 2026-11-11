import SwiftUI

/// "New Tag" sheet: a name and the parent it goes under (root by default).
///
/// Modal, so it owns a `NavigationStack`. A failed creation keeps the sheet
/// open with its input and shows the error in place.
struct CreateTagSheet: View {
    @Bindable var vm: TagsViewModel

    @State private var name = ""
    @State private var parentId: String?
    @Environment(\.dismiss) private var dismiss

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !vm.isCreating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Tag name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("createTagName")
                } footer: {
                    Text("Tags help you group and search photos.")
                }

                Section("Parent tag") {
                    parentRow(title: Text("No parent"), id: nil)
                        .accessibilityIdentifier("createTagParent_root")
                    ForEach(vm.parentChoices, id: \.id) { tag in
                        parentRow(title: Text(verbatim: tag.path), id: tag.id)
                            .accessibilityIdentifier("createTagParent_\(tag.id)")
                    }
                }

                if let message = vm.createErrorMessage {
                    Section {
                        InlineErrorBadge(message: message)
                            .accessibilityIdentifier("createTagError")
                    }
                }
            }
            .navigationTitle("New Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("createTagCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { if await vm.create(name: name, parentId: parentId) { dismiss() } }
                    }
                    .disabled(!canCreate)
                    .accessibilityIdentifier("createTagConfirm")
                }
            }
        }
    }

    private func parentRow(title: Text, id: String?) -> some View {
        Button {
            parentId = id
        } label: {
            HStack {
                title
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                Spacer()
                if parentId == id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.immichPrimary)
                }
            }
        }
        .accessibilityAddTraits(parentId == id ? .isSelected : [])
    }
}
