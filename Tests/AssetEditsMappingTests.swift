import XCTest
import UIKit
import CoreGraphics
import ImageIO
@testable import ImmichSwiftUI

/// `AssetEditsMapping` (EditState ↔ the server's edit list), the edit-list wire types, and the
/// pipeline's agreement with the server's semantics.
@MainActor
final class AssetEditsMappingTests: XCTestCase {

    private typealias Support = EditorTestSupport
    private typealias Corner = EditorTestSupport.Corner

    private let exif = ExifResponseDto(exifImageWidth: 4000, exifImageHeight: 3000, orientation: "1")

    // MARK: AC-182 — reading a server list

    func test_AC_182_readsListsInOrder() {
        let table: [(list: [AssetEditItem], steps: Int, horizontal: Bool, vertical: Bool)] = [
            ([], 0, false, false),
            ([.mirror(.horizontal)], 0, true, false),
            ([.mirror(.horizontal), .rotate(angle: 180)], 2, true, false),
            ([.mirror(.vertical), .rotate(angle: 90)], 1, false, true),
            ([.rotate(angle: 90), .mirror(.horizontal)], 1, false, true),
            ([.rotate(angle: 270), .mirror(.vertical)], 1, false, true),
            ([.rotate(angle: 90), .rotate(angle: 90)], 2, false, false),
            ([.mirror(.vertical), .mirror(.vertical)], 0, false, false)
        ]
        for row in table {
            let state = AssetEditsMapping.state(from: row.list, exif: exif)
            XCTAssertEqual(state.orientationSteps, row.steps, "\(row.list)")
            XCTAssertEqual(state.mirrorHorizontal, row.horizontal, "\(row.list)")
            XCTAssertEqual(state.mirrorVertical, row.vertical, "\(row.list)")
            XCTAssertNil(state.cropRect)
            XCTAssertNil(state.aspectRatio)
            XCTAssertTrue(state.isServerExpressible)
        }
    }

    func test_AC_182_cropIsReadInTheRawBufferFrame() {
        let exifSix = ExifResponseDto(exifImageWidth: 4000, exifImageHeight: 3000, orientation: "6")
        let state = AssetEditsMapping.state(
            from: [.crop(x: 750, y: 1000, width: 1500, height: 2000), .rotate(angle: 90)], exif: exifSix)
        XCTAssertEqual(state.cropRect, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(state.orientationSteps, 1)

        // The displayed photo is the raw buffer turned clockwise: its LEFT half is the raw BOTTOM half.
        let left = AssetEditsMapping.state(from: [.crop(x: 0, y: 0, width: 1500, height: 4000)], exif: exifSix)
        XCTAssertEqual(left.cropRect, CGRect(x: 0, y: 0.5, width: 1, height: 0.5))

        let whole = AssetEditsMapping.state(from: [.crop(x: 0, y: 0, width: 3000, height: 4000)], exif: exifSix)
        XCTAssertNil(whole.cropRect, "a crop that covers the whole image is no crop")
    }

    func test_AC_182_listsInTheEditorsOwnFormRoundTrip() {
        let exifSix = ExifResponseDto(exifImageWidth: 4000, exifImageHeight: 3000, orientation: "6")
        let lists: [[AssetEditItem]] = [
            [.crop(x: 750, y: 1000, width: 1500, height: 2000), .mirror(.vertical), .rotate(angle: 90)],
            [.mirror(.horizontal), .mirror(.vertical), .rotate(angle: 270)],
            [.crop(x: 0, y: 500, width: 3000, height: 2000)],
            [.rotate(angle: 180)]
        ]
        for list in lists {
            let state = AssetEditsMapping.state(from: list, exif: exifSix)
            XCTAssertEqual(AssetEditsMapping.edits(for: state, exif: exifSix), list)
        }
    }

    func test_AC_182_orientedRectAndRawRectAreInverse() {
        let rect = CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.25)
        let all: [CGImagePropertyOrientation] = [.up, .upMirrored, .down, .downMirrored,
                                                 .leftMirrored, .right, .rightMirrored, .left]
        for o in all {
            XCTAssertEqual(AssetEditsMapping.rawRect(AssetEditsMapping.orientedRect(rect, o), o), rect, "\(o.rawValue)")
        }
    }

    func test_AC_182_orientationAndSizeFromExif() {
        func e(_ orientation: String?, _ w: Int? = 4000, _ h: Int? = 3000) -> ExifResponseDto {
            ExifResponseDto(exifImageWidth: w, exifImageHeight: h, orientation: orientation)
        }
        let table: [(String?, CGImagePropertyOrientation)] = [
            ("1", .up), ("2", .upMirrored), ("3", .down), ("4", .downMirrored), ("5", .leftMirrored),
            ("6", .right), ("7", .rightMirrored), ("8", .left), ("90", .right), ("-90", .left),
            ("180", .down), ("9", .up), (nil, .up), ("abc", .up)
        ]
        for (raw, expected) in table {
            XCTAssertEqual(AssetEditsMapping.orientation(e(raw)), expected, "\(raw ?? "nil")")
        }
        XCTAssertEqual(AssetEditsMapping.orientedSize(e("1"))?.width, 4000)
        XCTAssertEqual(AssetEditsMapping.orientedSize(e("6"))?.width, 3000)
        XCTAssertEqual(AssetEditsMapping.orientedSize(e("-90"))?.height, 4000)
        XCTAssertNil(AssetEditsMapping.orientedSize(e("1", nil, 3000)))
        XCTAssertNil(AssetEditsMapping.orientedSize(e("1", 0, 3000)))
        XCTAssertNil(AssetEditsMapping.orientedSize(nil))
    }

    // MARK: AC-181 — the list the editor writes

    func test_AC_181_oracleListForExifSix() {
        let exifSix = ExifResponseDto(exifImageWidth: 4000, exifImageHeight: 3000, orientation: "6")
        let state = EditState(cropRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                              orientationSteps: 1, mirrorVertical: true)
        XCTAssertEqual(AssetEditsMapping.edits(for: state, exif: exifSix),
                       [.crop(x: 750, y: 1000, width: 1500, height: 2000), .mirror(.vertical), .rotate(angle: 90)])
    }

    func test_AC_181_cropIsBoundedAndOmittedWhenItCoversTheImage() {
        let full = EditState(cropRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(AssetEditsMapping.edits(for: full, exif: exif), [])
        let overshoot = EditState(cropRect: CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5))
        XCTAssertEqual(AssetEditsMapping.edits(for: overshoot, exif: exif),
                       [.crop(x: 3600, y: 2700, width: 400, height: 300)])
        let sliver = EditState(cropRect: CGRect(x: 0.5, y: 0.5, width: 0, height: 0))
        XCTAssertEqual(AssetEditsMapping.edits(for: sliver, exif: exif),
                       [.crop(x: 2000, y: 1500, width: 1, height: 1)])
    }

    // MARK: AC-182 — wire format

    func test_AC_182_decodesFractionalCropFromV2() throws {
        func decode(_ json: String) throws -> AssetEditItem {
            try JSONDecoder().decode(AssetEditItem.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"action":"rotate","parameters":{"angle":90.0}}"#), .rotate(angle: 90))
        XCTAssertEqual(try decode(#"{"action":"rotate","parameters":{"angle":-90}}"#), .rotate(angle: 270))
        XCTAssertEqual(try decode(#"{"action":"rotate","parameters":{"angle":360}}"#), .rotate(angle: 0))
        XCTAssertThrowsError(try decode(#"{"action":"rotate","parameters":{"angle":45}}"#))
        XCTAssertThrowsError(try decode(#"{"action":"blur","parameters":{}}"#))
        XCTAssertEqual(
            try decode(#"{"action":"crop","parameters":{"x":750.5,"y":0,"width":1499.5,"height":3000}}"#),
            .crop(x: 750, y: 0, width: 1499, height: 3000))
        XCTAssertThrowsError(try decode(#"{"action":"crop","parameters":{"x":-1,"y":0,"width":10,"height":10}}"#))
        XCTAssertEqual(try decode(#"{"action":"mirror","parameters":{"axis":"horizontal"}}"#), .mirror(.horizontal))
    }

    func test_AC_182_responseIgnoresActionIds() throws {
        let json = #"{"assetId":"a1","edits":[{"id":"e1","action":"mirror","parameters":{"axis":"vertical"}}]}"#
        let response = try JSONDecoder().decode(AssetEditsResponseDto.self, from: Data(json.utf8))
        XCTAssertEqual(response, AssetEditsResponseDto(assetId: "a1", edits: [.mirror(.vertical)]))
    }

    func test_AC_181_encodesIntegersAndWireNames() throws {
        let body = AssetEditsCreateDto(edits: [
            .crop(x: 1, y: 2, width: 3, height: 4), .mirror(.vertical), .rotate(angle: 90)
        ])
        let data = try JSONEncoder().encode(body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected: [[String: Any]] = [
            ["action": "crop", "parameters": ["x": 1, "y": 2, "width": 3, "height": 4]],
            ["action": "mirror", "parameters": ["axis": "vertical"]],
            ["action": "rotate", "parameters": ["angle": 90]]
        ]
        XCTAssertEqual(object["edits"] as? NSArray, expected as NSArray)
        // Integers on the wire: a v3.4.0 server refuses `90.0`.
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"angle\":90}"))
    }

    func test_AC_181_supportStartsAtTwoFive() {
        func v(_ major: Int, _ minor: Int, _ patch: Int) -> ServerVersionResponseDto {
            ServerVersionResponseDto(major: major, minor: minor, patch: patch, prerelease: nil)
        }
        XCTAssertFalse(AssetEditsSupport.isSupported(nil))
        XCTAssertFalse(AssetEditsSupport.isSupported(v(2, 4, 9)))
        XCTAssertTrue(AssetEditsSupport.isSupported(v(2, 5, 0)))
        XCTAssertTrue(AssetEditsSupport.isSupported(v(3, 4, 0)))
    }

    // MARK: AC-184 — state and pipeline

    func test_AC_184_draftWithoutMirrorKeysDecodes() throws {
        let json = #"{"orientationSteps":1,"straightenDeg":0,"exposure":0,"contrast":0,"saturation":0,"warmth":0}"#
        XCTAssertEqual(try JSONDecoder().decode(EditState.self, from: Data(json.utf8)), EditState(orientationSteps: 1))

        let state = EditState(cropRect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5), orientationSteps: 3,
                              mirrorHorizontal: true, mirrorVertical: true)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(EditState.self, from: data), state)
    }

    func test_AC_184_mirrorCountsAsAnEditAndExpressibility() {
        XCTAssertTrue(EditState(mirrorHorizontal: true).hasEdits)
        XCTAssertTrue(EditState(mirrorVertical: true).hasEdits)
        XCTAssertFalse(EditState.neutral.hasEdits)
        XCTAssertTrue(EditState(cropRect: .init(x: 0, y: 0, width: 0.5, height: 0.5), orientationSteps: 2,
                                mirrorHorizontal: true).isServerExpressible)
        XCTAssertFalse(EditState(straightenDeg: 5).isServerExpressible)
        XCTAssertFalse(EditState(exposure: 0.2).isServerExpressible)
        XCTAssertFalse(EditState(warmth: -0.1).isServerExpressible)
    }

    private func flipH(_ c: Corner) -> Corner {
        switch c {
        case .topLeft: return .topRight
        case .topRight: return .topLeft
        case .bottomLeft: return .bottomRight
        case .bottomRight: return .bottomLeft
        }
    }

    private func flipV(_ c: Corner) -> Corner {
        switch c {
        case .topLeft: return .bottomLeft
        case .bottomLeft: return .topLeft
        case .topRight: return .bottomRight
        case .bottomRight: return .topRight
        }
    }

    /// `rotate` 90 is clockwise: top left → top right → bottom right → bottom left.
    private func turn(_ c: Corner) -> Corner {
        switch c {
        case .topLeft: return .topRight
        case .topRight: return .bottomRight
        case .bottomRight: return .bottomLeft
        case .bottomLeft: return .topLeft
        }
    }

    func test_AC_184_previewMatchesServerSemanticsAllOrientations() throws {
        let orientations: [UIImage.Orientation] = [.up, .down, .left, .right,
                                                   .upMirrored, .downMirrored, .leftMirrored, .rightMirrored]
        let vm = PhotoEditorViewModel(assetId: "asset-1", client: MockImmichClient(), urlSession: { .shared })
        for orientation in orientations {
            let raw = Support.rawImage(width: 400, height: 300, orientation: orientation)
            vm.originalImage = raw
            // Where the markers sit in the oriented image: what the server starts from.
            let start = Support.markerCorners(of: raw)
            let startRed = try XCTUnwrap(start.red)
            let startGreen = try XCTUnwrap(start.green)
            for steps in 0..<4 {
                for (h, v) in [(false, false), (true, false), (false, true), (true, true)] {
                    let state = EditState(orientationSteps: steps, mirrorHorizontal: h, mirrorVertical: v)
                    vm.editState = state
                    var red = startRed, green = startGreen
                    for item in AssetEditsMapping.edits(for: state, exif: exif) {
                        switch item {
                        case .mirror(.horizontal): red = flipH(red); green = flipH(green)
                        case .mirror(.vertical): red = flipV(red); green = flipV(green)
                        case .rotate(let angle):
                            for _ in 0..<(angle / 90) { red = turn(red); green = turn(green) }
                        case .crop: break
                        }
                    }
                    let preview = try XCTUnwrap(vm.previewImage)
                    let actual = Support.markerCorners(of: preview)
                    let label = "orientation \(orientation.rawValue), steps \(steps), mirror \(h)/\(v)"
                    XCTAssertEqual(actual.red, red, "red marker, \(label)")
                    XCTAssertEqual(actual.green, green, "green marker, \(label)")
                    let turned = steps % 2 == 1
                    XCTAssertEqual(preview.size.width, turned ? raw.size.height : raw.size.width, "\(label)")
                }
            }
        }
    }

    func test_AC_184_cropThenRotateInTheOrientedFrame() throws {
        // EXIF 6 raw buffer 400×300; the top half of the raw buffer is the RIGHT half once displayed.
        let vm = PhotoEditorViewModel(assetId: "asset-1", client: MockImmichClient(), urlSession: { .shared })
        vm.originalImage = Support.rawImage(width: 400, height: 300, orientation: .right)
        vm.editState = EditState(cropRect: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        let preview = try XCTUnwrap(vm.previewImage)
        XCTAssertEqual(preview.size.width, 150)
        XCTAssertEqual(preview.size.height, 400)
        // The red marker is raw top-left → displayed top-right → inside the kept (right) half.
        XCTAssertEqual(Support.markerCorners(of: preview).red, .topRight)
    }
}
