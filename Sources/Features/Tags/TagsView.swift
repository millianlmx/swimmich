import SwiftUI

/// Where a tag row leads: the photos of that tag.
struct TagAssetsRoute: Hashable {
    let tagId: String
    let name: String
}

/// Tag management screen (gap #2, L-03): the tags as an indented, fully
/// expanded hierarchy; a touch on any row — parent included — opens its photos.
/// Create under a parent from the toolbar, delete with swipe. Pushed from the
/// Albums tab's Library section (L-12) — TrashView pattern (no own NavigationStack).
struct TagsView: View {
    @Bindable var vm: TagsViewModel

    @State private var showCreate = false

    var body: some View {
        Group {
            if case .loading = vm.renderState {
                // First read, or a "Try Again" with nothing to show.
                ProgressView()
                    .pvLoadingIndicator("tagsLoading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tagList
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
        .navigationDestination(for: TagAssetsRoute.self) { route in
            TagAssetsView(vm: DependencyContainer.shared.makeTagAssetsViewModel(tagId: route.tagId, tagName: route.name))
        }
        .sheet(isPresented: $showCreate) {
            CreateTagSheet(vm: vm)
                .presentationDetents([.medium, .large])
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tagsScreen")
    }

    /// One `List` carries `.refreshable` for the error, the empty state and the
    /// rows, so a state change never cancels the pull in flight.
    private var tagList: some View {
        List {
            switch vm.renderState {
            case .loading:
                EmptyView()
            case .error(let message):
                Section {
                    PVErrorStateView(
                        title: "Couldn't load tags",
                        message: message,
                        identifierPrefix: "tags",
                        retry: { Task { await vm.load(force: true) } }
                    )
                    .listRowBackground(Color.clear)
                }
            case .empty:
                Section {
                    ContentUnavailableView(
                        "No tags yet",
                        systemImage: "tag",
                        description: Text("Create tags to organize your photos.")
                    )
                    .accessibilityIdentifier("tagsEmptyState")
                    .listRowBackground(Color.clear)
                }
            case .data(let status):
                switch status {
                case .idle:
                    EmptyView()
                case .reloading:
                    // "Try Again" from the banner: the rows stay, this stands in for it.
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .pvLoadingIndicator("tagsLoading")
                            .listRowBackground(Color.clear)
                    }
                case .failed(let message):
                    Section {
                        InlineErrorBadge(message: message, retry: { Task { await vm.load(force: true) } })
                            .accessibilityIdentifier("tagsRefreshError")
                            .listRowBackground(Color.clear)
                    }
                }
                Section {
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
        .refreshable { await vm.refresh() }
    }
}
