import Foundation

/// Pure presentation helpers for the full-screen memory "moment" view.
/// No SwiftUI state — unit-testable (mirrors `MemoryCardPresentation`).
enum MemoryMomentPresentation {

    /// "July 1, 2022" — the memory's full date (day + year) from its UTC
    /// `memoryAt` timestamp, locale-correct ("1 juillet 2022" fr). Nil when
    /// `memoryAt` can't be parsed. `AppDateFormat` renders it, so the label
    /// follows the app's current language rather than the launch language.
    static func fullDateLabel(for memory: MemoryResponseDto, locale: Locale = .current) -> String? {
        guard let date = MemoryCardPresentation.parseMemoryAt(memory.memoryAt) else { return nil }
        return AppDateFormat.string(
            from: date, style: .yearMonthDay, locale: locale, calendar: utcCalendar
        )
    }

    /// Distinct people appearing in the memory's assets (deduped by id,
    /// first-seen order).
    static func people(for memory: MemoryResponseDto) -> [PersonResponseDto] {
        var seen = Set<String>()
        var result: [PersonResponseDto] = []
        for asset in memory.assets {
            for person in asset.people ?? [] {
                if seen.insert(person.id).inserted {
                    result.append(person)
                }
            }
        }
        return result
    }

    /// "Alice, Bob" from the people present; "1 person" / "N people" when the
    /// faces are unnamed; nil when nobody is tagged.
    static func peopleLabel(for memory: MemoryResponseDto, bundle: Bundle = .main, locale: Locale = .current) -> String? {
        let people = people(for: memory)
        guard !people.isEmpty else { return nil }
        let names = people.map(\.name).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if names.isEmpty {
            return String(localized: "\(people.count) people", bundle: bundle, locale: locale)
        }
        return names.joined(separator: ", ")
    }

    /// Distinct tags attached to the memory's assets (deduped by id).
    static func tags(for memory: MemoryResponseDto) -> [TagResponseDto] {
        var seen = Set<String>()
        var result: [TagResponseDto] = []
        for asset in memory.assets {
            for tag in asset.tags ?? [] {
                if seen.insert(tag.id).inserted {
                    result.append(tag)
                }
            }
        }
        return result
    }

    /// "travel, family" — comma-joined tag names; nil when untagged.
    static func tagsLabel(for memory: MemoryResponseDto) -> String? {
        let names = tags(for: memory).map(\.name).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Gregorian calendar pinned to UTC: memory days are UTC anchors, so they
    /// must never be re-read through the device's time zone.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
