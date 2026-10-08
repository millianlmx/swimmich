import SwiftUI

/// Tag-an-asset sheet (gap #2): toggles the server's tags on a single asset
/// and creates new tags inline. Self-contained — loads all tags + the asset's
/// current tags on appear, and persists each toggle via the tag/untag endpoints.
struct AssetTagsSheet: View {
    let asset: AssetReactItem
    let client: any ImmichClient
    var onChanged: () -> Void = {}

    @State private var allTags: [TagResponseDto] = []
    @State private var appliedTagIDs: Set<String> = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var newTagName = ""
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load tags", systemImage: "tag.slash")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                            .buttonStyle(PVPrimaryButtonStyle())
                    }
                } else if allTags.isEmpty {
                    ContentUnavailableView(
                        "No tags yet",
                        systemImage: "tag",
                        description: Text("Create your first tag below.")
                    )
                } else {
                    tagList
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newTagName = ""
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create tag")
                }
            }
            .alert("New Tag", isPresented: $showCreate) {
                TextField("Tag name", text: $newTagName)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    Task { await createAndApply(name: newTagName) }
                }
            }
        }
        .task { await load() }
    }

    private var tagList: some View {
        List {
            ForEach(allTags, id: \.id) { tag in
                Button {
                    Task { await toggle(tag) }
                } label: {
                    HStack(spacing: PVSpacing.s12) {
                        Image(systemName: "tag.fill")
                            .font(.pvBody)
                            .foregroundStyle((tag.color.flatMap { Color(hex: $0) }) ?? Color.immichPrimary)
                        Text(tag.name)
                            .font(.pvBody)
                            .foregroundStyle(Color.textPrimaryPV)
                        Spacer()
                        if appliedTagIDs.contains(tag.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.immichPrimary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func toggle(_ tag: TagResponseDto) async {
        do {
            if appliedTagIDs.contains(tag.id) {
                try await client.untagAssets(tagId: tag.id, assetIds: [asset.id])
                appliedTagIDs.remove(tag.id)
            } else {
                try await client.tagAssets(tagId: tag.id, assetIds: [asset.id])
                appliedTagIDs.insert(tag.id)
            }
            errorMessage = nil
            onChanged()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    private func createAndApply(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let tag = try await client.createTag(name: trimmed, color: nil)
            try await client.tagAssets(tagId: tag.id, assetIds: [asset.id])
            appliedTagIDs.insert(tag.id)
            errorMessage = nil
            await load()
            onChanged()
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let tags = client.getAllTags()
            async let detail = client.getAsset(id: asset.id)
            let (all, assetDetail) = try await (tags, detail)
            allTags = all
            appliedTagIDs = Set((assetDetail.tags ?? []).map(\.id))
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    @Environment(\.dismiss) private var dismiss
}
