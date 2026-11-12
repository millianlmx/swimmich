import PhotosUI
import SwiftUI

/// Profile picture screen (gap G16): choose a photo, frame the square the
/// avatar will show, send it — or remove the published one.
///
/// Pushed from `ProfileView`'s `NavigationStack`, so it deliberately carries no
/// `NavigationStack` of its own (one bar, the convention of `LanguageSettingsView`
/// and `TrashView`).
///
/// The screen does three things, in this order, and nothing else: choose →
/// frame → send. No aspect-ratio picker, no rotation, no filters: the avatar is
/// drawn in a `Circle` and the server takes one binary, so only the square
/// exists visually.
struct ProfilePictureView: View {
    @Bindable var vm: ProfilePictureViewModel

    @Environment(AuthViewModel.self) private var auth
    @PVReduceMotion private var reduceMotion

    @State private var pickerItem: PhotosPickerItem?
    @State private var isConfirmingRemoval = false
    /// The square as the finger found it. `DragGesture` reports a total
    /// translation, so it has to be applied to the rect the gesture started on
    /// and not to the one the previous frame produced (which would compound and
    /// run the square off the screen).
    @State private var dragAnchor: CGRect?
    /// Same, for the pinch: `MagnifyGesture` reports a factor relative to the
    /// start of the gesture.
    @State private var pinchAnchor: CGFloat?

    private static let avatarSide: CGFloat = 120
    private static let previewSide: CGFloat = 120
    private static let canvasHeight: CGFloat = 320

    var body: some View {
        ScrollView {
            VStack(spacing: PVSpacing.s24) {
                header
                emptyState
                chooser
                if let pending = vm.pendingImage {
                    cropBlock(pending)
                        .transition(PVMotion.appearance(.opacityAndScale(0.98), reduceMotion: reduceMotion).anyTransition)
                }
                actions
            }
            .padding(PVSpacing.s16)
            .animation(
                PVMotion.movement(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
                value: vm.pendingImage != nil
            )
        }
        .background(Color.bgPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ImmichAppBar(title: "Profile Picture") }
        }
        .immichAppBarTitleHeader("Profile Picture")
        .task { await vm.load() }
        .refreshable { await vm.load() }
        .confirmationDialog(
            "Remove profile picture?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Photo", role: .destructive) {
                Task { await vm.deletePhoto() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your avatars go back to your initials.")
        }
        .alert("Could not update profile picture", isPresented: isShowingError) {
            Button("OK", role: .cancel) { vm.clearError() }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: PVSpacing.s12) {
            avatar
            VStack(spacing: PVSpacing.s4) {
                Text("Profile Picture")
                    .font(.pvSubhead)
                    .foregroundStyle(Color.textPrimaryPV)
                phaseBadge
            }
        }
    }

    /// Same circle the hub row draws: the photo when the server has one, the
    /// initials otherwise, and the disc alone while the identity is in flight
    /// (the space is reserved, so nothing jumps into place).
    @ViewBuilder
    private var avatar: some View {
        if vm.hasPhoto, let url = vm.avatarURL {
            AuthenticatedAsyncImage(url: url, token: auth.accessToken)
                .frame(width: Self.avatarSide, height: Self.avatarSide)
                .clipShape(Circle())
                .accessibilityIdentifier("profilePictureAvatar")
                .accessibilityLabel(Text("Profile picture"))
        } else if let user = vm.avatarUser {
            UserAvatarCircle(user: user, size: Self.avatarSide)
                .accessibilityIdentifier("profilePictureAvatar")
                .accessibilityLabel(Text("No profile picture"))
                // Additive (2026-09-15, profile-picture scenario): the initials
                // were merged into the container's label, so neither VoiceOver
                // nor a UI test could read what the circle actually shows — and
                // the initials are the ONLY thing telling this branch apart from
                // the empty disc below (both spell "No profile picture").
                .accessibilityValue(Text(UserAvatarCircle.initials(from: user.name)))
        } else {
            Circle()
                .fill(Color.bgTertiary)
                .frame(width: Self.avatarSide, height: Self.avatarSide)
                .accessibilityIdentifier("profilePictureAvatar")
                .accessibilityLabel(Text("No profile picture"))
        }
    }

    /// Only while a write is in flight: an idle "Saved" would also describe a
    /// photo uploaded months ago, which this screen cannot tell apart.
    @ViewBuilder
    private var phaseBadge: some View {
        switch vm.phase {
        case .saving:
            PVStatusBadge(text: String(localized: "Uploading"), color: .immichWarning, symbol: "arrow.up.circle.fill")
        case .deleting:
            PVStatusBadge(text: String(localized: "Removing"), color: .immichWarning, symbol: "trash.circle.fill")
        default:
            EmptyView()
        }
    }

    // MARK: - Picker

    @ViewBuilder
    private var emptyState: some View {
        if vm.pendingImage == nil && !vm.hasPhoto && vm.phase != .loading {
            ContentUnavailableView {
                Label("No profile picture", systemImage: "person.crop.circle")
            } description: {
                Text("Pick a photo and it will show up next to your name.")
            }
        }
    }

    private var chooser: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            Label("Choose from Library", systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(PVSubtleButtonStyle())
        .accessibilityIdentifier("profilePictureChooseButton")
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                // `loadTransferable` is the one route that needs no photo-library
                // authorization: PhotosPicker runs out of process.
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    vm.choose(image)
                } else {
                    vm.errorMessage = String(localized: "That photo could not be read.")
                }
                pickerItem = nil
            }
        }
    }

    // MARK: - Crop

    private func cropBlock(_ pending: UIImage) -> some View {
        VStack(spacing: PVSpacing.s8) {
            GeometryReader { geo in
                let fitted = Self.fittedSize(pending.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: pending)
                        .resizable()
                        .scaledToFit()
                        .frame(width: fitted.width, height: fitted.height)

                    dimming(fitted: fitted)

                    RuleOfThirdsOverlay()
                        .frame(
                            width: vm.cropRect.width * fitted.width,
                            height: vm.cropRect.height * fitted.height
                        )
                        .offset(
                            x: vm.cropRect.minX * fitted.width,
                            y: vm.cropRect.minY * fitted.height
                        )
                }
                .frame(width: fitted.width, height: fitted.height)
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(cropDrag(fitted: fitted))
                .simultaneousGesture(cropPinch())
                // One VoiceOver element: the mask, the photo and the handle are
                // a single control, not three readings.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(vm.cropAccessibilityLabel))
                .accessibilityIdentifier("profilePictureCropCanvas")
            }
            .frame(height: Self.canvasHeight)

            HStack(spacing: PVSpacing.s8) {
                Text("Drag to move the square, pinch to resize it.")
                    .font(.pvCaption)
                    .foregroundStyle(Color.textSecondaryPV)
                Spacer(minLength: PVSpacing.s8)
                Button("Reset") {
                    withAnimation(PVMotion.movement(.easeInOut(duration: 0.25), reduceMotion: reduceMotion)) {
                        vm.resetCrop()
                    }
                }
                .buttonStyle(PVSubtleButtonStyle())
                .accessibilityIdentifier("profilePictureCropResetButton")
            }

            preview(pending)
        }
        .pvFieldSurface()
        .background(Color.bgSecondary)
    }

    /// Everything outside the square, in one even-odd fill — a crop darkens
    /// what it leaves out.
    private func dimming(fitted: CGSize) -> some View {
        let crop = CGRect(
            x: vm.cropRect.minX * fitted.width,
            y: vm.cropRect.minY * fitted.height,
            width: vm.cropRect.width * fitted.width,
            height: vm.cropRect.height * fitted.height
        )
        return Path { path in
            path.addRect(CGRect(origin: .zero, size: fitted))
            path.addRect(crop)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// Screen points → normalized 0..1 through `EditPipeline`'s helper: the
    /// conversion exists and is tested, so the view does not redo it.
    private func cropDrag(fitted: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let anchor = dragAnchor ?? vm.cropRect
                if dragAnchor == nil { dragAnchor = anchor }
                let start = CGRect(
                    x: anchor.minX * fitted.width,
                    y: anchor.minY * fitted.height,
                    width: anchor.width * fitted.width,
                    height: anchor.height * fitted.height
                )
                let moved = start.offsetBy(dx: value.translation.width, dy: value.translation.height)
                vm.moveCrop(to: EditPipeline.gestureRectToNormalized(moved, in: fitted))
            }
            .onEnded { _ in dragAnchor = nil }
    }

    private func cropPinch() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let anchor = pinchAnchor ?? vm.cropRect.width
                if pinchAnchor == nil { pinchAnchor = anchor }
                vm.resizeCrop(toFraction: anchor * value.magnification)
            }
            .onEnded { _ in pinchAnchor = nil }
    }

    /// Exactly the square that will be uploaded, rendered in a circle — the
    /// avatar's own crop, so nothing is a surprise after Save.
    private func preview(_ pending: UIImage) -> some View {
        let side = Self.previewSide
        let scale = side / max(vm.cropRect.width * pending.size.width, 0.001)
        return VStack(spacing: PVSpacing.s8) {
            Image(uiImage: pending)
                .resizable()
                .frame(width: pending.size.width * scale, height: pending.size.height * scale)
                .offset(
                    x: -vm.cropRect.minX * pending.size.width * scale,
                    y: -vm.cropRect.minY * pending.size.height * scale
                )
                .frame(width: side, height: side, alignment: .topLeading)
                .clipShape(Circle())
                .accessibilityIdentifier("profilePicturePreview")
                .accessibilityLabel(Text("Preview"))

            Text("Preview")
                .font(.pvCaption)
                .foregroundStyle(Color.textSecondaryPV)
        }
        .animation(
            PVMotion.movement(.easeInOut(duration: 0.2), reduceMotion: reduceMotion),
            value: vm.cropRect
        )
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: PVSpacing.s8) {
            if vm.phase == .saving {
                HStack(spacing: PVSpacing.s8) {
                    ProgressView()
                    Text("Uploading photo…")
                        .font(.pvCaption)
                        .foregroundStyle(Color.textSecondaryPV)
                }
                .frame(maxWidth: .infinity)
                .pvFieldSurface()
                .background(Color.bgSecondary)
                .accessibilityIdentifier("profilePictureUploadingIndicator")
                .transition(.opacity)
            }

            Button {
                Task { await vm.save() }
            } label: {
                Text("Save").frame(maxWidth: .infinity)
            }
            .buttonStyle(PVPrimaryButtonStyle())
            .disabled(vm.pendingImage == nil || vm.phase != .idle)
            .accessibilityIdentifier("profilePictureSaveButton")

            if vm.pendingImage != nil {
                Button("Cancel") { vm.cancelCrop() }
                    .buttonStyle(PVSubtleButtonStyle())
                    .accessibilityIdentifier("profilePictureCancelButton")
            }

            if vm.hasPhoto {
                Button(role: .destructive) {
                    isConfirmingRemoval = true
                } label: {
                    Text("Remove Photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(PVSubtleButtonStyle())
                .disabled(vm.phase != .idle)
                .accessibilityIdentifier("profilePictureRemoveButton")
            }
        }
        // A second tap during a write would start a second upload of the same
        // square: the whole block goes inert until the phase comes back.
        .disabled(vm.phase == .saving || vm.phase == .deleting)
    }

    // MARK: - Helpers

    /// The picked photo scaled to fit the canvas, preserving its ratio.
    private static func fittedSize(_ imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return container }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private var isShowingError: Binding<Bool> {
        Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.clearError() } }
        )
    }
}
