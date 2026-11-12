import SwiftUI

/// Duplicate cleanup screen — one card per duplicate group (Photos-style):
/// the group's thumbnails in a grid with a "Keep" badge on the suggested
/// keep(s), plus a per-group Delete button behind a confirmation dialog.
struct DuplicatesView: View {
    @Bindable var vm: DuplicatesViewModel
    @Environment(AuthViewModel.self) private var auth

    @State private var pendingDeleteId: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3)

    var body: some View {
        // No `NavigationStack` of its own: pushed from the Albums tab's Library
        // section, it shares the tab's single navigation bar.
        Group {
            if vm.groups.isEmpty && vm.isLoading {
                ProgressView("Checking for duplicates…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.errorMessage, vm.groups.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load duplicates", systemImage: "rectangle.on.rectangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await vm.load() } }
                        .buttonStyle(PVPrimaryButtonStyle())
                }
            } else if vm.groups.isEmpty {
                ContentUnavailableView(
                    "No Duplicates",
                    systemImage: "checkmark.seal",
                    description: Text("Duplicated photos will appear here for easy cleanup.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: PVSpacing.s16) {
                        ForEach(vm.groups, id: \.duplicateId) { group in
                            groupCard(group)
                        }
                    }
                    .padding(PVSpacing.s16)
                }
                .refreshable { await vm.load() }
            }
        }
        .navigationTitle("Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .confirmationDialog(
            Self.deletePrompt(count: pendingCount),
            isPresented: Binding(
                get: { pendingDeleteId != nil },
                set: { if !$0 { pendingDeleteId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteId {
                    Task { await vm.deleteGroup(id: id) }
                }
                pendingDeleteId = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteId = nil }
        } message: {
            Text("The suggested copies are kept. This cannot be undone.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duplicatesScreen")
    }

    private var pendingCount: Int {
        guard let id = pendingDeleteId,
              let group = vm.groups.first(where: { $0.duplicateId == id }) else { return 0 }
        return vm.deletableIds(for: group).count
    }

    /// Title of the delete confirmation. Pure and bundle/locale-injectable so the
    /// plural forms of the catalog can be tested in every shipped language.
    static func deletePrompt(count: Int, bundle: Bundle = .main, locale: Locale = .current) -> String {
        String(localized: "Delete \(count) duplicates?", bundle: bundle, locale: locale)
    }

    @ViewBuilder
    private func groupCard(_ group: DuplicateResponseDto) -> some View {
        let keep = Set(group.suggestedKeepAssetIds)
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            HStack {
                Text("\(group.assets.count) copies")
                    .font(.pvBody.weight(.semibold))
                    .foregroundStyle(Color.textPrimaryPV)
                Spacer()
                Button(role: .destructive) {
                    pendingDeleteId = group.duplicateId
                } label: {
                    Label("Delete Duplicates", systemImage: "trash")
                        .font(.pvSubhead)
                }
                .disabled(vm.deletableIds(for: group).isEmpty)
            }
            LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                ForEach(group.assets, id: \.id) { dto in
                    ZStack(alignment: .topLeading) {
                        AuthenticatedAsyncImage(
                            url: ImmichAssetURL.thumbnail(assetId: dto.id, thumbhash: dto.thumbhash ?? "", baseURL: auth.baseURL ?? URL(string: "https://example.com")!),
                            token: auth.accessToken
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: PVRadius.sm, style: .continuous))
                        if keep.contains(dto.id) {
                            Text("Keep")
                                .font(.pvCaption.weight(.semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, PVSpacing.s8)
                                .padding(.vertical, PVSpacing.s4)
                                .background(Color.immichPrimary, in: Capsule())
                                .padding(PVSpacing.s4)
                        }
                    }
                    .accessibilityLabel(keep.contains(dto.id) ? "Suggested keep" : "Duplicate copy")
                }
            }
        }
        .padding(PVSpacing.s16)
        .background(Color.gray.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("duplicateGroup_\(group.duplicateId)")
    }
}
