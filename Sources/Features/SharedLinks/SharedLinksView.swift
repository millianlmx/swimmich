import SwiftUI

/// "Shared" tab root (PRD §4). Lists ALL of the user's shared links (album and
/// individual), with copy-URL + revoke, pull-to-refresh, and a `+` to create a
/// new album-typed shared link. Backed by `SharedLinksViewModel`.
struct SharedLinksView: View {
    @State var vm: SharedLinksViewModel
    /// Builds the public viewer's view model when it is presented (issue #22).
    /// A link visit needs the server the app is connected to, which only exists
    /// once authenticated — so the factory takes it as an argument rather than
    /// the container holding a half-built VM.
    let makeViewer: (_ baseURL: URL, _ externalDomain: String) -> SharedLinkViewerViewModel
    @Environment(AuthViewModel.self) private var auth
    @Environment(AlbumsViewModel.self) private var albumsVM
    @Environment(\.openProfile) private var openProfile
    @State private var presentingCreate = false
    @State private var presentingViewer = false
    @State private var pendingRevokeId: String?
    @State private var showRevokeConfirm = false
    @State private var editLinkItem: EditLinkItem?

    init(
        vm: SharedLinksViewModel,
        makeViewer: @escaping (URL, String) -> SharedLinkViewerViewModel
    ) {
        _vm = State(initialValue: vm)
        self.makeViewer = makeViewer
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.sharedLinks.isEmpty && vm.loadErrorMessage != nil && !vm.isLoading {
                    ContentUnavailableView {
                        Label("Couldn't load shared links", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(vm.loadErrorMessage ?? "")
                    } actions: {
                        Button("Try Again") { Task { await vm.refresh() } }
                            .buttonStyle(PVPrimaryButtonStyle())
                    }
                } else if vm.isLoading && vm.sharedLinks.isEmpty {
                    ProgressView()
                } else if vm.sharedLinks.isEmpty {
                    ContentUnavailableView {
                        Image(systemName: "link")
                            .font(.system(size: 56)) // DS-exempt: hero illustration §8.6
                            .foregroundStyle(Color.textTertiaryPV)
                        Text("No shared links")
                            .font(.pvTitle)
                    } description: {
                        Text("Links you create to share albums will appear here.")
                    } actions: {
                        Button("Create Link") { presentingCreate = true }
                            .buttonStyle(PVPrimaryButtonStyle())
                            .padding(.horizontal, PVSpacing.s48)
                            .accessibilityIdentifier("newSharedLinkButton")
                    }
                } else {
                    linkList
                }
            }
            .navigationTitle("Shared")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        presentingViewer = true
                    } label: {
                        Label("Open a shared link", systemImage: "link.badge.plus")
                    }
                    .accessibilityIdentifier("openSharedLinkViewer")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ProfileAvatarButton { openProfile() }
                }
            }
            .task {
                await vm.load()
                await albumsVM.load() // ensure album list is ready for the create picker
            }
            .refreshable {
                await vm.refresh()
            }
            .sheet(isPresented: $presentingCreate) {
                CreateSharedLinkSheet(vm: vm)
            }
            .sheet(isPresented: $presentingViewer) {
                SharedLinkViewerView(
                    vm: makeViewer(
                        auth.baseURL ?? URL(string: "https://example.com")!,
                        auth.serverConfig?.externalDomain ?? ""
                    )
                )
            }
            .sheet(item: $editLinkItem) { item in
                EditSharedLinkSheet(link: item.link) { dto in
                    await vm.updateLink(id: item.link.id, dto: dto)
                }
                .presentationDetents([.medium, .large])
            }
            .alert("Revoke this shared link?", isPresented: $showRevokeConfirm) {
                Button("Revoke", role: .destructive) {
                    if let id = pendingRevokeId {
                        Task {
                            await vm.revoke(id: id)
                            // On success the row is gone from the data (it was
                            // already off-screen). On failure it slides back in.
                            withAnimation(PVMotion.snappy) {
                                pendingRevokeId = nil
                                showRevokeConfirm = false
                            }
                        }
                    } else {
                        withAnimation(PVMotion.snappy) {
                            showRevokeConfirm = false
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    withAnimation(PVMotion.snappy) {
                        pendingRevokeId = nil
                        showRevokeConfirm = false
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { vm.actionErrorMessage != nil },
                set: { if !$0 { vm.actionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.actionErrorMessage ?? "")
            }
        }
    }

    // MARK: - List

    private var linkList: some View {
        let sharedLinkBase = SharedLinkURL(
            serverURL: auth.baseURL ?? URL(string: "https://example.com")!,
            externalDomain: auth.serverConfig?.externalDomain ?? ""
        )
        return List {
            if let message = vm.loadErrorMessage {
                Section {
                    InlineErrorBadge(message: message, retry: { Task { await vm.refresh() } })
                        .listRowBackground(Color.clear)
                }
            }
            ForEach(vm.sharedLinks, id: \.id) { link in
                SharedLinkRow(
                    link: link,
                    sharedLinkBase: sharedLinkBase,
                    isPendingRevoke: pendingRevokeId == link.id,
                    onRevoke: { pendingRevokeId = link.id }
                )
                .contextMenu {
                    Button {
                        editLinkItem = EditLinkItem(link: link)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingRevokeId = link.id
                        showRevokeConfirm = true
                    } label: {
                        Label("Revoke", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Revoke", systemImage: "trash", role: .destructive) {
                        withAnimation(PVMotion.snappy) {
                            pendingRevokeId = link.id
                        }
                        // Present the confirmation after the row has finished
                        // sliding out, so the popup never has to snap the row
                        // back from an open swipe state.
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            guard pendingRevokeId == link.id else { return }
                            showRevokeConfirm = true
                        }
                    }
                }
                .tint(.red)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// Identifiable wrapper for the edit sheet — `SharedLinkResponseDto` is not
/// `Identifiable`, and `.sheet(item:)` requires one. Shared by both edit
/// surfaces (Shared tab + album sheet).
struct EditLinkItem: Identifiable {
    let id = UUID()
    let link: SharedLinkResponseDto
}

// MARK: - Row

/// Card-style shared-link row. Swipe-to-revoke uses native List
/// `.swipeActions` (trailing destructive), wired to the same
/// confirmation-dialog flow as the card's `onRevoke` callback.
///
/// The card is never removed from the list while the confirmation is pending:
/// it slides out to the left (as if finishing the swipe) and slides back in
/// from the left on cancel, driven by a plain `offset` transform — the only
/// row animation that works reliably inside this List. With Reduce Motion
/// enabled the slide is replaced by an opacity crossfade.
struct SharedLinkRow: View {
    let link: SharedLinkResponseDto
    /// Base for the public URL — `externalDomain` when the server advertises
    /// one, the server URL otherwise. Built by the caller so the row never has
    /// to know about auth.
    let sharedLinkBase: SharedLinkURL
    let isPendingRevoke: Bool
    let onRevoke: () -> Void
    var cardBackground: Color = Color.bgSecondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var offsetX: CGFloat = 0
    @State private var rowWidth: CGFloat = 0
    @State private var rowHeight: CGFloat = 84

    private var url: String {
        sharedLinkBase.urlString(slug: link.slug, key: link.key)
    }

    private var publicURL: URL {
        sharedLinkBase.url(slug: link.slug, key: link.key)
    }

    private var title: String {
        if let album = link.album {
            if let desc = link.description, !desc.isEmpty {
                return "\(album.albumName) • \(desc)"
            }
            return album.albumName
        }
        if let desc = link.description, !desc.isEmpty { return desc }
        // "1 photo" / "%lld photos" are the catalog's existing plural pair; a
        // hand-rolled "photo\(s)" suffix only pluralizes in English.
        if !link.assets.isEmpty {
            let count = link.assets.count
            return count == 1 ? String(localized: "1 photo") : String(localized: "\(count) photos")
        }
        return String(localized: "Untitled link")
    }

    var body: some View {
        cardContent
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { rowWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newWidth in
                            rowWidth = newWidth
                        }
                }
            }
            .offset(x: offsetX)
            .opacity(isPendingRevoke && reduceMotion ? 0 : 1)
            .clipShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
            .allowsHitTesting(!isPendingRevoke)
            .onChange(of: isPendingRevoke) { _, isPending in
                withAnimation(PVMotion.snappy) {
                    if isPending {
                        // Slide the card out and collapse its cell so the list
                        // closes up behind it — no gap while the confirmation
                        // popup is up.
                        offsetX = -rowWidth
                        rowHeight = 0
                    } else {
                        // Reopen the cell and slide the card back in from the
                        // left.
                        offsetX = 0
                        rowHeight = 84
                    }
                }
            }
            .accessibilityAction(named: Text("Revoke")) { onRevoke() }
            // Row chrome: transparent background, no separator, and — while a
            // revoke is pending — zero insets + no minimum height so the cell
            // fully collapses (no residual gap during the confirmation popup).
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(
                top: isPendingRevoke ? 0 : PVSpacing.s4,
                leading: PVSpacing.s16,
                bottom: isPendingRevoke ? 0 : PVSpacing.s4,
                trailing: PVSpacing.s16
            ))
            .environment(\.defaultMinListRowHeight, isPendingRevoke ? 0 : 44)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s8) {
            HStack(spacing: PVSpacing.s8) {
                // Type icon: album vs individual assets.
                Image(systemName: link.type == .album ? "rectangle.stack" : "photo")
                    .font(.pvBody)
                    .foregroundStyle(Color.textSecondaryPV)
                if link.password != nil {
                    Image(systemName: "lock.fill")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                Text(title)
                    .font(.pvSubhead)
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: PVSpacing.s8) {
                Text(url)
                    .font(.pvCaption).monospacedDigit()
                    .foregroundStyle(Color.textSecondaryPV)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if copied {
                    Text("Copied")
                        .font(.pvCaption)
                        .foregroundStyle(Color.immichPrimary)
                        .accessibilityIdentifier("sharedLinkCopyFeedback")
                }
                // No `.buttonStyle(.plain)` here: inside a List it swallows the
                // tap (the row looks tappable and nothing happens). The default
                // list style + an explicit hit shape is what works.
                Button {
                    UIPasteboard.general.string = url
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(Color.immichPrimary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("sharedLinkCopy-\(link.id)")
                .accessibilityLabel("Copy link")

                ShareLink(item: publicURL) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Color.immichPrimary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("sharedLinkShare-\(link.id)")
                .accessibilityLabel("Share link")
            }
        }
        .padding(PVSpacing.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
    }
}

// MARK: - Create sheet

/// Creates a new album-typed shared link. Picks an album from the user's list,
/// optional description + password, optional custom slug and expiry — then
/// switches to a "link is ready" panel that has already copied the URL.
///
/// The second state mirrors Flutter (`shared_link_edit.page.dart`): after a
/// successful create the client copies the link and shows it, instead of
/// dismissing and leaving the user to hunt for the fresh row.
struct CreateSharedLinkSheet: View {
    @Bindable var vm: SharedLinksViewModel
    @Environment(AuthViewModel.self) private var auth
    @Environment(AlbumsViewModel.self) private var albumsVM
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAlbumId: String?
    @State private var description = ""
    @State private var usePassword = false
    @State private var password = ""
    @State private var slug = ""
    @State private var expiresAt: Date?
    @State private var created: SharedLinkResponseDto?
    @State private var createTick = 0
    @State private var copiedTick = 0
    @State private var didCopyLink = false

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    // Each title literal sits in its own `navigationTitle` call:
                    // a ternary's strings are invisible to the extractor.
                    readyPanel(for: created)
                        .navigationTitle("Link ready")
                } else {
                    form
                        .navigationTitle("New Shared Link")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if created == nil {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("cancelCreateSharedLink")
                    } else {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("closeSharedLinkSheet")
                    }
                }
                if created == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { create() }
                            .fontWeight(.semibold)
                            .disabled(selectedAlbumId == nil)
                            .accessibilityIdentifier("confirmCreateSharedLink")
                    }
                }
            }
        }
        .appSensoryFeedback(.success, trigger: createTick)
    }

    private var form: some View {
        Form {
            Section("Album") {
                if albumsVM.albums.isEmpty {
                    Text("You have no albums yet.")
                        .foregroundStyle(Color.textSecondaryPV)
                } else {
                    Picker("Album", selection: $selectedAlbumId) {
                        ForEach(albumsVM.albums, id: \.id) { album in
                            Text(album.albumName).tag(Optional(album.id))
                        }
                    }
                    .accessibilityIdentifier("sharedLinkAlbumPicker")
                }
            }
            Section("Options") {
                TextField("Description (optional)", text: $description)
                Toggle("Password protect", isOn: $usePassword)
                if usePassword {
                    SecureField("Password", text: $password)
                }
                // The stored slug never carries the prefix: the server builds
                // `…/s/<slug>` itself, and the public URL helper joins it the
                // same way. The prefix is an affordance of the field.
                HStack(spacing: 0) {
                    if !slug.isEmpty {
                        Text("/s/")
                            .foregroundStyle(Color.textSecondaryPV)
                            .accessibilityHidden(true)
                    }
                    TextField("Custom URL", text: $slug)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("sharedLinkSlugField")
                }
            }
            Section("Expiration") {
                SharedLinkExpiryPicker(date: $expiresAt)
            }
        }
    }

    /// Post-create panel: the URL, already on the pasteboard, with the same
    /// copy/share pair the list rows offer.
    private func readyPanel(for link: SharedLinkResponseDto) -> some View {
        let url = sharedLinkBase.url(slug: link.slug, key: link.key)
        return VStack(spacing: PVSpacing.s16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)) // DS-exempt: hero confirmation glyph
                .foregroundStyle(Color.immichSuccess)
            Text(url.absoluteString)
                .font(.pvCaption).monospacedDigit()
                .foregroundStyle(Color.textSecondaryPV)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)
                .accessibilityIdentifier("sharedLinkReadyURL")
            HStack(spacing: PVSpacing.s12) {
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    didCopyLink = true
                    copiedTick &+= 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { didCopyLink = false }
                } label: {
                    // Two literal labels instead of one ternary: `Label(didCopyLink
                    // ? "Copied" : "Copy link", …)` produces no extractable string.
                    if didCopyLink {
                        Label("Copied", systemImage: "checkmark")
                    } else {
                        Label("Copy link", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(PVPrimaryButtonStyle())
                .accessibilityIdentifier("sharedLinkReadyCopy")
                ShareLink(item: url) {
                    Label("Share link", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("sharedLinkReadyShare")
            }
            .padding(.horizontal, PVSpacing.s24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(PVSpacing.s24)
        // No identifier on this container: an `.accessibilityIdentifier` set on a
        // container propagates to every descendant and OVERWRITES theirs — the
        // URL text and both buttons all came back as "sharedLinkReadyScreen",
        // which is invisible on screen and makes the identifiers useless.
        .appSensoryFeedback(.success, trigger: copiedTick)
        .task {
            // Flutter copies the link as soon as it exists — the user came here
            // to get one.
            UIPasteboard.general.string = url.absoluteString
        }
    }

    private var sharedLinkBase: SharedLinkURL {
        SharedLinkURL(
            serverURL: auth.baseURL ?? URL(string: "https://example.com")!,
            externalDomain: auth.serverConfig?.externalDomain ?? ""
        )
    }

    private func create() {
        guard let albumId = selectedAlbumId else { return }
        Task {
            let link = await vm.createAlbumLink(
                albumId: albumId,
                description: description.isEmpty ? nil : description,
                password: usePassword ? password : nil,
                slug: slug,
                expiresAt: expiresAt
            )
            guard let link else { return }
            createTick &+= 1
            created = link
        }
    }
}
