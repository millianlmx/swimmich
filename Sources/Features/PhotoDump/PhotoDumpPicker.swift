import CoreGraphics
import Foundation

/// A photo the dump can show, once looked at: its quality score
/// (`RoadTripPhotoScore`), where its subject is and its shape.
struct DumpCandidate: Identifiable, Equatable, Sendable {
    let asset: AssetReactItem
    let score: Double
    /// The center of the photo's subject, `0...1` from the top-left corner:
    /// the crop is centered on it.
    let focus: CGPoint
    /// Width / height, as displayed.
    let aspect: Double

    var id: String { asset.id }
}

/// The shape every photo of the dump is cropped to: a carousel shows all its
/// photos at the shape of the first one.
enum DumpAspect: String, CaseIterable, Identifiable, Sendable {
    case portrait
    case square
    case original

    var id: String { rawValue }

    /// Width / height; nil keeps each photo's own shape.
    var ratio: Double? {
        switch self {
        case .portrait: 4.0 / 5.0
        case .square: 1
        case .original: nil
        }
    }

    var title: String {
        switch self {
        case .portrait: "4:5"
        case .square: "1:1"
        case .original: String(localized: "Original")
        }
    }
}

/// Where each photo of the dump's grid sits, and which slot a point falls in:
/// the reorder drag moves a photo to the slot under the finger.
struct DumpGridMetrics: Equatable {
    let width: CGFloat
    let columns: Int
    /// Width / height of a cell.
    let ratio: Double
    let spacing: CGFloat

    /// Three columns, four past nine photos: twenty photos fit on the screen,
    /// so a drag never has to scroll.
    static func columns(forCount count: Int) -> Int { count > 9 ? 4 : 3 }

    var cellWidth: CGFloat { max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)) }
    var cellHeight: CGFloat { cellWidth / CGFloat(ratio) }

    func height(count: Int) -> CGFloat {
        let rows = (count + columns - 1) / columns
        return rows == 0 ? 0 : CGFloat(rows) * cellHeight + CGFloat(rows - 1) * spacing
    }

    func center(of index: Int) -> CGPoint {
        CGPoint(
            x: CGFloat(index % columns) * (cellWidth + spacing) + cellWidth / 2,
            y: CGFloat(index / columns) * (cellHeight + spacing) + cellHeight / 2
        )
    }

    /// The slot under `point`, clamped to the grid's `count` photos.
    func index(at point: CGPoint, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let column = min(max(Int(point.x / (cellWidth + spacing)), 0), columns - 1)
        let row = max(Int(point.y / (cellHeight + spacing)), 0)
        return min(row * columns + column, count - 1)
    }
}

/// Picks the dump — a pure function of the scored candidates, so the choice,
/// the swaps and the count changes are the same on every run.
///
/// `isDuplicate` says two photos show the same moment (a burst, the same shot
/// taken twice): a dump never shows both.
enum PhotoDumpPicker {

    /// Instagram's carousel holds 2 to 20 photos; a dump below 4 is not one.
    static let countRange = 4...20
    static let defaultCount = 10

    /// `count` photos: the candidates are cut into `count` stretches of time,
    /// each giving its best photo that is not a duplicate of one already
    /// picked; a stretch left without one is made up by the best photos
    /// overall. The best photo of all opens the dump (the carousel's cover),
    /// the others follow in the order they were taken.
    static func pick(
        _ candidates: [DumpCandidate],
        count: Int,
        isDuplicate: (DumpCandidate, DumpCandidate) -> Bool
    ) -> [DumpCandidate] {
        let chronological = chronologicalOrder(candidates)
        let n = min(count, chronological.count)
        guard n > 0 else { return [] }
        var picks: [DumpCandidate] = []
        for stretch in stretches(chronological.count, into: n) {
            let best = chronological[stretch]
                .filter { candidate in !picks.contains { isDuplicate($0, candidate) } }
                .max { $0.score < $1.score }
            if let best { picks.append(best) }
        }
        let byScore = chronological.sorted { $0.score > $1.score }
        for candidate in byScore where picks.count < n && !picks.contains(candidate) {
            if !picks.contains(where: { isDuplicate($0, candidate) }) { picks.append(candidate) }
        }
        // Fewer distinct moments than photos asked: duplicates rather than a short dump.
        for candidate in byScore where picks.count < n && !picks.contains(candidate) {
            picks.append(candidate)
        }
        return coverFirst(picks, chronological: chronological)
    }

    /// The photo that takes the place of `id` when it is swapped out: the best
    /// one taken between its neighbors in time, not already in the dump, not
    /// swapped out before and not a duplicate of another photo of the dump —
    /// the best such photo of the whole set when there is none between them.
    static func replacement(
        for id: String,
        in picks: [DumpCandidate],
        candidates: [DumpCandidate],
        excluded: Set<String>,
        isDuplicate: (DumpCandidate, DumpCandidate) -> Bool
    ) -> DumpCandidate? {
        let chronological = chronologicalOrder(candidates)
        let rank = Dictionary(uniqueKeysWithValues: chronological.enumerated().map { ($1.id, $0) })
        guard let replacedRank = rank[id] else { return nil }
        let others = picks.filter { $0.id != id }
        let pool = chronological.filter { candidate in
            candidate.id != id && !excluded.contains(candidate.id)
                && !picks.contains { $0.id == candidate.id }
                && !others.contains { isDuplicate($0, candidate) }
        }
        let ranks = others.compactMap { rank[$0.id] }
        let lower = ranks.filter { $0 < replacedRank }.max() ?? -1
        let upper = ranks.filter { $0 > replacedRank }.min() ?? chronological.count
        let between = pool.filter { (rank[$0.id] ?? -1) > lower && (rank[$0.id] ?? -1) < upper }
        return (between.isEmpty ? pool : between).max { $0.score < $1.score }
    }

    /// The dump at `count` photos: the best photos not yet in it are added in
    /// their place in time (the cover stays first), or the lowest scored ones
    /// leave it (never the cover).
    static func resized(
        _ picks: [DumpCandidate],
        to count: Int,
        candidates: [DumpCandidate],
        excluded: Set<String>,
        isDuplicate: (DumpCandidate, DumpCandidate) -> Bool
    ) -> [DumpCandidate] {
        var picks = picks
        while picks.count > count, picks.count > 1 {
            let rest = picks.dropFirst()
            guard let lowest = rest.min(by: { $0.score < $1.score }) else { break }
            picks.removeAll { $0.id == lowest.id }
        }
        guard picks.count < count else { return picks }
        let pool = candidates
            .filter { candidate in !excluded.contains(candidate.id) && !picks.contains { $0.id == candidate.id } }
            .sorted { $0.score > $1.score }
        for candidate in pool where picks.count < count {
            guard !picks.contains(where: { isDuplicate($0, candidate) }) else { continue }
            // After the cover, before the first photo taken later.
            let index = picks.indices.dropFirst().first { picks[$0].asset.fileCreatedAt > candidate.asset.fileCreatedAt }
            picks.insert(candidate, at: index ?? picks.endIndex)
        }
        return picks
    }

    /// The largest rectangle of `ratio` (width / height) in an image of
    /// `size`, centered on `focus` (`0...1` from the top-left) as far as the
    /// image's edges allow.
    static func cropRect(imageSize size: CGSize, ratio: Double, focus: CGPoint) -> CGRect {
        guard size.width > 0, size.height > 0, ratio > 0 else { return CGRect(origin: .zero, size: size) }
        var crop = size
        if size.width / size.height > ratio {
            crop.width = size.height * ratio
        } else {
            crop.height = size.width / ratio
        }
        let x = min(max(focus.x * size.width - crop.width / 2, 0), size.width - crop.width)
        let y = min(max(focus.y * size.height - crop.height / 2, 0), size.height - crop.height)
        return CGRect(x: x, y: y, width: crop.width, height: crop.height).integral
    }

    // MARK: - Helpers

    static func chronologicalOrder(_ candidates: [DumpCandidate]) -> [DumpCandidate] {
        candidates.sorted { $0.asset.fileCreatedAt < $1.asset.fileCreatedAt }
    }

    /// `count` contiguous ranges of `0..<total`, as equal as can be.
    static func stretches(_ total: Int, into count: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in (i * total / count)..<((i + 1) * total / count) }.filter { !$0.isEmpty }
    }

    private static func coverFirst(_ picks: [DumpCandidate], chronological: [DumpCandidate]) -> [DumpCandidate] {
        guard let cover = picks.max(by: { $0.score < $1.score }) else { return picks }
        let rest = chronological.filter { candidate in candidate.id != cover.id && picks.contains { $0.id == candidate.id } }
        return [cover] + rest
    }
}
