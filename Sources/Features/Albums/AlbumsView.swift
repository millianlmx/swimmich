import SwiftUI

/// Albums tab (AC-514). A Photos-style grid of premium portrait album cards;
/// tapping a card pushes `AlbumDetailView`. The `+` toolbar button and the
/// empty-state CTA present `CreateAlbumSheet`.
///
/// Navigation follows Apple HIG for a top-level content tab: a native large,
/// scroll-collapsing title (`.large`) — no custom brand wordmark in the toolbar.
///
/// `AlbumsViewModel` is injected via `@Environment` from RootView so the
/// Timeline "Add to Album" picker shares the same instance (FM-3 mitigation).
struct AlbumsView: View {
    @Bindable var vm: AlbumsViewModel
    @Environment(AuthViewModel.self) private var auth
    @Environment(\.openProfile) private var openProfile
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentingCreate = false
    @Namespace private var zoomNamespace

    private let columns = Array(repeating: GridItem(.flexible(), spacing: PVSpacing.s12), count: 2)

    var body: some View {
        NavigationStack {
            Group {
                if vm.albums.isEmpty && vm.loadErrorMessage != nil && !vm.isLoading {
                    errorState
                } else if vm.isLoading && vm.albums.isEmpty {
                    ScrollView {
                        PVSkeletonGrid(rows: 4, columnCount: 2)
                            .padding(.horizontal, PVSpacing.s4)
                            .padding(.top, PVSpacing.s4)
                    }
                } else if vm.albums.isEmpty {
                    emptyState
                } else {
                    albumGrid
                }
            }
            .navigationTitle("Albums")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ProfileAvatarButton { openProfile() }
                }
            }
            .task { await vm.load() }
            .refreshable { await vm.refresh() }
            .sheet(isPresented: $presentingCreate) {
                CreateAlbumSheet(vm: vm, preselectedAssetIds: nil)
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

    // MARK: - States

    private var errorState: some View {
        ContentUnavailableView {
            Label("Couldn't load albums", systemImage: "wifi.exclamationmark")
        } description: {
            Text(vm.loadErrorMessage ?? "")
        } actions: {
            Button("Try Again") { Task { await vm.refresh() } }
                .buttonStyle(PVPrimaryButtonStyle())
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 56)) // DS-exempt: hero illustration §8.6
                .foregroundStyle(Color.textTertiaryPV)
            Text("No albums yet")
                .font(.pvTitle)
        } description: {
            Text("Create an album to organize your photos.")
        } actions: {
            Button("Create Album") { presentingCreate = true }
                .buttonStyle(PVPrimaryButtonStyle())
                .padding(.horizontal, PVSpacing.s48)
        }
    }

    // MARK: - Grid

    private var albumGrid: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s16) {
                if let message = vm.loadErrorMessage {
                    Section {
                        InlineErrorBadge(message: message, retry: { Task { await vm.refresh() } })
                    }
                    .padding(.horizontal, PVSpacing.s4)
                    .padding(.top, PVSpacing.s4)
                }
                LazyVGrid(columns: columns, spacing: PVSpacing.s16) {
                    ForEach(vm.albums, id: \.id) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                                .zoomNavigationTransitioniOS27(sourceID: album.id, in: zoomNamespace)
                        } label: {
                            AlbumCard(
                                album: album,
                                baseURL: auth.baseURL ?? defaultBaseURL,
                                token: auth.accessToken,
                                showsShadow: colorScheme == .light,
                                zoomNamespace: zoomNamespace
                            )
                        }
                        .buttonStyle(AlbumCardPressStyle(reduceMotion: reduceMotion))
                    }
                }
                .padding(.horizontal, PVSpacing.s4)
                .padding(.top, PVSpacing.s4)
            }
        }
    }

    private var defaultBaseURL: URL { URL(string: "https://example.com")! }

    // MARK: - Card

    /// Premium portrait (3:4) album card. Opaque content surface (glass is for
    /// the control layer per WWDC25-219/356 — never the photo), 16pt continuous
    /// corners, a soft diffuse shadow in light mode, and title + count beneath.
    /// A glass "shared" badge floats on the cover when the album is collaborative.
    fileprivate struct AlbumCard: View {
        let album: AlbumResponseDto
        let baseURL: URL
        let token: String?
        let showsShadow: Bool
        let zoomNamespace: Namespace.ID

        var body: some View {
            VStack(alignment: .leading, spacing: PVSpacing.s4) {
                cover
                VStack(alignment: .leading, spacing: PVSpacing.s2) {
                    Text(album.albumName)
                        .font(.pvHeadline)
                        .foregroundStyle(Color.textPrimaryPV)
                        .lineLimit(1)
                    Text("\(album.assetCount) Photos")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                .padding(.leading, PVSpacing.s4)
            }
            .shadow(color: .black.opacity(showsShadow ? 0.12 : 0), radius: showsShadow ? 8 : 0, x: 0, y: 4)
        }

        private var cover: some View {
            Color.clear
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    if let thumbId = album.albumThumbnailAssetId {
                        AuthenticatedAsyncImage(
                            url: ImmichAssetURL.thumbnail(assetId: thumbId, thumbhash: "", baseURL: baseURL),
                            token: token
                        )
                    } else {
                        ZStack {
                            Color.bgTertiary
                            Image(systemName: "rectangle.stack")
                                .font(.pvTitleXL)
                                .foregroundStyle(Color.textSecondaryPV)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if album.shared {
                        GlassEffectContainer {
                            Image(systemName: "person.2.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(PVSpacing.s4)
                                .glassEffect(.regular.tint(.black.opacity(0.6)), in: Capsule())
                                .padding(PVSpacing.s4)
                        }
                        .accessibilityLabel("Shared album")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: PVRadius.lg, style: .continuous))
                // Zoom-morph source (iOS 27+): the push zooms this cover into
                // the detail hero. Gated to iOS 27 because the zoom transition
                // interacts with the destination toolbar on iOS 26 (deferred
                // trailing-item glyph render, fixed in iOS 27 DB5); on iOS 26
                // the push falls back to the system slide (Apple Files parity,
                // no toolbar glyph lag).
                .matchedTransitionSourceiOS27(id: album.id, in: zoomNamespace)
        }
    }
}

/// Press style for album cards: a subtle 0.97 scale-down spring on tap
/// (the premium, system-consistent touch feedback). Disabled under Reduce Motion.
struct AlbumCardPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : PVMotion.snappy, value: configuration.isPressed)
    }
}

// MARK: - iOS-27 zoom gating
//
// `.navigationTransition(.zoom)` + `.matchedTransitionSource` are available on
// iOS 18+, but on iOS 26 the zoom push defers the destination's trailing
// toolbar-item glyph render (~2s lag, fixed only in iOS 27 DB5). Apple Files
// avoids this by using a standard push. We gate the zoom to iOS 27+ so iOS 26
// gets the Files-style push (no lag), and iOS 27+ keeps the zoom-morph open.
private extension View {
    @ViewBuilder
    func zoomNavigationTransitioniOS27(sourceID: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 27, *) {
            self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
    }

    @ViewBuilder
    func matchedTransitionSourceiOS27(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 27, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }
}
