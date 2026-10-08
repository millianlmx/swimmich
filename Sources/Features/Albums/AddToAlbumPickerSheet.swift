import SwiftUI

/// Picker sheet launched from Timeline selection toolbar (AC-515, AC-520).
/// Lists existing albums (shared AlbumsViewModel via @Environment) as thumbnail
/// rows — cover + name + count — + a "New Album" action that creates one with
/// the selected assets pre-populated.
struct AddToAlbumPickerSheet: View {
    let selectedAssetIds: Set<String>
    var onCompleted: () -> Void = {}

    @Environment(AlbumsViewModel.self) private var albumsVM
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var presentingCreate = false
    @State private var addedAlbumId: String?
    @State private var lastAddTick = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Selected") {
                    Label("\(selectedAssetIds.count) photo\(selectedAssetIds.count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.textSecondaryPV)
                }
                Section("Albums") {
                    if albumsVM.albums.isEmpty {
                        Text("No albums yet")
                            .foregroundStyle(Color.textSecondaryPV)
                    }
                    ForEach(albumsVM.albums, id: \.id) { album in
                        Button {
                            Task { await add(to: album.id) }
                        } label: {
                            albumRow(album)
                        }
                        .disabled(albumsVM.isLoading)
                    }
                }
            }
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        presentingCreate = true
                    } label: {
                        Label("New Album", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .task { await albumsVM.load() }
            .refreshable { await albumsVM.refresh() }
            .sheet(isPresented: $presentingCreate) {
                CreateAlbumSheet(vm: albumsVM, preselectedAssetIds: Array(selectedAssetIds))
            }
            .appSensoryFeedback(.success, trigger: lastAddTick)
        }
    }

    /// Thumbnail row: 44×44 cover + name + count, with a success checkmark when
    /// the add for this album has just completed.
    @ViewBuilder
    private func albumRow(_ album: AlbumResponseDto) -> some View {
        let baseURL = auth.baseURL ?? URL(string: "https://example.com")!
        HStack(spacing: PVSpacing.s12) {
            Color.clear
                .frame(width: 44, height: 44)
                .overlay {
                    if let thumbId = album.albumThumbnailAssetId {
                        AuthenticatedAsyncImage(
                            url: ImmichAssetURL.thumbnail(assetId: thumbId, thumbhash: "", baseURL: baseURL),
                            token: auth.accessToken
                        )
                    } else {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 18, weight: .semibold)) // DS-exempt: small placeholder glyph
                            .foregroundStyle(Color.textSecondaryPV)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: PVRadius.xs, style: .continuous))

            VStack(alignment: .leading, spacing: PVSpacing.s2) {
                Text(album.albumName)
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                    .lineLimit(1)
                Text("\(album.assetCount) item\(album.assetCount == 1 ? "" : "s")")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
            }
            Spacer()
            if addedAlbumId == album.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.immichSuccess)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .animation(PVMotion.snappy, value: addedAlbumId)
    }

    private func add(to albumId: String) async {
        await albumsVM.addAssets(ids: Array(selectedAssetIds), toAlbumId: albumId)
        if albumsVM.actionErrorMessage == nil {
            addedAlbumId = albumId
            lastAddTick &+= 1
            await albumsVM.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                dismiss()
                onCompleted()
            }
        }
    }
}
