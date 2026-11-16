import Foundation

/// The single cache of display-date formatters.
///
/// Two problems drive this: `DateFormatter` allocation is expensive (the
/// activity feed used to build a `RelativeDateTimeFormatter` per list row),
/// and a formatter captured in a `static let` freezes the language it was
/// created with — after an in-app language change (see `AppLanguageStore`)
/// dates would keep rendering in the language the app launched in. Every
/// display-date site goes through here, keyed by locale and calendar, so a
/// new language simply misses the cache and allocates the right formatter.
enum AppDateFormat {

    /// The display configurations actually in use. Each case reproduces the
    /// exact configuration its call site used before the cache existed.
    enum Style: Hashable {
        /// `dateStyle = .long`, `timeStyle = .none` — "July 29, 2024".
        case longDate
        /// Literal `"MMMM yyyy"` — timeline month banners ("July 2024").
        case monthYear
        /// `setLocalizedDateFormatFromTemplate("MMMMd")` — "July 1" / "1 juillet".
        case monthDay
        /// `setLocalizedDateFormatFromTemplate("yMMMMd")` — "July 1, 2023".
        case yearMonthDay
        /// Literal `"EEEE, MMMM d"` / `"EEEE, MMMM d, yyyy"` — timeline day headers.
        case dayHeader(includeYear: Bool)
        /// Literal `"EEEE d MMMM"` — "Wednesday 29 July".
        case dayMonth
        /// Literal `"yyyy"` — a bare year label.
        case year
    }

    /// Cache identity of a `DateFormatter`: a style is only reusable for the
    /// exact locale, time zone and week-start rule it was built with, since
    /// all four change the rendered string.
    private struct Key: Hashable {
        let style: Style
        let localeIdentifier: String
        let timeZoneIdentifier: String
        let firstWeekday: Int
    }

    private struct RelativeKey: Hashable {
        let localeIdentifier: String
        let timeZoneIdentifier: String
        let firstWeekday: Int
    }

    /// The key space is tiny in practice (a handful of styles × the languages
    /// the user ever switches to), so the cap is only a guard against unbounded
    /// growth; dropping the whole cache on overflow is cheaper than tracking
    /// recency for entries this cheap to rebuild.
    private static let maxCachedFormatters = 64

    /// Guards both caches. Call sites are main-thread today, but a shared
    /// mutable dictionary is exactly the kind of state that breaks silently if
    /// that ever stops being true.
    private static let lock = NSLock()
    private static var formatters: [Key: DateFormatter] = [:]
    private static var relativeFormatters: [RelativeKey: RelativeDateTimeFormatter] = [:]

    /// Returns a cached formatter for `style`, configured with `locale`,
    /// `calendar` and `calendar.timeZone`. The instance is shared — read it,
    /// never mutate it.
    static func formatter(_ style: Style, locale: Locale, calendar: Calendar) -> DateFormatter {
        let key = Key(
            style: style,
            localeIdentifier: locale.identifier,
            timeZoneIdentifier: calendar.timeZone.identifier,
            firstWeekday: calendar.firstWeekday
        )
        lock.lock()
        defer { lock.unlock() }
        if let cached = formatters[key] { return cached }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch style {
        case .longDate:
            formatter.dateStyle = .long
            formatter.timeStyle = .none
        case .monthYear:
            formatter.dateFormat = "MMMM yyyy"
        case .monthDay:
            formatter.setLocalizedDateFormatFromTemplate("MMMMd")
        case .yearMonthDay:
            formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        case .dayHeader(let includeYear):
            formatter.dateFormat = includeYear ? "EEEE, MMMM d, yyyy" : "EEEE, MMMM d"
        case .dayMonth:
            formatter.dateFormat = "EEEE d MMMM"
        case .year:
            formatter.dateFormat = "yyyy"
        }

        if formatters.count >= maxCachedFormatters { formatters.removeAll(keepingCapacity: true) }
        formatters[key] = formatter
        return formatter
    }

    /// Renders `date` in `style`, spoken in `locale` and interpreted in
    /// `calendar` (its time zone included).
    ///
    /// Defaults are the *autoupdating* current values, so a language or
    /// time-zone change is honored on the next render rather than frozen at
    /// first use.
    static func string(
        from date: Date,
        style: Style,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        let text = formatter(style, locale: locale, calendar: calendar).string(from: date)
        // ICU renders day and month names with the locale's own casing, which
        // is lowercase in French, Italian and Spanish ("mercredi 29 juillet",
        // "juin 2024"). The pinned header and the scrubber bubble START with
        // these labels, so they are sentence-cased: the first letter only,
        // never each word — "Mercredi 29 juillet", not "Mercredi 29 Juillet",
        // and the same rule for both so the two dates never disagree in form.
        switch style {
        case .dayMonth, .monthYear: return sentenceCased(text)
        default: return text
        }
    }

    /// A `.short` relative phrase for `date` counted from `reference`
    /// (e.g. "2 h ago" for the activity feed). One cached formatter serves
    /// every row instead of one allocation per row.
    static func relativeString(
        for date: Date,
        relativeTo reference: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .current
    ) -> String {
        let key = RelativeKey(
            localeIdentifier: locale.identifier,
            timeZoneIdentifier: calendar.timeZone.identifier,
            firstWeekday: calendar.firstWeekday
        )
        lock.lock()
        if let cached = relativeFormatters[key] {
            lock.unlock()
            return cached.localizedString(for: date, relativeTo: reference)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        if relativeFormatters.count >= maxCachedFormatters {
            relativeFormatters.removeAll(keepingCapacity: true)
        }
        relativeFormatters[key] = formatter
        lock.unlock()
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    /// Uppercases the first character of `text` and leaves the rest as the
    /// locale wrote it (`.dayMonth` and `.monthYear`).
    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
