import XCTest
@testable import ImmichSwiftUI

final class ColorMosaicLayoutTests: XCTestCase {

    /// A thumbhash carrying only the header's DC term: `l`, `p`, `q` are the
    /// raw 6-bit indices `ThumbHashDecoder` reads.
    private func thumbhash(l: UInt32, p: UInt32, q: UInt32) -> String {
        let header24 = l | (p << 6) | (q << 12)
        let bytes: [UInt8] = [
            UInt8(header24 & 0xFF), UInt8((header24 >> 8) & 0xFF), UInt8((header24 >> 16) & 0xFF), 0x07, 0x00
        ]
        return Data(bytes).base64EncodedString()
    }

    private func makeAsset(id: String, time: String = "2024-07-01T00:00:00.000Z") -> AssetReactItem {
        AssetReactItem(
            id: id, ownerId: "owner", ratio: 1.0, isFavorite: false, visibility: "timeline",
            isTrashed: false, isImage: true, thumbhash: nil,
            createdAt: time, fileCreatedAt: time,
            localOffsetHours: 0, duration: nil, livePhotoVideoId: nil,
            projectionType: nil, city: nil, country: nil, latitude: nil, longitude: nil, stack: []
        )
    }

    private func tile(_ id: String, hue: Double, time: String = "2024-07-01T00:00:00.000Z") -> MosaicTile {
        // A saturated color at `hue`, built from the HSB wheel.
        let color = UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: nil)
        return MosaicTile(asset: makeAsset(id: id, time: time), color: MosaicColor(red: r, green: g, blue: b))
    }

    private func gray(_ id: String, _ value: Double) -> MosaicTile {
        MosaicTile(asset: makeAsset(id: id), color: MosaicColor(red: value, green: value, blue: value))
    }

    // MARK: - Average color

    func test_averageColor_readsRedFromHeader() throws {
        // Pure red: l = 1/3, p = 1/2, q = 1 → indices 21, 47, 63.
        let rgb = try XCTUnwrap(ThumbHashDecoder.averageColor(thumbhash: thumbhash(l: 21, p: 47, q: 63)))
        XCTAssertEqual(rgb.red, 1, accuracy: 0.02)
        XCTAssertEqual(rgb.green, 0, accuracy: 0.02)
        XCTAssertEqual(rgb.blue, 0, accuracy: 0.02)
    }

    func test_averageColor_invalidHash_isNil() {
        XCTAssertNil(ThumbHashDecoder.averageColor(thumbhash: ""))
        XCTAssertNil(ThumbHashDecoder.averageColor(thumbhash: "AAA="))
        XCTAssertNil(MosaicColor(thumbhash: nil))
    }

    func test_mosaicColor_hue() {
        XCTAssertEqual(MosaicColor(red: 1, green: 0, blue: 0).hue, 0, accuracy: 0.001)
        XCTAssertEqual(MosaicColor(red: 0, green: 1, blue: 0).hue, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(MosaicColor(red: 0, green: 0, blue: 1).hue, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertTrue(MosaicColor(red: 0.5, green: 0.5, blue: 0.5).isNeutral)
        XCTAssertTrue(MosaicColor(red: 0.1, green: 0, blue: 0).isNeutral)
    }

    // MARK: - Grid

    func test_grid_picksDensestFullGrid() {
        // Story: 12 columns need 12 × 21 = 252 photos.
        XCTAssertEqual(MosaicLayoutBuilder.grid(count: 252, format: .story)?.columns, 12)
        XCTAssertEqual(MosaicLayoutBuilder.grid(count: 251, format: .story)?.columns, 11)
        XCTAssertEqual(MosaicLayoutBuilder.grid(count: 5000, format: .story)?.columns, 12)
        // Square: 3 × 3 is the smallest.
        XCTAssertEqual(MosaicLayoutBuilder.grid(count: 9, format: .square)?.rows, 3)
        XCTAssertNil(MosaicLayoutBuilder.grid(count: 8, format: .square))
        XCTAssertEqual(MosaicLayoutBuilder.minimumCount(format: .square), 9)
    }

    func test_build_fillsEveryCellOnce() throws {
        let tiles = (0..<100).map { tile("t\($0)", hue: Double($0) / 100) }
        let layout = try XCTUnwrap(MosaicLayoutBuilder.build(tiles: tiles, format: .post, arrangement: .rainbow))
        XCTAssertEqual(layout.cells.count, layout.columns * layout.rows)
        XCTAssertEqual(Set(layout.cells.map(\.id)).count, layout.cells.count)
    }

    // MARK: - Rainbow

    func test_rainbowOrder_cutsAtWidestHueGap_neutralsLast() {
        // Hues cluster around red (0.95 … 0.05): the widest gap is in the
        // middle of the wheel, so the order starts at 0.95, wraps through red.
        let tiles = [tile("a", hue: 0.05), tile("b", hue: 0.95), tile("c", hue: 0.0), gray("dark", 0.2), gray("light", 0.9)]
        let order = MosaicLayoutBuilder.rainbowOrder(tiles).map(\.id)
        XCTAssertEqual(order, ["b", "c", "a", "light", "dark"])
    }

    func test_diagonalPlacement_firstColorTopLeft_lastBottomRight() throws {
        let tiles = (0..<9).map { tile("t\($0)", hue: Double($0) / 12) }
        let layout = try XCTUnwrap(MosaicLayoutBuilder.build(tiles: tiles, format: .square, arrangement: .rainbow))
        XCTAssertEqual(layout.cells.first?.id, "t0")
        XCTAssertEqual(layout.cells.last?.id, "t8")
    }

    // MARK: - Timeline

    func test_timeline_isChronologicalRowByRow() throws {
        let times = (0..<9).map { String(format: "2024-%02d-01T00:00:00.000Z", $0 + 1) }
        let tiles = times.enumerated().reversed().map { tile("m\($0.offset)", hue: 0.5, time: $0.element) }
        let layout = try XCTUnwrap(MosaicLayoutBuilder.build(tiles: tiles, format: .square, arrangement: .timeline))
        XCTAssertEqual(layout.cells.map(\.id), (0..<9).map { "m\($0)" })
    }

    func test_spread_keepsEnds() {
        XCTAssertEqual(MosaicLayoutBuilder.spread(Array(0..<10), keeping: 4), [0, 3, 6, 9])
        XCTAssertEqual(MosaicLayoutBuilder.spread([1, 2], keeping: 5), [1, 2])
    }

    // MARK: - Renderer

    func test_render_producesFormatSize() throws {
        let tiles = (0..<9).map { tile("t\($0)", hue: Double($0) / 9) }
        let layout = try XCTUnwrap(MosaicLayoutBuilder.build(tiles: tiles, format: .square, arrangement: .rainbow))
        let image = MosaicRenderer.render(layout: layout, format: .square, images: [:], showsCredit: true)
        XCTAssertEqual(image.size, CGSize(width: 1080, height: 1080))
    }
}
