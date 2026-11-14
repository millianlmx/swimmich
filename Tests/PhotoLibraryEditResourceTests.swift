import Photos
import XCTest
@testable import ImmichSwiftUI

/// Which Photos resource is the edited version of an asset, and under what
/// name it goes to the server — a pure function, tested without a library.
final class PhotoLibraryEditResourceTests: XCTestCase {

    private typealias Resource = (type: PHAssetResourceType, originalFilename: String)

    private func choice(
        kind: BackupAssetKind = .image, live: Bool = false, _ resources: [Resource], name: String
    ) -> PhotoLibraryServiceImpl.EditedResourceChoice? {
        PhotoLibraryServiceImpl.editedResourceChoice(
            kind: kind, isLivePhoto: live, resources: resources, candidateFileName: name
        )
    }

    func test_AC_203_resourceChoice_photoTakesFullSizePhotoAndOriginalBaseName() {
        let result = choice([
            (.photo, "IMG_0001.HEIC"), (.fullSizePhoto, "FullSizeRender.jpg"), (.adjustmentData, "Adjustments.plist"),
        ], name: "IMG_0001.HEIC")

        let expected = PhotoLibraryServiceImpl.EditedResourceChoice(
            mainIndex: 1, fileName: "IMG_0001.jpg", pairedIndex: nil, pairedFileName: nil
        )
        XCTAssertEqual(result, expected)
    }

    func test_AC_203_resourceChoice_videoTakesFullSizeVideo() {
        let result = choice(kind: .video, [
            (.video, "IMG_0002.MOV"), (.fullSizeVideo, "FullSizeRender.mov"),
        ], name: "IMG_0002.MOV")

        XCTAssertEqual(result?.mainIndex, 1)
        XCTAssertEqual(result?.fileName, "IMG_0002.mov")
    }

    func test_AC_203_resourceChoice_livePhotoAddsItsFullSizePairedVideo() {
        let result = choice(live: true, [
            (.photo, "IMG_0003.HEIC"), (.pairedVideo, "IMG_0003.MOV"),
            (.fullSizePhoto, "FullSizeRender.jpg"), (.fullSizePairedVideo, "FullSizeVideoRender.mov"),
        ], name: "IMG_0003.HEIC")

        let expected = PhotoLibraryServiceImpl.EditedResourceChoice(
            mainIndex: 2, fileName: "IMG_0003.jpg", pairedIndex: 3, pairedFileName: "IMG_0003.mov"
        )
        XCTAssertEqual(result, expected)
    }

    func test_AC_203_resourceChoice_livePhotoWithoutEditedVideoGoesAlone() {
        let result = choice(live: true, [
            (.photo, "IMG_0004.HEIC"), (.pairedVideo, "IMG_0004.MOV"), (.fullSizePhoto, "FullSizeRender.jpg"),
        ], name: "IMG_0004.HEIC")

        XCTAssertEqual(result?.mainIndex, 2)
        XCTAssertNil(result?.pairedIndex)
        XCTAssertNil(result?.pairedFileName)
    }

    func test_AC_203_resourceChoice_noEditedResourceIsNil() {
        XCTAssertNil(choice([(.photo, "IMG_0005.HEIC"), (.adjustmentData, "Adjustments.plist")], name: "IMG_0005.HEIC"))
        XCTAssertNil(choice(kind: .video, [(.video, "IMG_0006.MOV"), (.fullSizePhoto, "x.jpg")], name: "IMG_0006.MOV"),
                     "a video never takes a photo resource")
    }

    func test_AC_203_resourceChoice_aStillIgnoresAPairedVideoItIsNotLiveFor() {
        let result = choice([
            (.photo, "IMG_0007.HEIC"), (.fullSizePhoto, "FullSizeRender.jpg"), (.fullSizePairedVideo, "v.mov"),
        ], name: "IMG_0007.HEIC")

        XCTAssertNil(result?.pairedIndex)
    }

    func test_AC_203_resourceChoice_keepsTheOriginalExtensionWhenTheRenderingHasNone() {
        let result = choice([(.fullSizePhoto, "FullSizeRender")], name: "IMG_0008.HEIC")

        XCTAssertEqual(result?.fileName, "IMG_0008.HEIC")
    }
}
