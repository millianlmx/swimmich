import XCTest
import UIKit
import CoreImage
@testable import ImmichSwiftUI

/// Profile picture (gap G16): reading the identity, framing the square and
/// publishing it, then removing it.
@MainActor
final class ProfilePictureViewModelTests: XCTestCase {

    private var client: MockImmichClient!
    private var vm: ProfilePictureViewModel!
    private let baseURL = URL(string: "https://immich.example.com")!

    override func setUp() {
        super.setUp()
        client = MockImmichClient()
        vm = ProfilePictureViewModel(client: client, baseURL: { [baseURL] in baseURL }, token: "token")
    }

    override func tearDown() {
        vm = nil
        client = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func profile(path: String?, changedAt: String?) -> UserAdminResponseDto {
        UserAdminResponseDto(
            id: "me", name: "Ada Lovelace", email: "ada@example.com",
            profileImagePath: path, avatarColor: "#3366FF", profileChangedAt: changedAt
        )
    }

    private func makeImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Left quarter green, center half red, right quarter blue. The centered
    /// square crop of this image is uniformly red — so the average colour of
    /// what was uploaded says *where* the crop was taken from, not just how big
    /// it was.
    private func makeBandedImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            let quarter = width / 4
            UIColor.green.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: quarter, height: height))
            UIColor.red.setFill()
            ctx.fill(CGRect(x: quarter, y: 0, width: width / 2, height: height))
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: quarter + width / 2, y: 0, width: quarter, height: height))
        }
    }

    /// Average colour of an image, via `CIAreaAverage` — no byte-order guessing.
    private func averageColor(of image: UIImage) -> CIColor? {
        guard let input = CIImage(image: image),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: input,
                  kCIInputExtentKey: CIVector(cgRect: input.extent)
              ]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return CIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255
        )
    }

    // MARK: - Loading

    func test_load_setsProfileFromGetMyUser() async {
        client.getMyUserResponse = profile(path: "upload/me/a.jpg", changedAt: "t1")

        await vm.load()

        XCTAssertEqual(vm.profile?.id, "me")
        XCTAssertEqual(vm.profile?.name, "Ada Lovelace")
        XCTAssertTrue(vm.hasPhoto)
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertNil(vm.errorMessage)
    }

    func test_load_failure_setsErrorMessage_andKeepsKnownProfile() async {
        client.getMyUserResponse = profile(path: "upload/me/a.jpg", changedAt: "t1")
        await vm.load()

        client.getMyUserError = URLError(.notConnectedToInternet)
        await vm.load()

        XCTAssertNotNil(vm.errorMessage)
        // A failed refresh must not blank the avatar the user already had.
        XCTAssertEqual(vm.profile?.profileImagePath, "upload/me/a.jpg")
        XCTAssertTrue(vm.hasPhoto)
    }

    // MARK: - Choosing and framing

    func test_choose_rejectsImageSmallerThan128() {
        vm.choose(makeImage(width: 120, height: 400))

        XCTAssertNil(vm.pendingImage)
        XCTAssertEqual(
            vm.errorMessage,
            localizedString("That photo is too small. Choose one at least 128 pixels on its shortest side.")
        )
    }

    func test_choose_rejection_keepsThePreviousPick() {
        vm.choose(makeImage(width: 300, height: 300))
        let kept = vm.pendingImage

        vm.choose(makeImage(width: 64, height: 64))

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.pendingImage === kept)
    }

    func test_choose_centersSquare_narrowerOnTheLongAxis() {
        vm.choose(makeImage(width: 400, height: 300))

        XCTAssertEqual(vm.cropRect.minX, 0.125, accuracy: 0.0001)
        XCTAssertEqual(vm.cropRect.minY, 0.0, accuracy: 0.0001)
        XCTAssertEqual(vm.cropRect.width, 0.75, accuracy: 0.0001)
        XCTAssertEqual(vm.cropRect.height, 1.0, accuracy: 0.0001)
    }

    func test_moveCrop_keepsTheSquareInsideTheImage() {
        vm.choose(makeImage(width: 400, height: 200))

        vm.moveCrop(to: CGRect(x: 0.9, y: 0.9, width: 0.5, height: 1.0))

        XCTAssertEqual(vm.cropRect.width, 0.5, accuracy: 0.0001)
        XCTAssertEqual(vm.cropRect.maxX, 1.0, accuracy: 0.0001)
        XCTAssertEqual(vm.cropRect.maxY, 1.0, accuracy: 0.0001)
    }

    // MARK: - Publishing

    func test_save_cropsToSquareAndUploads512Jpeg() async {
        await vm.load()
        vm.choose(makeBandedImage(width: 400, height: 200))

        await vm.save()

        let upload = client.lastProfileImageUpload
        XCTAssertEqual(upload?.filename, "profile.jpg")
        XCTAssertEqual(upload?.contentType, "image/jpeg")
        let data = upload?.data ?? Data()
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "must be a JPEG")

        guard let sent = UIImage(data: data) else { return XCTFail("uploaded bytes are not an image") }
        XCTAssertEqual(sent.size.width, 512)
        XCTAssertEqual(sent.size.height, 512)
        // The centered square of the banded source is the red band; a crop that
        // took the whole width, or the wrong offset, would average differently.
        let average = try? XCTUnwrap(averageColor(of: sent))
        XCTAssertGreaterThan(average?.red ?? 0, 0.9)
        XCTAssertLessThan(average?.green ?? 1, 0.1)
        XCTAssertLessThan(average?.blue ?? 1, 0.1)

        XCTAssertEqual(vm.profile?.profileImagePath, "upload/me/profile.jpg")
        XCTAssertTrue(vm.hasPhoto)
        XCTAssertNil(vm.pendingImage)
        XCTAssertNil(vm.errorMessage)
    }

    func test_save_failure_keepsThePublishedPhotoAndReportsIt() async {
        client.getMyUserResponse = profile(path: "upload/me/old.jpg", changedAt: "t1")
        await vm.load()
        vm.choose(makeImage(width: 400, height: 400))
        client.uploadProfileImageError = URLError(.timedOut)

        await vm.save()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.profile?.profileImagePath, "upload/me/old.jpg")
        XCTAssertTrue(vm.hasPhoto)
        XCTAssertEqual(vm.phase, .idle)
        // The pick survives, so a retry does not send the user back to Photos.
        XCTAssertNotNil(vm.pendingImage)
    }

    // MARK: - Removing

    func test_delete_clearsProfileImagePathAndFallsBackToInitials() async {
        client.getMyUserResponse = profile(path: "upload/me/a.jpg", changedAt: "t1")
        await vm.load()
        XCTAssertTrue(vm.hasPhoto)

        await vm.deletePhoto()

        XCTAssertEqual(client.deleteProfileImageCallCount, 1)
        XCTAssertEqual(vm.profile?.profileImagePath, "")
        XCTAssertFalse(vm.hasPhoto)
        XCTAssertNil(vm.avatarURL)
        // The initials fallback needs the rest of the identity to survive.
        XCTAssertEqual(vm.avatarUser?.name, "Ada Lovelace")
        XCTAssertEqual(vm.avatarUser?.avatarColor, "#3366FF")
    }

    func test_delete_failure_keepsThePhotoAndReportsIt() async {
        client.getMyUserResponse = profile(path: "upload/me/a.jpg", changedAt: "t1")
        await vm.load()
        client.deleteProfileImageError = URLError(.networkConnectionLost)

        await vm.deletePhoto()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.profile?.profileImagePath, "upload/me/a.jpg")
        XCTAssertTrue(vm.hasPhoto)
    }

    // MARK: - Cache busting

    func test_avatarURL_changesWithProfileChangedAt() async {
        client.getMyUserResponse = profile(path: "upload/me/a.jpg", changedAt: "t1")
        await vm.load()
        let first = vm.avatarURL

        client.getMyUserResponse = profile(path: "upload/me/b.jpg", changedAt: "t2")
        await vm.load()

        XCTAssertEqual(first?.path, "/api/users/me/profile-image")
        XCTAssertEqual(first?.query, "v=t1")
        XCTAssertEqual(vm.avatarURL?.query, "v=t2")
        XCTAssertNotEqual(first, vm.avatarURL)
    }

    /// L-26: the closure is read at every use, so a switch of address moves the
    /// avatar to the new origin, path and query kept.
    func test_AC_49_avatarFollowsActiveAddress() async {
        var current = URL(string: "https://immich.example.com")!
        let followed = ProfilePictureViewModel(client: client, baseURL: { current }, token: "token")
        client.getMyUserResponse = profile(path: "upload/me/a.jpg", changedAt: "t1")
        await followed.load()
        XCTAssertEqual(followed.avatarURL?.host, "immich.example.com")

        current = URL(string: "http://192.168.1.10:2283")!

        XCTAssertEqual(followed.avatarURL?.host, "192.168.1.10")
        XCTAssertEqual(followed.avatarURL?.port, 2283)
        XCTAssertEqual(followed.avatarURL?.path, "/api/users/me/profile-image")
        XCTAssertEqual(followed.avatarURL?.query, "v=t1")
    }

    func test_avatarURL_isNilWithoutAPhoto() async {
        client.getMyUserResponse = profile(path: "", changedAt: nil)
        await vm.load()

        XCTAssertNil(vm.avatarURL)
        XCTAssertFalse(vm.hasPhoto)
    }

    func test_clearError_removesTheMessage() {
        vm.choose(makeImage(width: 32, height: 32))
        XCTAssertNotNil(vm.errorMessage)

        vm.clearError()

        XCTAssertNil(vm.errorMessage)
    }
}
