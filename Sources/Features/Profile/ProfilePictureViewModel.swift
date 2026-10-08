import Foundation
import UIKit
import CoreImage
import Observation

/// Profile picture screen (gap G16): reads the signed-in user, crops the picked
/// photo to a square and uploads it, or removes it.
///
/// The crop is deliberately **not** a second editor: the avatar is drawn inside
/// a `Circle`, so only the square matters, and `EditState`/`EditPipeline` —
/// already used by the photo editor — hold that square in normalized 0..1
/// coordinates relative to the original extent. A private, JPEG-only pipeline
/// here would be a copy of code that already exists and is already tested.
@Observable
@MainActor
final class ProfilePictureViewModel {

    /// What the screen is doing. `idle` is also the "you may act" state: Save
    /// and the picker are only enabled outside a write.
    enum Phase: Equatable {
        case idle
        case loading
        case saving
        case deleting
    }

    /// Shortest acceptable side, in pixels. Below this the 512-point avatar
    /// would be an upscale of a thumbnail — visibly soft, and the server
    /// accepts it without complaint, so the refusal has to happen here.
    static let minimumSide: CGFloat = 128

    /// Side of the square sent to the server. The upstream Flutter client
    /// uploads a 512-pixel JPEG; the avatar renders at 120 pt at most, so 512
    /// keeps it crisp on a 3× display without shipping a multi-megabyte photo.
    static let outputSide: CGFloat = 512

    /// Filename the server stores; its extension is what the `FileInterceptor`
    /// keys the mime type off, and the multipart part carries `image/jpeg`.
    static let uploadFilename = "profile.jpg"

    private let client: any ImmichClient
    private let baseURL: URL?
    private let token: String?

    private(set) var phase: Phase = .idle

    /// The identity as the server last reported it. Never cleared by a failed
    /// load: a screen that lost its avatar because the network blinked would be
    /// worse than one showing the previous photo with an error badge.
    private(set) var profile: UserAdminResponseDto?

    var errorMessage: String?

    /// The picked, orientation-normalized photo, cropped on screen but not yet
    /// sent. `nil` means "nothing chosen" — the empty state.
    private(set) var pendingImage: UIImage?

    /// Cropping square, normalized 0..1 with a UIKit top-left origin (exactly
    /// `EditState.cropRect`'s representation). Starts as the whole image: until
    /// a photo is picked there is nothing to crop.
    private(set) var cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    init(client: any ImmichClient, baseURL: URL?, token: String?) {
        self.client = client
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: - Derived state

    /// True when the server holds a photo for this user — the switch between
    /// the photo and the initials fallback, in this screen and in every avatar.
    var hasPhoto: Bool {
        !(profile?.profileImagePath ?? "").isEmpty
    }

    /// Cache-busted URL of the published photo. `ImageCache` is keyed by URL,
    /// so `profileChangedAt` riding along is what makes a replacement photo
    /// appear instead of the cached previous one (AC-5162).
    var avatarURL: URL? {
        guard let profile, let baseURL, !(profile.profileImagePath ?? "").isEmpty else { return nil }
        return ImmichAssetURL.profileImage(userId: profile.id, changedAt: profile.profileChangedAt, baseURL: baseURL)
    }

    /// The identity in the shape the shared avatar component takes — so the
    /// hub row and this screen's header cannot drift apart.
    var avatarUser: UserResponseDto? {
        guard let profile else { return nil }
        return UserResponseDto(
            id: profile.id,
            name: profile.name,
            email: profile.email,
            profileImagePath: profile.profileImagePath ?? "",
            avatarColor: profile.avatarColor ?? "",
            profileChangedAt: profile.profileChangedAt ?? ""
        )
    }

    /// Spoken description of the crop square. The canvas is one VoiceOver
    /// element (mask + image + handle are one control, not three).
    var cropAccessibilityLabel: String {
        String(localized: "Crop square, \(Int((cropRect.width * 100).rounded())) percent of the image")
    }

    // MARK: - Loading

    /// `GET /api/users/me`. A failure keeps the profile already known and
    /// surfaces the message (pattern of `MapViewModel`).
    func load() async {
        guard phase == .idle else { return }
        phase = .loading
        defer { phase = .idle }
        do {
            profile = try await client.getMyUser()
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    // MARK: - Choosing and cropping

    /// Takes over the picked photo: normalizes its EXIF orientation (the
    /// pipeline assumes an upright image, so a `.left`/`.right` photo would
    /// otherwise be cropped and sent on its side), refuses one too small to
    /// fill an avatar, and centers the square.
    func choose(_ image: UIImage) {
        let upright = Self.upright(image)
        let shortestSide = min(upright.size.width, upright.size.height) * upright.scale
        guard shortestSide >= Self.minimumSide else {
            // The pending image is left alone on purpose: a rejected pick must
            // not throw away the crop the user was in the middle of.
            errorMessage = String(localized: "That photo is too small. Choose one at least 128 pixels on its shortest side.")
            return
        }
        pendingImage = upright
        cropRect = Self.centeredSquare(for: upright.size)
        errorMessage = nil
    }

    /// The largest square centered in a `size` image, in normalized 0..1 space.
    ///
    /// Normalized coordinates are relative to the original extent on **each**
    /// axis, so the square's normalized width and height differ for a non-square
    /// photo — and both are 1 for a square one. (Same construction as
    /// `PhotoEditorViewModel.setAspectRatio`, which cannot do this because it
    /// never sees the image size.)
    static func centeredSquare(for size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let side = min(size.width, size.height)
        let width = side / size.width
        let height = side / size.height
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    /// Moves the square to a newly computed normalized rect, keeping its size
    /// and clamping it inside the image — the gesture converts screen points to
    /// normalized space, this keeps the result legal.
    func moveCrop(to rect: CGRect) {
        let width = min(max(rect.width, Self.minimumSquareSide), 1)
        let height = min(max(rect.height, Self.minimumSquareSide), 1)
        cropRect = CGRect(
            x: min(max(rect.origin.x, 0), 1 - width),
            y: min(max(rect.origin.y, 0), 1 - height),
            width: width,
            height: height
        )
    }

    /// Resizes the square around its own center (pinch), bounded so it never
    /// leaves the image.
    func resizeCrop(toFraction fraction: CGFloat) {
        let width = min(max(fraction, Self.minimumSquareSide), 1)
        let height = min(max(fraction, Self.minimumSquareSide), 1)
        let center = CGPoint(x: cropRect.midX, y: cropRect.midY)
        moveCrop(to: CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        ))
    }

    /// Bottom bound of the square: a sliver would upload a blur.
    private static let minimumSquareSide: CGFloat = 0.25

    /// Puts the square back where `choose` left it. The reset button of the
    /// crop block; it only means something while a photo is pending.
    func resetCrop() {
        guard let pendingImage else { return }
        cropRect = Self.centeredSquare(for: pendingImage.size)
    }

    /// Throws the crop away without publishing anything — the published photo
    /// stays exactly as it was.
    func cancelCrop() {
        pendingImage = nil
        cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    // MARK: - Writing

    /// Crops the pending photo to its square, renders it at `outputSide` and
    /// uploads it (`POST /api/users/profile-image`).
    ///
    /// A failure leaves the previously published photo in place — on screen
    /// (the profile is only replaced on a successful answer) and on the server,
    /// which never saw a complete request — and says so.
    func save() async {
        guard let pendingImage, phase == .idle else { return }
        phase = .saving
        defer { phase = .idle }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("immich-profile-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            guard let jpeg = Self.squareJPEG(from: pendingImage, cropRect: cropRect) else {
                errorMessage = String(localized: "That photo could not be prepared.")
                return
            }
            try jpeg.write(to: fileURL, options: .atomic)
            let response = try await client.uploadProfileImage(
                fileURL: fileURL,
                filename: Self.uploadFilename,
                contentType: "image/jpeg"
            )
            if profile == nil {
                // The identity request failed earlier, so there is no row to
                // patch. The photo IS on the server: read the row back, and if
                // that also fails let the next load reconcile it.
                profile = try? await client.getMyUser()
            }
            profile = Self.applying(response, to: profile)
            self.pendingImage = nil
            cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    /// `DELETE /api/users/profile-image`. The `204` carries no body, so the
    /// local row is patched rather than refetched: an empty path is what flips
    /// the avatar back to initials everywhere.
    func deletePhoto() async {
        guard phase == .idle else { return }
        phase = .deleting
        defer { phase = .idle }
        do {
            try await client.deleteProfileImage()
            profile?.profileImagePath = ""
            errorMessage = nil
        } catch {
            errorMessage = error.userFacingMessage
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Rendering

    /// The square `cropRect` describes, at `outputSide` pixels, as JPEG data.
    private static func squareJPEG(from image: UIImage, cropRect: CGRect) -> Data? {
        guard let source = CIImage(image: image) else { return nil }

        // The aspect ratio is what the square IS; the rect is where it sits.
        var state = EditState(aspectRatio: .square)
        state.cropRect = cropRect
        let cropped = EditPipeline.applyEditState(to: source, state: state)

        let extent = cropped.extent
        guard extent.width >= 1, extent.height >= 1,
              let square = CIContext().createCGImage(cropped, from: extent) else { return nil }

        let side = outputSide
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { context in
            // JPEG has no alpha channel; without this an image with
            // transparency would composite onto black.
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            UIImage(cgImage: square).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return rendered.jpegData(compressionQuality: 0.9)
    }

    /// Redraws the image upright so its `size`, the crop square and the pixels
    /// the pipeline sees all agree. Nothing in the pipeline reads the EXIF
    /// orientation, so this is the one place that has to.
    private static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// The published photo's path and timestamp, grafted onto the identity
    /// already held — the rest of the row (name, email, quota…) did not move,
    /// and `UserAdminResponseDto` carries fields this screen never loads.
    private static func applying(
        _ response: CreateProfileImageResponseDto,
        to profile: UserAdminResponseDto?
    ) -> UserAdminResponseDto? {
        guard var profile else { return nil }
        profile.profileImagePath = response.profileImagePath
        profile.profileChangedAt = response.profileChangedAt
        return profile
    }
}
