import Foundation

/// A person of the year and the photos they are in.
struct WrappedPerson: Equatable, Sendable {
    let id: String
    let name: String
    let photos: Int
}

/// The cards of the story, in order. A card with nothing to say (no face
/// named, no photo with a place) is left out.
enum WrappedCard: String, CaseIterable, Identifiable, Sendable {
    case intro
    case months
    case people
    case places
    case colors
    case best
    case outro

    var id: String { rawValue }
}

/// The year in numbers — pure functions of what the server answered.
enum WrappedPlan {

    /// People shown, at most.
    static let topPeopleCount = 5
    /// Named people whose year is counted, the most photographed overall first.
    static let peopleConsidered = 20
    /// The best photos of the year.
    static let bestCount = 9
    /// Photos of the year read, at most (their colors, their days).
    static let maxAssets = 6000

    /// Photos per month of `year` (January first), from the timeline's month
    /// buckets ("2026-07-01…").
    static func monthCounts(_ buckets: [TimeBucketsResponseDto], year: Int) -> [Int] {
        var counts = Array(repeating: 0, count: 12)
        for bucket in buckets {
            let parts = bucket.timeBucket.prefix(7).split(separator: "-")
            guard parts.count == 2, Int(parts[0]) == year, let month = Int(parts[1]), (1...12).contains(month) else { continue }
            counts[month - 1] += bucket.count
        }
        return counts
    }

    /// The month with the most photos (0 = January), nil for an empty year.
    static func busiestMonth(_ counts: [Int]) -> Int? {
        guard let best = counts.max(), best > 0 else { return nil }
        return counts.firstIndex(of: best)
    }

    /// The day with the most photos, where they were taken, and how many.
    static func busiestDay(_ assets: [AssetReactItem]) -> (day: CalendarDay, photos: Int)? {
        var counts: [String: (day: CalendarDay, photos: Int)] = [:]
        for asset in assets {
            guard let date = PhotoDumpViewModel.date(asset.fileCreatedAt),
                  let day = GrowingUpPlan.localDay(of: asset, date: date) else { continue }
            let key = "\(day.year)-\(day.month)-\(day.day)"
            counts[key] = (day, (counts[key]?.photos ?? 0) + 1)
        }
        return counts.values.max {
            $0.photos != $1.photos ? $0.photos < $1.photos
                : ($0.day.year, $0.day.month, $0.day.day) > ($1.day.year, $1.day.month, $1.day.day)
        }
    }

    /// The people of the year, the most photographed first, those not in any
    /// photo of the year left out.
    static func topPeople(_ people: [WrappedPerson]) -> [WrappedPerson] {
        Array(people.filter { $0.photos > 0 }
            .sorted { $0.photos != $1.photos ? $0.photos > $1.photos : $0.name < $1.name }
            .prefix(topPeopleCount))
    }

    /// The cards there is something to show on.
    static func cards(hasPeople: Bool, hasPlaces: Bool, hasColors: Bool, hasBest: Bool) -> [WrappedCard] {
        WrappedCard.allCases.filter { card in
            switch card {
            case .people: hasPeople
            case .places: hasPlaces
            case .colors: hasColors
            case .best: hasBest
            case .intro, .months, .outro: true
            }
        }
    }

    /// The whole of `year` for the metadata search: its first instant to its last, ISO-8601.
    static func takenRange(year: Int, calendar: Calendar = .current) -> (after: String, before: String)? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return nil }
        let formatter = ISO8601DateFormatter()
        return (formatter.string(from: start), formatter.string(from: end.addingTimeInterval(-0.001)))
    }

    /// The video: each card this long, the next one fading in over the end.
    static let cardDuration = 2.6
    static let fadeDuration = 0.35

    static func videoDuration(cardCount: Int) -> Double { Double(cardCount) * cardDuration }

    /// The card on screen at `time`, and how far the next one has faded in.
    static func card(at time: Double, cardCount: Int) -> (index: Int, fade: Double) {
        guard cardCount > 0 else { return (0, 0) }
        let index = min(Int(max(time, 0) / cardDuration), cardCount - 1)
        guard index < cardCount - 1 else { return (index, 0) }
        let local = time - Double(index) * cardDuration
        let fade = (local - (cardDuration - fadeDuration)) / fadeDuration
        return (index, min(max(fade, 0), 1))
    }
}
