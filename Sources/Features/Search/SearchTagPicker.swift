import SwiftUI

/// "Tags" of the Filters sheet: every tag, children indented under their
/// parent, each shown by its full path (`Voyages/Japon`) so a child never reads
/// like its parent. Pushed in the sheet's own `NavigationStack` (never a stack
/// of its own).
///
/// A view without logic, like `SearchPeoplePicker`: the rows and the selection
/// are the view model's, and choosing sends nothing until the sheet's Done.
/// Choosing a tag sends its id only — the server adds the tag's descendants.
struct SearchTagPicker: View {
    @Bindable var vm: SearchViewModel

    var body: some View {
        content
            .task { await vm.loadTagOptions() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ImmichAppBar(title: "Tags")
                        .accessibilityIdentifier("searchTagPicker")
                }
            }
            .immichAppBarTitleHeader("Tags")
    }

    @ViewBuilder
    private var content: some View {
        switch vm.tagOptionsState {
        case .loading:
            ProgressView()
                .pvLoadingIndicator("searchTagsLoading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            PVErrorStateView(
                title: "Couldn't load tags",
                message: message,
                identifierPrefix: "searchTags",
                retry: { Task { await vm.loadTagOptions() } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView("No tags", systemImage: "tag")
                .accessibilityIdentifier("searchTagsEmpty")
        case .data(let status):
            List {
                if case .failed(let message) = status {
                    InlineErrorBadge(message: message, retry: { Task { await vm.loadTagOptions() } })
                        .accessibilityIdentifier("searchTagsRefreshError")
                }
                ForEach(vm.tagOptions) { row in
                    tagRow(row)
                }
            }
        }
    }

    private func tagRow(_ row: TagRow) -> some View {
        let isSelected = vm.filter.tags.contains { $0.id == row.tag.id }
        return Button {
            vm.toggleTag(row.tag)
        } label: {
            HStack(spacing: PVSpacing.s12) {
                Text(verbatim: row.tag.path)
                    .font(.pvBody)
                    .foregroundStyle(Color.textPrimaryPV)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: PVSpacing.s8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.pvBody.weight(.semibold))
                        .foregroundStyle(Color.immichPrimary)
                }
            }
            .padding(.leading, CGFloat(row.depth) * PVSpacing.s16)
            .padding(.vertical, PVSpacing.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.tag.path))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("searchTagRow_\(row.tag.id)")
    }
}
