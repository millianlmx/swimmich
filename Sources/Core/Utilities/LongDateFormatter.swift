import Foundation

/// Long-form localized date rendering for a single photo's `fileCreatedAt`
/// (e.g. `"July 29, 2024"`).
///
/// Shared by `PhotoInfoPanel.dateLabel` and `PhotoViewer.headerDate(for:)`,
/// which were byte-for-byte identical before this helper existed (audit P2).
/// Rendering goes through `AppDateFormat`, which caches the formatter per
/// locale — a `static let` here would keep the launch language forever, so a
/// language changed in `AppLanguageStore` would not reach these labels.
enum LongDateFormatter {

    /// Stateless UTC parser for the `"YYYY-MM-DD"` → UTC-noon parse step.
    private static let utcParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        parser.timeZone = TimeZone(identifier: "UTC")
        return parser
    }()

    /// Immich timestamps carry milliseconds (`"2024-07-29T14:30:00.000Z"`), which
    /// the plain `.withInternetDateTime` parser REJECTS — it needs the fractional
    /// option. Both parsers are needed because neither accepts both shapes.
    private static let fractionalParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    private static let plainParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser
    }()

    /// Parses the first 10 characters (`"YYYY-MM-DD"`) as UTC noon; nil when they
    /// are not a date. Noon keeps the calendar day stable in every time zone.
    static func date(isoPrefix: String) -> Date? {
        utcParser.date(from: "\(isoPrefix.prefix(10))T12:00:00Z")
    }

    /// Formats an ISO-8601 `"YYYY-MM-DD..."` prefix as a `.long` localized
    /// date (e.g. "July 29, 2024"), no time, in the app's current language —
    /// `AppDateFormat` owns the formatter. Falls back to the 10-char prefix if
    /// parsing fails — never crashes the view over malformed input.
    static func format(isoPrefix: String) -> String {
        guard let parsed = date(isoPrefix: isoPrefix) else {
            return String(isoPrefix.prefix(10))
        }
        return AppDateFormat.string(from: parsed, style: .longDate)
    }

    /// Parses a full ISO timestamp to a Date; nil when malformed. Handles both
    /// the server's millisecond form (`"2024-07-29T14:30:00.000Z"`) and a plain
    /// one (`"2024-07-29T14:30:00Z"`).
    ///
    /// Needed for relative-time rendering (activity feed) and for the shared-link
    /// expiry picker — where a nil used to be indistinguishable from "never
    /// expires", so editing any other field of a link that HAD an expiry silently
    /// cleared it.
    static func parse(isoTimestamp: String) -> Date? {
        fractionalParser.date(from: isoTimestamp) ?? plainParser.date(from: isoTimestamp)
    }
}
