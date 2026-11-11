import Foundation

/// Pure, type-aware titles for memories (card, full-screen moment, badge).
/// No SwiftUI state — unit-testable.
///
/// A memory's `data.year` means different things per type: the year of an
/// `on_this_day` memory, the *birth year* of a `birthday` one. No `.birthday`
/// path here ever shows that year or derives a "N years ago" from it — the
/// birthday's age comes from the displayed photo's year, like the official
/// client (`memory_title.widget.dart@v3.4.0`).
enum MemoryTitlePresentation {

    /// "Alice's birthday · 30 years old". Name nil / blank → "Unknown". Age =
    /// `ageYear - birthYear`; nil `ageYear` or an age below 1 → name only.
    /// `bundle` picks the catalog language (tests pin one `.lproj`).
    static func birthdayTitle(personName: String?, ageYear: Int?, birthYear: Int, bundle: Bundle = .main) -> String {
        let name = (personName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return String(localized: "Unknown", bundle: bundle) }
        let title = String(localized: "\(name)'s birthday", bundle: bundle)
        guard let ageYear, ageYear - birthYear >= 1 else { return title }
        let age = ageYear - birthYear
        return "\(title) · \(String(localized: "\(age) years old", bundle: bundle))"
    }

    /// The year an asset was taken, read off the wall-clock prefix (no time
    /// zone), `localDateTime` first, then `fileCreatedAt`.
    static func takenYear(of asset: AssetResponseDto) -> Int? {
        Int(asset.localDateTime.prefix(4)) ?? Int(asset.fileCreatedAt.prefix(4))
    }

    /// Main line of the list card. Never empty.
    static func cardTitle(for memory: MemoryResponseDto, bundle: Bundle = .main) -> String? {
        switch memory.type {
        case .on_this_day:
            return MemoryMomentPresentation.fullDateLabel(for: memory)
        case .birthday:
            return birthdayTitle(
                personName: memory.data.personName, ageYear: nil, birthYear: memory.data.year, bundle: bundle
            )
        case .unknown:
            return MemoryMomentPresentation.fullDateLabel(for: memory) ?? String(memory.data.year)
        }
    }

    /// Second line of the list card.
    static func cardSubtitle(for memory: MemoryResponseDto) -> String? {
        switch memory.type {
        case .on_this_day: return yearsAgoText(for: memory)
        case .birthday: return MemoryMomentPresentation.fullDateLabel(for: memory)
        case .unknown: return nil
        }
    }

    /// Big title of the full-screen moment; `asset` is the photo on screen.
    static func momentTitle(for memory: MemoryResponseDto, asset: AssetResponseDto?, bundle: Bundle = .main) -> String {
        switch memory.type {
        case .on_this_day:
            return String(memory.data.year)
        case .birthday:
            return birthdayTitle(
                personName: memory.data.personName,
                ageYear: asset.flatMap(takenYear),
                birthYear: memory.data.year,
                bundle: bundle
            )
        case .unknown:
            return MemoryMomentPresentation.fullDateLabel(for: memory) ?? String(memory.data.year)
        }
    }

    /// Line under the moment title: "1 juillet · il y a 3 ans" for on-this-day,
    /// the day alone for a birthday, nothing for an unknown type.
    static func momentSubtitle(for memory: MemoryResponseDto) -> String? {
        switch memory.type {
        case .on_this_day:
            let parts = [MemoryCardPresentation.dayLabel(for: memory), yearsAgoText(for: memory)].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .birthday:
            return MemoryCardPresentation.dayLabel(for: memory)
        case .unknown:
            return nil
        }
    }

    /// Top-bar / card badge.
    static func badge(for memory: MemoryResponseDto, bundle: Bundle = .main) -> (label: String, symbol: String) {
        switch memory.type {
        case .on_this_day: return (String(localized: "On this day", bundle: bundle), "sparkles")
        case .birthday: return (String(localized: "Birthday", bundle: bundle), "birthday.cake")
        case .unknown: return (String(localized: "Memory", bundle: bundle), "sparkles")
        }
    }

    private static func yearsAgoText(for memory: MemoryResponseDto) -> String? {
        guard let count = MemoryCardPresentation.yearsAgoCount(year: memory.data.year) else { return nil }
        return MemoryCardPresentation.yearsAgoText(count: count)
    }
}
