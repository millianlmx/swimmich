import SwiftUI

/// People & faces (P3 people-faces): person list with face thumbnails and
/// asset counts, Featured section (favorites first), hidden-count footer row,
/// then a per-person drill-down: faces grid + rename / favorite / hide / merge.
/// Pushed from the Me tab (ProfileView) — no own NavigationStack (TrashView pattern).
struct PeopleView: View {
    @Bindable var vm: PeopleViewModel
    @Environment(AuthViewModel.self) private var auth

    @State private var viewerItem: PhotoViewerItem?
    /// One token per pushed screen: the task replays when the detail pops back
    /// (same token: nothing reloads), a fresh push from Profile mints a new one.
    @State private var visit = UUID()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3)

    var body: some View {
        Group {
            if vm.isLoading && vm.people.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.people.isEmpty, let error = vm.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load people", systemImage: "person.2.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await vm.refresh() }
                    }
                    .buttonStyle(PVPrimaryButtonStyle())
                }
            } else if vm.people.isEmpty {
                ContentUnavailableView(
                    "No people yet",
                    systemImage: "person.2",
                    description: Text("Faces detected on your photos will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                personList
            }
        }
        .navigationTitle("People")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh people")
            }
        }
        .task { await vm.appear(visit: visit) }
        .refreshable { await vm.refresh() }
        .photoViewer(
            item: $viewerItem,
            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
            token: auth.accessToken,
            onDataChanged: { Task { await vm.refreshAssets() } }
        )
    }

    // MARK: - List

    private var personList: some View {
        List {
            let featured = vm.featuredPeople

            if !featured.isEmpty {
                Section("Featured") {
                    ForEach(featured) { person in
                        personRow(person)
                    }
                }
            }
            Section("People") {
                ForEach(vm.otherPeople) { person in
                    personRow(person)
                }
                listFooter
            }
            if vm.hiddenCount > 0 {
                Section {
                    Button {
                        Task { await vm.toggleShowHidden() }
                    } label: {
                        Label(
                            vm.showingHidden ? "Hide hidden people" : "Show \(vm.hiddenCount) hidden people",
                            systemImage: "eye.slash"
                        )
                        .font(.pvBody)
                        .foregroundStyle(Color.textSecondaryPV)
                    }
                }
            }
            if let error = vm.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.pvCaption)
                        .foregroundStyle(Color.immichError)
                }
            }
        }
    }

    /// Last row of the list: a spinner that asks for the next page when it
    /// scrolls into view (recreated on every `peopleEndRevision`, like the
    /// album grid footer: no `onChange`, no `task(id:)`).
    @ViewBuilder
    private var listFooter: some View {
        switch vm.peopleFooter {
        case .none:
            EmptyView()
        case .error(let message):
            InlineErrorBadge(message: message, retry: { Task { await vm.loadMorePeople() } })
        case .loadingMore:
            ProgressView()
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("peopleLoadMore")
                .onAppear { Task { await vm.loadMorePeople() } }
                .id(vm.peopleEndRevision)
        }
    }

    /// A row is pushed as a **view**, not by value: the hub opens this screen with
    /// a view-destination link, and SwiftUI keeps value destinations *below* view
    /// destinations inside one stack — a `NavigationLink(value:)` here silently
    /// did nothing (measured by XCUITest: eight gestures across two list
    /// instances, row hittable, screen unmoved, while a tap on the same screen's
    /// refresh button did reach the app). `FolderView` hit the same wall and was
    /// fixed the same way.
    private func personRow(_ person: PersonResponseDto) -> some View {
        NavigationLink {
            PersonDetailView(vm: vm, pushed: person, columns: columns, viewerItem: $viewerItem)
        } label: {
            HStack(spacing: PVSpacing.s12) {
                AuthenticatedAsyncImage(
                    url: ImmichAssetURL.personThumbnail(personId: person.id, baseURL: auth.baseURL ?? URL(string: "https://example.com")!),
                    token: auth.accessToken
                )
                .clipShape(Circle())
                .frame(width: 48, height: 48)
                .overlay(Circle().strokeBorder(Color.separatorPV, lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name)
                        .font(.pvBody)
                        .foregroundStyle(Color.textPrimaryPV)
                    Text("\(vm.assetCount(for: person.id)) photos")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                Spacer()
                if person.isFavorite == true {
                    Image(systemName: "star.fill")
                        .font(.pvBody)
                        .foregroundStyle(Color.immichPrimary)
                }
            }
            .padding(.vertical, PVSpacing.s4)
        }
        .accessibilityElement(children: .combine)
        // The row is interactive and had no identifier: its label is a
        // concatenation ("Ada Lovelace, 3 photos"), and after the drill-down is
        // popped back the same row publishes as a cell whose label is EMPTY, so
        // a label query stops matching a list that is plainly on screen. (The
        // combine modifier above is NOT the reason the row does not activate for
        // XCUITest — removing it was measured to change nothing.)
        .accessibilityIdentifier("personRow_\(person.id)")
        .onAppear { Task { await vm.personRowAppeared(person.id) } }
    }
}

/// Faces drill-down: person header (avatar, name, count, birthday) + action
/// toolbar (favorite / rename / hide / birthday / merge) + 3-column faces grid
/// with full viewer.
private struct PersonDetailView: View {
    @Bindable var vm: PeopleViewModel
    /// The row the navigation pushed, captured once. `let`, not `private let`:
    /// a private stored property makes the synthesized initializer private too.
    let pushed: PersonResponseDto
    let columns: [GridItem]
    @Binding var viewerItem: PhotoViewerItem?

    @Environment(AuthViewModel.self) private var auth

    /// The live row: every write goes through `PeopleViewModel.apply`, which
    /// replaces `vm.people[i]` with the server's answer and remembers it per
    /// id, so reading the pushed snapshot would keep showing a birthday that
    /// was just changed — and a person that left the loaded pages (merge target,
    /// reload to page 1) would lose its edits.
    private var person: PersonResponseDto {
        vm.livePerson(pushed)
    }

    var body: some View {
        ScrollView {
            // Lazy, like the album grid: a plain stack would build the footer at
            // once and request page 2 before any scroll.
            LazyVStack {
                VStack(spacing: PVSpacing.s16) {
                    AuthenticatedAsyncImage(
                        url: ImmichAssetURL.personThumbnail(
                            personId: person.id,
                            baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
                            size: .preview
                        ),
                        token: auth.accessToken
                    )
                    .clipShape(Circle())
                    .frame(width: 96, height: 96)
                    .overlay(Circle().strokeBorder(Color.separatorPV, lineWidth: 1))

                    VStack(spacing: 2) {
                        Text(person.name)
                            .font(.pvTitle)
                            .foregroundStyle(Color.textPrimaryPV)
                        Text("\(vm.assetCount(for: person.id)) photos")
                            .font(.pvCaption)
                            .foregroundStyle(Color.textSecondaryPV)
                        // Nothing at all when the person has no birthday (or the
                        // server sent something unparseable): no placeholder, no
                        // empty line, so the header keeps its height.
                        if let birthday = PersonBirthday.display(person.birthDate) {
                            Label(birthday, systemImage: "calendar")
                                .font(.pvCaption)
                                .foregroundStyle(Color.textSecondaryPV)
                                .transition(.opacity)
                                .accessibilityIdentifier("personBirthdayValue")
                        }
                    }
                    .animation(.default, value: person.birthDate)

                    HStack(spacing: PVSpacing.s8) {
                        actionButton("star.fill", person.isFavorite == true ? Color.immichPrimary : Color.textSecondaryPV, "Favorite") {
                            Task { await vm.toggleFavorite(person) }
                        }
                        actionButton("pencil", .textSecondaryPV, "Rename") {
                            renameText = person.name
                            renamePerson = person
                        }
                        actionButton("eye.slash", .textSecondaryPV, person.isHidden ? "Unhide" : "Hide") {
                            Task { await vm.toggleHidden(person) }
                        }
                        actionButton("calendar", .textSecondaryPV, "Birthday") {
                            birthdayDraft = PersonBirthday.date(from: person.birthDate) ?? Date()
                            birthdayPerson = person
                        }
                        .accessibilityIdentifier("personBirthdayAction")
                        mergeMenu
                    }
                }
                .padding(.top, PVSpacing.s16)
                .padding(.horizontal, PVSpacing.s16)

                if vm.assetsLoading && vm.personAssets.isEmpty {
                    ProgressView()
                        .padding(.vertical, PVSpacing.s32)
                } else if vm.personAssets.isEmpty {
                    ContentUnavailableView(
                        "No photos",
                        systemImage: "photo.on.rectangle",
                        description: Text("No assets tagged with this person yet.")
                    )
                    .padding(.vertical, PVSpacing.s24)
                } else {
                    LazyVGrid(columns: columns, spacing: PVSpacing.s2) {
                        ForEach(Array(vm.personAssets.enumerated()), id: \.element.id) { i, item in
                            AssetThumbnailCell(
                                asset: item,
                                baseURL: auth.baseURL ?? URL(string: "https://example.com")!,
                                token: auth.accessToken,
                                onTap: { viewerItem = PhotoViewerItem(assets: vm.personAssets, index: i) }
                            )
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    Task { await vm.setFeatureFace(person, assetId: item.id) }
                                } label: {
                                    Label("Set as cover", systemImage: "person.crop.circle.badge.checkmark")
                                }
                            }
                            .onAppear { Task { await vm.assetCellAppeared(item.id) } }
                        }
                    }
                    .padding(.horizontal, PVSpacing.s4)
                }

                switch vm.assetsFooter {
                case .none:
                    EmptyView()
                case .error(let message):
                    InlineErrorBadge(message: message, retry: { Task { await vm.loadMoreAssets() } })
                        .padding(.horizontal, PVSpacing.s4)
                case .loadingMore:
                    // Recreated on every `assetsEndRevision`: see `PeopleView.listFooter`.
                    ProgressView()
                        .padding(.vertical, PVSpacing.s12)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("personAssetsLoadMore")
                        .onAppear { Task { await vm.loadMoreAssets() } }
                        .id(vm.assetsEndRevision)
                }

                if let error = vm.assetsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.pvCaption)
                        .foregroundStyle(Color.immichError)
                        .padding(.vertical, PVSpacing.s8)
                }
            }
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.select(person) }
        .alert(
            "Rename Person",
            isPresented: Binding(
                get: { renamePerson != nil },
                set: { if !$0 { renamePerson = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let person = renamePerson {
                    Task { await vm.rename(person, to: renameText) }
                }
            }
        } message: {
            Text(person.name)
        }
        // `PersonResponseDto` is already `Identifiable`, so no ad-hoc id is
        // needed; the rename alert and this sheet are never live at once.
        .sheet(item: $birthdayPerson) { person in
            BirthdayEditorSheet(
                draft: $birthdayDraft,
                hasExistingBirthday: person.birthDate != nil,
                onSave: { date in
                    // The wire conversion happens here, at the last moment: the
                    // sheet stays presentation-only.
                    Task { await vm.setBirthday(person, to: date.map(PersonBirthday.wire(from:))) }
                }
            )
        }
    }

    @State private var renamePerson: PersonResponseDto?
    @State private var renameText = ""
    @State private var birthdayPerson: PersonResponseDto?
    @State private var birthdayDraft = Date()

    private func actionButton(_ systemName: String, _ color: Color, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.pvHeadline)
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(Color.gray.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var mergeMenu: some View {
        Menu {
            ForEach(vm.people.filter { $0.id != person.id }) { other in
                Button {
                    Task {
                        await vm.merge([other.id], into: person)
                    }
                } label: {
                    Label("Merge \(other.name)", systemImage: "person.crop.circle.badge.plus")
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.merge")
                .font(.pvHeadline)
                .foregroundStyle(Color.textSecondaryPV)
                .frame(width: 40, height: 40)
                .background(Color.gray.opacity(0.12))
                .clipShape(Circle())
        }
        .disabled(vm.people.filter { $0.id != person.id }.isEmpty)
        .accessibilityLabel("Merge person")
    }
}