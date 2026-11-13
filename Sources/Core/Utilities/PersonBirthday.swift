import Foundation

/// Wire-format helpers for a person's birthday (gap G15).
///
/// The server carries the field as a **date-only** `"YYYY-MM-DD"` string
/// (`PersonUpdateDto.birthDate`, OpenAPI `format: date`, `nullable: true`), and
/// none of the repo's date formats can read it: `ISO8601DateFormatter` rejects
/// `"1990-05-12"` outright, and routing the value through `JSONCoding`'s
/// `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` would shift the day by one in any time zone
/// west of UTC. `date(from:)` and `wire(from:)` are therefore an identity over
/// `Calendar.current`, with no time component anywhere.
///
/// This is the only risky logic of the feature, so it lives here rather than in
/// the view: a one-day drift is invisible until it is wrong.
enum PersonBirthday {

    /// Parses the wire's `"YYYY-MM-DD"` into a `Date` at the start of that day.
    ///
    /// `nil` for `nil`, for any other shape (`"12/05/1990"`, a full timestamp,
    /// an unpadded month), and for a day that does not exist (`"1990-02-30"`) —
    /// the components are read back from the parsed date, so a calendar that
    /// normalizes an out-of-range day instead of refusing it cannot slip one
    /// through.
    static func date(from wire: String?) -> Date? {
        guard let wire else { return nil }
        let parts = wire.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }

        let roundTrip = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return date
    }

    /// Renders `date` as the wire's `"YYYY-MM-DD"`, in the user's calendar —
    /// the exact inverse of `date(from:)`.
    static func wire(from date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Localized label for the detail header (e.g. "May 12, 1990" / "12 mai
    /// 1990"), `nil` when there is nothing to show.
    ///
    /// `AppDateFormat` renders it — the repo's single cached formatter — so the
    /// label follows the app's language (an inline `DateFormatter` or a
    /// `static let` here would freeze the launch language), and the caller's
    /// `if let` draws no line at all for a person without a birthday.
    static func display(_ wire: String?) -> String? {
        guard let date = date(from: wire) else { return nil }
        return AppDateFormat.string(from: date, style: .yearMonthDay)
    }
}

/// A day on the Gregorian calendar, with no time and no time zone: the unit
/// both a birthday and a photo's reference day are compared in.
struct CalendarDay: Equatable {
    let year: Int
    let month: Int
    let day: Int
}

extension PersonBirthday {

    /// Parses the wire's `"YYYY-MM-DD"` into a `CalendarDay`, under the same
    /// acceptance rules as `date(from:)` but checked on a fixed UTC Gregorian
    /// calendar, so neither the device's time zone nor its calendar can move
    /// the day. `nil` for `nil` and for any other shape or a day that does not
    /// exist.
    static func day(from wire: String?) -> CalendarDay? {
        guard let wire else { return nil }
        let parts = wire.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return CalendarDay(year: year, month: month, day: day)
    }
}

/// A person's age on a given day, in the official client's three forms
/// (`formatAge`, `people.utils.dart@v3.4.0`): months for a baby, "1 year and N
/// months" up to two years, whole years after.
enum PersonAge: Equatable {
    case months(Int)
    case oneYearAnd(months: Int)
    case years(Int)

    /// The age on `reference`. `nil` when `birth` is after `reference`.
    /// The formula is the official client's, line for line: 12 months falls in
    /// the years branch ("1 year") and the birth day itself is "0 months".
    static func at(birth b: CalendarDay, on r: CalendarDay) -> PersonAge? {
        var years = r.year - b.year
        if r.month < b.month || (r.month == b.month && r.day < b.day) { years -= 1 }
        let months = (r.year - b.year) * 12 + r.month - b.month - (r.day < b.day ? 1 : 0)
        if years < 0 { return nil }
        if months <= 11 { return .months(months) }
        if (13...23).contains(months) { return .oneYearAnd(months: months - 12) }
        return .years(years)
    }

    /// Localized label, every form read from the catalog (plural-aware).
    func label(bundle: Bundle = .main, locale: Locale = .current) -> String {
        switch self {
        case .months(let n):
            return String(localized: "\(n) months old", bundle: bundle, locale: locale)
        case .oneYearAnd(let n):
            return String(localized: "1 year and \(n) months old", bundle: bundle, locale: locale)
        case .years(let n):
            return String(localized: "\(n) years old", bundle: bundle, locale: locale)
        }
    }
}
