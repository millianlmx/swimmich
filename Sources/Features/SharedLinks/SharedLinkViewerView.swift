import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Public shared-link viewer (issue #22): paste a link someone sent you, unlock
/// it if it has a password, browse what it contains, and — when the link allows
/// it — add a photo to it.
///
/// Presented as a sheet from the Shared tab: the task is self-contained
/// (HIG: modal for self-contained tasks, always with a clear dismiss) and it
/// belongs to no navigation stack of its own.
struct SharedLinkViewerView: View {
    @State var vm: SharedLinkViewerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var openPage: AssetPage?

    init(vm: SharedLinkViewerViewModel) {
        _vm = State(initialValue: vm)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .entry:
                    entryForm
                case .passwordRequired:
                    passwordForm
                case .loading:
                    ProgressView().controlSize(.large)
                case .opened:
                    openedLink
                case .deadLink:
                    deadLink
                case .failed(let text):
                    failureState(text)
                }
            }
            .navigationTitle("Shared Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("closeSharedLinkViewer")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if vm.phase == .opened, vm.canUpload {
                        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                            Label("Add photos", systemImage: "photo.badge.plus")
                        }
                        .accessibilityIdentifier("addPhotoToSharedLink")
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                pickerItem = nil
                Task { await uploadPicked(item) }
            }
            .pvFullScreenCover(item: $openPage) { page in
                SharedLinkAssetPager(
                    assets: vm.assets,
                    baseURL: vm.baseURL,
                    sharedLink: vm.credential,
                    startIndex: page.index
                ) { openPage = nil }
            }
        }
    }

    // MARK: - Entry

    private var entryForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PVSpacing.s24) {
                VStack(alignment: .leading, spacing: PVSpacing.s8) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 44)) // DS-exempt: hero illustration §8.6
                        .foregroundStyle(Color.immichPrimary)
                    Text("Open a shared link")
                        .font(.pvTitle)
                    Text("Paste the link someone shared with you — or its key — to browse the photos it contains.")
                        .font(.pvSubhead)
                        .foregroundStyle(Color.textSecondaryPV)
                }

                PVInputGroup {
                    TextField("https://photos.example.com/s/…", text: $vm.linkText)
                        .font(.pvBody)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .pvFieldSurface()
                        .accessibilityIdentifier("sharedLinkViewerField")
                        .onSubmit { Task { await vm.openLink() } }
                }

                if let message = vm.message {
                    InlineErrorBadge(message: message)
                }

                Button("Open") { Task { await vm.openLink() } }
                    .buttonStyle(PVPrimaryButtonStyle())
                    .accessibilityIdentifier("openSharedLink")
            }
            .padding(.horizontal, PVSpacing.s16)
            .padding(.top, PVSpacing.s24)
        }
    }

    // MARK: - Password

    private var passwordForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PVSpacing.s24) {
                VStack(alignment: .leading, spacing: PVSpacing.s8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40)) // DS-exempt: hero illustration §8.6
                        .foregroundStyle(Color.immichPrimary)
                    Text("Password required")
                        .font(.pvTitle)
                    Text("This link is protected. Enter the password you were given with it.")
                        .font(.pvSubhead)
                        .foregroundStyle(Color.textSecondaryPV)
                }

                PVInputGroup {
                    SecureField("Password", text: $vm.password)
                        .font(.pvBody)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .pvFieldSurface()
                        .accessibilityIdentifier("sharedLinkViewerPassword")
                        .onSubmit { Task { await vm.submitPassword() } }
                }

                if let message = vm.message {
                    InlineErrorBadge(message: message)
                }

                Button("Unlock") { Task { await vm.submitPassword() } }
                    .buttonStyle(PVPrimaryButtonStyle())
                    .accessibilityIdentifier("submitSharedLinkPassword")

                Button("Open another link") { vm.reset() }
                    .buttonStyle(PVSubtleButtonStyle())
                    .accessibilityIdentifier("resetSharedLinkViewer")
            }
            .padding(.horizontal, PVSpacing.s16)
            .padding(.top, PVSpacing.s24)
        }
    }

    // MARK: - Opened link

    private var openedLink: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PVSpacing.s16) {
                header

                if let message = vm.message {
                    InlineErrorBadge(message: message)
                        .accessibilityIdentifier("sharedLinkViewerMessage")
                }

                if vm.assets.isEmpty {
                    emptyLink
                } else {
                    assetGrid
                }
            }
            .padding(.top, PVSpacing.s8)
        }
        .refreshable { await vm.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PVSpacing.s4) {
            Text(vm.title)
                .font(.pvHeadline)
                .accessibilityIdentifier("sharedLinkViewerTitle")
            Text(vm.subtitle)
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
                .accessibilityIdentifier("sharedLinkViewerSubtitle")
        }
        .padding(.horizontal, PVSpacing.s16)
    }

    private var assetGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s2), count: 3),
            spacing: PVSpacing.s2
        ) {
            ForEach(Array(vm.assets.enumerated()), id: \.element.id) { index, asset in
                AssetThumbnailCell(
                    asset: asset,
                    baseURL: vm.baseURL,
                    token: nil,
                    onTap: { openPage = AssetPage(index: index) },
                    sharedLink: vm.credential
                )
                .accessibilityIdentifier("sharedLinkAsset_\(asset.id)")
                .onAppear {
                    // Prefetch a screenful early so an album link never
                    // dead-ends on a spinner.
                    if index == vm.assets.count - 1, vm.hasMore {
                        Task { await vm.loadMoreAlbumAssets() }
                    }
                }
            }
        }
        .padding(.horizontal, PVSpacing.s4)
    }

    private var emptyLink: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(vm.canUpload ? "This shared album has no photos. You can add the first one."
                              : "This shared link holds no photos.")
        }
        .accessibilityIdentifier("sharedLinkViewerEmpty")
    }

    // MARK: - Terminal states

    private var deadLink: some View {
        ContentUnavailableView {
            Label("This link is no longer available", systemImage: "link.slash")
        } description: {
            Text("It was revoked or it expired. Ask for a new one.")
        } actions: {
            Button("Open another link") { vm.reset() }
                .buttonStyle(PVPrimaryButtonStyle())
                .accessibilityIdentifier("resetSharedLinkViewer")
        }
        .accessibilityIdentifier("sharedLinkViewerDeadLink")
    }

    private func failureState(_ text: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't open this link", systemImage: "wifi.exclamationmark")
        } description: {
            Text(text)
        } actions: {
            Button("Try Again") { Task { await vm.load() } }
                .buttonStyle(PVPrimaryButtonStyle())
                .accessibilityIdentifier("retrySharedLinkViewer")
            Button("Open another link") { vm.reset() }
                .buttonStyle(PVSubtleButtonStyle())
                .accessibilityIdentifier("resetSharedLinkViewer")
        }
        .accessibilityIdentifier("sharedLinkViewerFailure")
    }

    // MARK: - Guest upload

    /// Copies the picked photo to a temp file and hands it to the view model.
    ///
    /// The bytes go through memory once (`loadTransferable`): this is one
    /// user-initiated photo, not a library scan, and `PhotosPicker` is the only
    /// route that needs no photo-library authorization — a visitor has no reason
    /// to grant one. The file name keeps the picked type's extension, because
    /// the server derives the asset's mime type from it.
    private func uploadPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            vm.message = String(localized: "That photo could not be read.")
            return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        let filename = "shared-link-\(UUID().uuidString).\(ext)"
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
        } catch {
            vm.message = String(localized: "That photo could not be read.")
            return
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        await vm.upload(fileURL: fileURL, filename: filename, deviceAssetId: item.itemIdentifier ?? UUID().uuidString)
    }
}

/// Index of the photo whose full-size page is open. `Int` identity is enough:
/// the list only grows at its end, so an index keeps pointing at the same asset
/// for the life of the presentation.
private struct AssetPage: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Read-only full-screen pager for a link's photos.
///
/// Deliberately not `PhotoViewer`: that one is built around the owner's
/// session (favorite / edit / delete / EXIF all run on the signed-in client),
/// and none of those belong to a visitor. This keeps the one gesture that
/// matters — pinch, double-tap, swipe between photos — on the same
/// `ZoomableImageView` the owner's viewer uses.
private struct SharedLinkAssetPager: View {
    let assets: [AssetReactItem]
    let baseURL: URL
    let sharedLink: SharedLinkCredential?
    let onClose: () -> Void

    @State private var index: Int

    init(
        assets: [AssetReactItem],
        baseURL: URL,
        sharedLink: SharedLinkCredential?,
        startIndex: Int,
        onClose: @escaping () -> Void
    ) {
        self.assets = assets
        self.baseURL = baseURL
        self.sharedLink = sharedLink
        self.onClose = onClose
        _index = State(initialValue: assets.isEmpty ? 0 : min(max(startIndex, 0), assets.count - 1))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(assets.enumerated()), id: \.element.id) { offset, asset in
                    ZoomableImageView(
                        asset: asset,
                        baseURL: baseURL,
                        token: nil,
                        sharedLink: sharedLink,
                        offersRetry: true
                    )
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            bar
        }
        .statusBarHidden(true)
    }

    private var bar: some View {
        HStack {
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .pvFloating(.circle)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("closeSharedLinkPager")

            Spacer()

            if assets.count > 1 {
                Text("\(index + 1) of \(assets.count)")
                    .font(.pvCaption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, PVSpacing.s12)
                    .padding(.vertical, PVSpacing.s8)
                    .pvFloating(.pill)
                    .accessibilityIdentifier("sharedLinkPagerPosition")
            }
        }
        .padding(.horizontal, PVSpacing.s16)
        .pvFullscreenChromeTextCap()
    }
}
