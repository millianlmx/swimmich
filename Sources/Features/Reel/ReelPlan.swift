import CoreGraphics
import Foundation

/// How long the reel runs: how many photos it cuts through.
enum ReelLength: String, CaseIterable, Identifiable, Sendable {
    case short
    case medium
    case long

    var id: String { rawValue }

    var photoCount: Int {
        switch self {
        case .short: 16
        case .medium: 24
        case .long: 40
        }
    }

    var title: String {
        switch self {
        case .short: String(localized: "Short")
        case .medium: String(localized: "Medium")
        case .long: String(localized: "Long")
        }
    }
}

/// The reel — pure functions of the scored photos and the clock, so the
/// player and the export cut on the same frame: a title card, then one photo
/// per beat with a slow push-in around its subject, the last one held under
/// the credit.
enum ReelPlan {

    /// 120 beats a minute: a cut every half second, the pace of the reels
    /// people post.
    static let beat = 0.5
    static let titleDuration = 2.0
    static let endHold = 1.5
    /// The push-in over a photo's beat: its crop narrows by this share.
    static let zoom = 0.08
    /// Photos looked at, at most (a search's best matches first).
    static let sampleSize = 120
    /// Under this many photos there is no reel.
    static let minPhotos = 6

    enum Segment: Equatable {
        case title
        case photo(Int)
    }

    static func duration(photoCount: Int) -> Double {
        guard photoCount > 0 else { return 0 }
        return titleDuration + Double(photoCount) * beat + endHold
    }

    /// What is on screen at `time`, and how far into it (`0...1`).
    static func segment(at time: Double, photoCount: Int) -> (segment: Segment, progress: Double) {
        let t = max(time, 0)
        guard photoCount > 0, t >= titleDuration else { return (.title, min(t / titleDuration, 1)) }
        let index = Int((t - titleDuration) / beat)
        if index >= photoCount - 1 {
            let start = titleDuration + Double(photoCount - 1) * beat
            return (.photo(photoCount - 1), min((t - start) / (beat + endHold), 1))
        }
        return (.photo(index), (t - titleDuration - Double(index) * beat) / beat)
    }

    /// `count` photos among `candidates` (in the order they matched — the
    /// best match first): the `required` ones (added by hand), then the best
    /// of the others — each weighed by how well it matched and how good it
    /// is, never one `excluded` (removed by hand), never two of the same
    /// moment — all in the order they were taken.
    static func pick(
        _ candidates: [DumpCandidate],
        count: Int,
        required: Set<String> = [],
        excluded: Set<String> = [],
        isDuplicate: (DumpCandidate, DumpCandidate) -> Bool
    ) -> [DumpCandidate] {
        var picks = candidates.filter { required.contains($0.id) }
        for candidate in weighed(candidates) where picks.count < count {
            guard !excluded.contains(candidate.id), !required.contains(candidate.id) else { continue }
            if !picks.contains(where: { isDuplicate($0, candidate) }) { picks.append(candidate) }
        }
        return PhotoDumpPicker.chronologicalOrder(picks)
    }

    /// `candidates` from the most to the least worth showing: 60 % how good
    /// the photo is, 40 % how well it matched (its place in the list).
    static func weighed(_ candidates: [DumpCandidate]) -> [DumpCandidate] {
        let n = Double(max(candidates.count, 1))
        return candidates.enumerated()
            .map { rank, candidate in (candidate, candidate.score * 0.6 + (1 - Double(rank) / n) * 0.4) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// "Lisbon, Portugal", the city alone when the country repeats it
    /// (Singapore), the country alone without a city; nil without either.
    static func placeLabel(city: String?, country: String?) -> String? {
        let city = city?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let country = country?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        switch (city, country) {
        case let (city?, country?): return city == country ? city : "\(city), \(country)"
        case let (city?, nil): return city
        case let (nil, country?): return country
        case (nil, nil): return nil
        }
    }

    /// "2019 – 2025", or the one year, from the photos' local days.
    static func yearRange(_ years: [Int]) -> String? {
        guard let first = years.min(), let last = years.max() else { return nil }
        return first == last ? String(first) : "\(first) – \(last)"
    }

    /// The part of the photo on screen `progress` into its time: the crop of
    /// the film's shape around its subject, narrowing by `zoom` toward the
    /// subject.
    static func visibleRect(imageSize: CGSize, canvas: CGSize, focus: CGPoint, progress: Double) -> CGRect {
        let crop = PhotoDumpPicker.cropRect(imageSize: imageSize, ratio: canvas.width / canvas.height, focus: focus)
        let scale = 1 - zoom * min(max(progress, 0), 1)
        let width = crop.width * scale
        let height = crop.height * scale
        let target = CGPoint(x: focus.x * imageSize.width, y: focus.y * imageSize.height)
        let x = min(max(target.x - width / 2, crop.minX), crop.maxX - width)
        let y = min(max(target.y - height / 2, crop.minY), crop.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Where to draw an image of `imageSize` so its `visible` part fills `canvas`.
    static func drawRect(imageSize: CGSize, visible: CGRect, canvas: CGSize) -> CGRect {
        let scale = canvas.width / max(visible.width, 1)
        return CGRect(
            x: -visible.minX * scale, y: -visible.minY * scale,
            width: imageSize.width * scale, height: imageSize.height * scale
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
