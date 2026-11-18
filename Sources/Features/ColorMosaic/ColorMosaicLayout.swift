import Foundation

/// The average color of a photo, read from its thumbhash
/// (`ThumbHashDecoder.averageColor`), with the hue / saturation / brightness the
/// rainbow sorts on.
struct MosaicColor: Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(thumbhash: String?) {
        guard let thumbhash, !thumbhash.isEmpty,
              let rgb = ThumbHashDecoder.averageColor(thumbhash: thumbhash) else { return nil }
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var brightness: Double { max(red, green, blue) }

    var saturation: Double {
        let maximum = brightness
        guard maximum > 0 else { return 0 }
        return (maximum - min(red, green, blue)) / maximum
    }

    /// Hue in `0..<1` (0 = red); 0 for a gray.
    var hue: Double {
        let maximum = brightness
        let delta = maximum - min(red, green, blue)
        guard delta > 0 else { return 0 }
        var h: Double
        if maximum == red {
            h = (green - blue) / delta
        } else if maximum == green {
            h = (blue - red) / delta + 2
        } else {
            h = (red - green) / delta + 4
        }
        h /= 6
        return h < 0 ? h + 1 : h
    }

    /// Too dull or too dark for its hue to read: it goes with the grays, at
    /// the end of the rainbow.
    var isNeutral: Bool { saturation < 0.15 || brightness < 0.15 }
}

/// A photo of the mosaic and its color.
struct MosaicTile: Identifiable, Equatable, Sendable {
    let asset: AssetReactItem
    let color: MosaicColor
    var id: String { asset.id }
}

/// The picture the mosaic is exported as — the sizes Instagram, TikTok and
/// Messages show without cropping.
enum MosaicFormat: String, CaseIterable, Identifiable, Sendable {
    case story
    case post
    case square

    var id: String { rawValue }

    var pixelSize: CGSize {
        switch self {
        case .story: CGSize(width: 1080, height: 1920)
        case .post: CGSize(width: 1080, height: 1350)
        case .square: CGSize(width: 1080, height: 1080)
        }
    }

    var title: String {
        switch self {
        case .story: String(localized: "Story")
        case .post: String(localized: "Post")
        case .square: String(localized: "Square")
        }
    }
}

/// How the photos are laid out.
enum MosaicArrangement: String, CaseIterable, Identifiable, Sendable {
    /// Sorted by hue, flowing diagonally from the top-left corner, grays last.
    case rainbow
    /// In the order they were taken, row by row: the album's colors over time.
    case timeline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rainbow: String(localized: "Rainbow")
        case .timeline: String(localized: "Timeline")
        }
    }
}

/// The placed mosaic: `columns × rows` cells, `cells[i]` the tile in the cell
/// at row `i / columns`, column `i % columns`.
struct MosaicLayout: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let cells: [MosaicTile]
}

/// Builds the mosaic — a pure function of the tiles, the format and the
/// arrangement, so the preview and the export place every photo the same way.
enum MosaicLayoutBuilder {

    /// Fewest and most columns. Twelve columns on 1080 pixels is a 90-pixel
    /// photo, still recognizable in a story; three is the least that reads as
    /// a mosaic.
    static let minColumns = 3
    static let maxColumns = 12

    /// Rows that keep the cells about square for `columns` in `format`.
    static func rows(columns: Int, format: MosaicFormat) -> Int {
        let size = format.pixelSize
        return max(1, Int((Double(columns) * size.height / size.width).rounded()))
    }

    /// The densest grid `count` photos fill entirely, nil when they cannot
    /// fill the smallest one.
    static func grid(count: Int, format: MosaicFormat) -> (columns: Int, rows: Int)? {
        for columns in stride(from: maxColumns, through: minColumns, by: -1) {
            let rows = rows(columns: columns, format: format)
            if columns * rows <= count { return (columns, rows) }
        }
        return nil
    }

    /// Photos needed for the smallest grid of `format`.
    static func minimumCount(format: MosaicFormat) -> Int {
        minColumns * rows(columns: minColumns, format: format)
    }

    static func build(tiles: [MosaicTile], format: MosaicFormat, arrangement: MosaicArrangement) -> MosaicLayout? {
        guard let (columns, rows) = grid(count: tiles.count, format: format) else { return nil }
        let ordered = switch arrangement {
        case .rainbow: rainbowOrder(tiles)
        case .timeline: tiles.sorted { $0.asset.fileCreatedAt < $1.asset.fileCreatedAt }
        }
        // An even spread of the ordered photos: every hue (every month) of
        // the album keeps its share of the grid.
        let kept = spread(ordered, keeping: columns * rows)
        let cells: [MosaicTile] = switch arrangement {
        case .rainbow: diagonalPlacement(kept, columns: columns, rows: rows)
        case .timeline: kept
        }
        return MosaicLayout(columns: columns, rows: rows, cells: cells)
    }

    /// The colors by hue, then the neutrals from light to dark. The hue circle
    /// is cut at its widest empty gap, so the rainbow has no seam where red
    /// would wrap back to red.
    static func rainbowOrder(_ tiles: [MosaicTile]) -> [MosaicTile] {
        let chromatic = tiles.filter { !$0.color.isNeutral }.sorted { $0.color.hue < $1.color.hue }
        let neutrals = tiles.filter(\.color.isNeutral).sorted { $0.color.brightness > $1.color.brightness }
        guard chromatic.count > 1 else { return chromatic + neutrals }
        var cut = 0
        var widest = chromatic[0].color.hue + 1 - chromatic[chromatic.count - 1].color.hue
        for i in 1..<chromatic.count {
            let gap = chromatic[i].color.hue - chromatic[i - 1].color.hue
            if gap > widest {
                widest = gap
                cut = i
            }
        }
        return Array(chromatic[cut...] + chromatic[..<cut]) + neutrals
    }

    /// `count` items spread evenly over `items`, in their order.
    static func spread<T>(_ items: [T], keeping count: Int) -> [T] {
        guard count < items.count else { return items }
        guard count > 1 else { return Array(items.prefix(count)) }
        return (0..<count).map { items[Int((Double($0) * Double(items.count - 1) / Double(count - 1)).rounded())] }
    }

    /// Lays `ordered` along the grid's diagonals, top-left to bottom-right:
    /// the colors run as bands across the picture instead of row by row.
    static func diagonalPlacement(_ ordered: [MosaicTile], columns: Int, rows: Int) -> [MosaicTile] {
        let cellOrder = (0..<(columns * rows)).sorted { a, b in
            let ka = diagonalKey(a, columns: columns, rows: rows)
            let kb = diagonalKey(b, columns: columns, rows: rows)
            return ka == kb ? a < b : ka < kb
        }
        var cells = ordered
        for (rank, cell) in cellOrder.enumerated() where rank < ordered.count && cell < cells.count {
            cells[cell] = ordered[rank]
        }
        return cells
    }

    /// The position along the diagonal, normalized so a tall grid's bands
    /// cross it at the same angle as a square one's.
    private static func diagonalKey(_ cell: Int, columns: Int, rows: Int) -> Double {
        Double(cell % columns) / Double(columns) + Double(cell / columns) / Double(rows)
    }
}
