import SwiftUI

/// "People" of the Filters sheet: the named people of the library, each with
/// its face, to choose among. Pushed in the sheet's own `NavigationStack`
/// (never a stack of its own).
///
/// A view without logic: the list, its filtering and the selection are the
/// view model's (`peopleOptions`, `matchingPeople`, `togglePerson`). Only the
/// text of the filter field is local state. Choosing sends nothing — the
/// sheet's Done runs the search with every person chosen.
struct SearchPeoplePicker: View {
    @Bindable var vm: SearchViewModel
    @Environment(AuthViewModel.self) private var auth

    @State private var filterText = ""

    var body: some View {
        content
            .task { await vm.loadPeopleOptions() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ImmichAppBar(title: "People")
                        .accessibilityIdentifier("searchPeoplePicker")
                }
            }
            .immichAppBarTitleHeader("People")
    }

    @ViewBuilder
    private var content: some View {
        switch vm.peopleOptionsState {
        case .loading:
            ProgressView()
                .pvLoadingIndicator("searchPeopleLoading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let message):
            PVErrorStateView(
                title: "Couldn't load people",
                message: message,
                identifierPrefix: "searchPeople",
                retry: { Task { await vm.loadPeopleOptions() } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView("No people", systemImage: "person.2")
                .accessibilityIdentifier("searchPeopleEmpty")
        case .data(let status):
            list(status)
        }
    }

    private func list(_ status: DataStatus) -> some View {
        let matches = SearchViewModel.matchingPeople(vm.peopleOptions, query: filterText)
        return List {
            if case .failed(let message) = status {
                InlineErrorBadge(message: message, retry: { Task { await vm.loadPeopleOptions() } })
                    .accessibilityIdentifier("searchPeopleRefreshError")
            }
            Section {
                TextField("Filter people", text: $filterText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("searchPeopleFilterField")
            }
            Section {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: filterText)
                } else {
                    ForEach(matches) { person in
                        personRow(person)
                    }
                }
            }
        }
    }

    /// Face, name, check — one VoiceOver element named after the person, whose
    /// "selected" trait carries the check.
    private func personRow(_ person: PersonResponseDto) -> some View {
        let name = person.name.isEmpty ? String(localized: "Unnamed") : person.name
        let isSelected = vm.filter.people.contains { $0.id == person.id }
        return Button {
            vm.togglePerson(person)
        } label: {
            HStack(spacing: PVSpacing.s12) {
                AuthenticatedAsyncImage(
                    url: ImmichAssetURL.personThumbnail(
                        personId: person.id,
                        baseURL: auth.baseURL ?? URL(string: "https://example.com")!
                    ),
                    token: auth.accessToken
                )
                .clipShape(Circle())
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(Color.separatorPV, lineWidth: 0.5))

                Text(verbatim: name)
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
            .padding(.vertical, PVSpacing.s4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("searchPersonRow_\(person.id)")
    }
}
