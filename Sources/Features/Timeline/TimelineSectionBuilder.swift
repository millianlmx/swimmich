import Foundation

/// How the timeline cuts its asset list (settings-parity, gap G22). Upstream's
/// `.timelineGroupAssetsBy`; `.none` is this app's "flat" — one uninterrupted
/// run, no header at all.
enum TimelineGroupBy: String, CaseIterable, Identifiable {
    case day, month, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return String(localized: "Day")
        case .month: return String(localized: "Month")
        case .none: return String(localized: "Flat")
        }
    }
}

/// Builds an interleaved array of month-header + day-group sections from the
/// view model's `groupedByDay` output.
///
/// Extracted as a pure function so it can be unit-tested independently of
/// SwiftUI (no `View` dependency). The timeline grid renders month banners
/// only when the month changes between consecutive day groups — never two
/// banners in a row, never an orphan for the first group.
///
/// Input contract: `groupedByDay` is already sorted day-descending with
/// intra-day items time-descending (as produced by
/// `TimelineViewModel.groupedByDay`).
enum TimelineSectionBuilder {

    // MARK: Cached parser (hoisted from build() — audit P2)

    /// Stateless UTC parser for the `"YYYY-MM-DD"` → UTC-noon parse step.
    /// Reused across every `build` call (was per-call).
    private static let utcParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        parser.timeZone = TimeZone(identifier: "UTC")
        return parser
    }()

    /// One renderable section in the timeline vertical stack.
    enum Section: Identifiable, Equatable {
        /// Full-width month-year banner (e.g. "July 2024").
        /// - `month`: ISO year-month key `"YYYY-MM"` used for identity/dedup.
        /// - `display`: localized display string (e.g. "July 2024").
        case monthHeader(month: String, display: String)
        /// A day's worth of assets, grouped under a day header.
        case dayGroup(day: String, items: [AssetReactItem])
        /// A whole month's assets, with no day boundary inside it (`.month`
        /// grouping). `month` is the ISO year-month key, used for identity.
        case monthGroup(month: String, items: [AssetReactItem])
        /// The whole timeline in one ungrouped run (`.none` grouping): no
        /// banner, no day break — the same grid, fed in one piece.
        case flat(items: [AssetReactItem])

        var id: String {
            switch self {
            case .monthHeader(let month, _):  return "month-\(month)"
            case .dayGroup(let day, _):       return "day-\(day)"
            case .monthGroup(let month, _):   return "monthGroup-\(month)"
            case .flat:                       return "flat"
            }
        }
    }

    /// Cuts the day-descending groups according to `groupBy`: one banner +
    /// day group per day (`.day`, the default and today's behavior), one banner
    /// + month group per month (`.month`), or a single flat run (`.none`).
    ///
    /// One builder, three shapes: the grid rendering downstream is the same, so
    /// a grouping change never duplicates a view.
    ///
    /// - Parameters:
    ///   - groupedByDay: day-descending groups (from
    ///     `TimelineViewModel.groupedByDay`).
    ///   - groupBy: how to cut them. Defaults to `.day` — the caller that does
    ///     not care gets exactly the output this function has always produced.
    /// - Returns: Ordered sections ready for `ForEach` in the timeline
    ///   `LazyVStack`. Empty input → empty output.
    static func build(
        from groupedByDay: [(day: String, items: [AssetReactItem])],
        groupBy: TimelineGroupBy = .day
    ) -> [Section] {
        guard !groupedByDay.isEmpty else { return [] }

        switch groupBy {
        case .day:
            return daySections(from: groupedByDay)
        case .month:
            return monthSections(from: groupedByDay)
        case .none:
            return [.flat(items: groupedByDay.flatMap(\.items))]
        }
    }

    /// Interleaves `.monthHeader` cases between `.dayGroup` cases whenever the
    /// ISO year-month prefix (`"YYYY-MM"`) changes.
    private static func daySections(
        from groupedByDay: [(day: String, items: [AssetReactItem])]
    ) -> [Section] {
        var result: [Section] = []
        result.reserveCapacity(groupedByDay.count + 4) // rough: +1 banner per month

        var lastMonth: String?

        for group in groupedByDay {
            let monthKey = Self.monthKey(for: group.day)
            if monthKey != lastMonth {
                let display = Self.displayString(forMonthKey: monthKey)
                result.append(.monthHeader(month: monthKey, display: display))
                lastMonth = monthKey
            }
            result.append(.dayGroup(day: group.day, items: group.items))
        }
        return result
    }

    /// One `.monthHeader` + one `.monthGroup` per calendar month, in the same
    /// descending order the day groups arrive in.
    private static func monthSections(
        from groupedByDay: [(day: String, items: [AssetReactItem])]
    ) -> [Section] {
        var result: [Section] = []
        result.reserveCapacity(groupedByDay.count)

        var currentMonth: String?
        var bucket: [AssetReactItem] = []

        for group in groupedByDay {
            let monthKey = Self.monthKey(for: group.day)
            if monthKey != currentMonth {
                if let currentMonth {
                    result.append(.monthGroup(month: currentMonth, items: bucket))
                }
                result.append(.monthHeader(month: monthKey, display: Self.displayString(forMonthKey: monthKey)))
                currentMonth = monthKey
                bucket = []
            }
            bucket.append(contentsOf: group.items)
        }
        if let currentMonth {
            result.append(.monthGroup(month: currentMonth, items: bucket))
        }
        return result
    }

    /// ISO year-month key (`"YYYY-MM"`) of a `"YYYY-MM-DD"` day. Defensive: a
    /// prefix shorter than 7 chars can't yield one, so the raw day is used and
    /// the group keeps a stable identity instead of losing its banner.
    private static func monthKey(for day: String) -> String {
        day.count >= 7 ? String(day.prefix(7)) : day
    }

    /// Formats an ISO `"YYYY-MM"` key as a localized `"MMMM yyyy"` display
    /// string in the app's current language (`AppDateFormat` owns the cached
    /// formatter, so a language change is picked up on the next render).
    /// Falls back to the raw key if parsing fails — never crashes the grid over
    /// malformed input.
    private static func displayString(forMonthKey monthKey: String) -> String {
        // Parse as UTC noon (mid-month would also work; noon avoids DST edges).
        guard let date = utcParser.date(from: "\(monthKey)-15T12:00:00Z") else {
            return monthKey
        }
        return AppDateFormat.string(from: date, style: .monthYear)
    }
}
