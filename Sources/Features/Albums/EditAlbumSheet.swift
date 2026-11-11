import SwiftUI

/// Edits an album's name, description and activity-feed toggle (AC-1101).
/// Saves via `AlbumDetailViewModel.updateAlbumDetails` — the sheet dismisses
/// only on success, keeping the form open for retry on failure.
struct EditAlbumSheet: View {
    @Bindable var vm: AlbumDetailViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AuthViewModel.self) private var auth
    @State private var name: String
    @State private var description: String
    @State private var isActivityEnabled: Bool
    @State private var isSaving = false
    @State private var saveTick = 0

    init(vm: AlbumDetailViewModel) {
        self.vm = vm
        _name = State(initialValue: vm.album?.albumName ?? "")
        _description = State(initialValue: vm.album?.description ?? "")
        _isActivityEnabled = State(initialValue: vm.album?.isActivityEnabled ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Album name", text: $name)
                        .accessibilityIdentifier("editAlbumNameField")
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("editAlbumDescriptionField")
                }
                // The activity feed stays with the owner; an editor only edits title and description.
                if vm.canToggleActivity(currentUserId: auth.userId) {
                    Section("Sharing") {
                        Toggle("Activity feed", isOn: $isActivityEnabled)
                            .accessibilityIdentifier("editAlbumActivityToggle")
                    }
                }
            }
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                isSaving = true
                                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                let ok = await vm.updateAlbumDetails(
                                    name: trimmed.isEmpty ? nil : trimmed,
                                    description: description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description,
                                    isActivityEnabled: isActivityEnabled,
                                    currentUserId: auth.userId
                                )
                                isSaving = false
                                if ok {
                                    saveTick &+= 1
                                    dismiss()
                                }
                            }
                        }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("editAlbumSaveButton")
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .appSensoryFeedback(.success, trigger: saveTick)
    }
}
