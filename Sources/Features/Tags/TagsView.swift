import SwiftUI

/// Where a tag row leads: the photos of that tag.
struct TagAssetsRoute: Hashable {
    let tagId: String
    let name: String
}

/// Tag management screen (gap #2, L-03): the tags as an indented, fully
/// expanded hierarchy; a touch on any row — parent included — opens its photos.
/// Create under a parent from the toolbar, delete with swipe. Pushed from the
/// Me section (ProfileView) — TrashView pattern (no own NavigationStack).
struct TagsView: View {
    @Bindable var vm: TagsViewModel

    @State private var showCreate = false

    var body: some View {
        Group {
            if vm.isLoading && vm.rows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.rows.isEmpty {
                ContentUnavailableView(
                    "No tags yet",
                    systemImage: "tag",
                    description: Text("Create tags to organize your photos.")
                )
            } else {
                List {
                    ForEach(vm.rows) { row in
                        NavigationLink(value: TagAssetsRoute(tagId: row.tag.id, name: row.tag.name)) {
                            HStack(spacing: PVSpacing.s12) {
                                Image(systemName: "tag.fill")
                                    .font(.pvBody)
                                    .foregroundStyle((row.tag.color.flatMap { Color(hex: $0) }) ?? Color.immichPrimary)
                                Text(verbatim: row.tag.name)
                                    .font(.pvBody)
                                    .foregroundStyle(Color.textPrimaryPV)
                            }
                            .padding(.leading, CGFloat(row.depth) * PVSpacing.s16)
                        }
                        .accessibilityIdentifier(row.accessibilityIdentifier)
                        .accessibilityValue(Text(verbatim: row.depth > 0 ? row.tag.path : ""))
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let tag = vm.rows[index].tag
                            Task { await vm.delete(tag) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    vm.clearCreateError()
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create tag")
                .accessibilityIdentifier("createTagButton")
            }
        }
        .task { await vm.load() }
        .refreshable { await vm.load(force: true) }
        .navigationDestination(for: TagAssetsRoute.self) { route in
            TagAssetsView(vm: DependencyContainer.shared.makeTagAssetsViewModel(tagId: route.tagId, tagName: route.name))
        }
        .sheet(isPresented: $showCreate) {
            CreateTagSheet(vm: vm)
                .presentationDetents([.medium, .large])
        }
    }
}
