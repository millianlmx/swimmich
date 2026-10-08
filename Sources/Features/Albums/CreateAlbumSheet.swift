import SwiftUI

/// Form sheet for creating a new album (AC-507).
/// Optionally receives preselected assetIds when launched from the Timeline
/// "Add to Album" picker (allows "New Album with these photos").
///
/// A live cover preview at the top gives immediate visual feedback — the first
/// selected photo (or a placeholder) shown in the same portrait shape the album
/// card will use on the grid.
struct CreateAlbumSheet: View {
    @Bindable var vm: AlbumsViewModel
    let preselectedAssetIds: [String]?

    @Environment(AuthViewModel.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var createTick = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    coverPreview
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section("Album") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .navigationTitle("New Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await vm.createAlbum(
                                name: name,
                                description: description.isEmpty ? nil : description,
                                assetIds: preselectedAssetIds
                            )
                            if vm.actionErrorMessage == nil {
                                createTick &+= 1
                                dismiss()
                            }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isCreating)
                    .fontWeight(.semibold)
                }
            }
        }
        .appSensoryFeedback(.success, trigger: createTick)
    }

    /// Portrait cover preview: the first selected photo if any, otherwise a
    /// placeholder. A count chip surfaces how many photos will be seeded.
    @ViewBuilder
    private var coverPreview: some View {
        let firstId = preselectedAssetIds?.first
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxWidth: 220)
                .overlay {
                    if let firstId, let baseURL = auth.baseURL {
                        AuthenticatedAsyncImage(
                            url: ImmichAssetURL.thumbnail(assetId: firstId, thumbhash: "", baseURL: baseURL),
                            token: auth.accessToken
                        )
                    } else {
                        ZStack {
                            Color.bgTertiary
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 40)) // DS-exempt: placeholder glyph
                                .foregroundStyle(Color.textTertiaryPV)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: PVRadius.sm, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let count = preselectedAssetIds?.count, count > 0 {
                        Text("\(count) Photo\(count == 1 ? "" : "s")")
                            .font(.pvCaption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, PVSpacing.s8)
                            .padding(.vertical, PVSpacing.s4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.5))
                            .padding(PVSpacing.s8)
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PVSpacing.s16)
    }
}
