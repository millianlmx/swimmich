import Foundation

/// State behind the adjust-date sheet (L-33, B-38): the wall-clock date the user
/// picks, the time zone it is read in, the sorted and filterable zone list and
/// the `dateTimeOriginal` string that goes to the server.
///
/// The date is a *wall clock*: the instant whose **UTC** components are the date
/// and time on screen. The picker shows it under a UTC environment, and changing
/// the zone never moves it (the official client treats date and zone as two
/// independent states). Only the offset appended on save follows the zone.
@Observable
@MainActor
final class AdjustDateViewModel: Identifiable {

    /// One row of the zone list: the identifier and its offset at the current wall clock.
    struct TimeZoneEntry: Identifiable, Equatable {
        let identifier: String
        let offsetMinutes: Int
        var id: String { identifier }
        var offsetText: String { AdjustDateViewModel.offsetText(minutes: offsetMinutes) }
    }

    let id = UUID()
    let detail: AssetDetailViewModel

    /// Date and time as shown in the sheet (UTC components). Bound to the picker.
    var wallClock: Date
    private(set) var selectedZoneIdentifier: String
    /// Written by the zone list's search field.
    var filterText: String = ""
    private(set) var isSaving = false

    // MARK: - Zone catalogue (built once)

    private struct Zone {
        let identifier: String
        let timeZone: TimeZone
        /// Identifier reduced for matching (`Self.reduce`).
        let reduced: String
    }

    private let zones: [Zone]
    private let zonesByIdentifier: [String: TimeZone]
    @ObservationIgnored private var cachedWallClock: Date?
    @ObservationIgnored private var cachedSorted: [TimeZoneEntry] = []

    init(
        detail: AssetDetailViewModel,
        deviceTimeZone: TimeZone,
        knownIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers,
        now: Date = Date()
    ) {
        self.detail = detail

        var seen = Set<String>()
        var built: [Zone] = []
        for identifier in knownIdentifiers + ["UTC", deviceTimeZone.identifier] {
            guard seen.insert(identifier).inserted, let tz = TimeZone(identifier: identifier) else { continue }
            built.append(Zone(identifier: identifier, timeZone: tz, reduced: Self.reduce(identifier)))
        }
        zones = built
        let lookup = Dictionary(uniqueKeysWithValues: built.map { ($0.identifier, $0.timeZone) })
        zonesByIdentifier = lookup

        // 1. Memory of a correction saved on this photo.
        if let saved = detail.savedDateCorrection, lookup[saved.timeZoneIdentifier] != nil {
            selectedZoneIdentifier = saved.timeZoneIdentifier
            wallClock = saved.wallClock
            return
        }

        // 2. Instant of the photo.
        let exif = detail.detail?.exifInfo
        let instant = exif?.dateTimeOriginal.flatMap(LongDateFormatter.parse(isoTimestamp:))
            ?? detail.detail.flatMap { LongDateFormatter.parse(isoTimestamp: $0.fileCreatedAt) }
            ?? LongDateFormatter.parse(isoTimestamp: detail.asset.fileCreatedAt)
            ?? now

        // 3. Zone: EXIF name, else a named zone with the EXIF fixed offset, else the device's.
        let exifZone = exif?.timeZone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chosen: String
        if !exifZone.isEmpty, lookup[exifZone] != nil {
            chosen = exifZone
        } else if let minutes = Self.fixedOffsetMinutes(exifTimeZone: exifZone) {
            let matching = built.filter { $0.timeZone.secondsFromGMT(for: instant) / 60 == minutes }
            if matching.contains(where: { $0.identifier == deviceTimeZone.identifier }) {
                chosen = deviceTimeZone.identifier
            } else {
                chosen = matching.map(\.identifier).min() ?? deviceTimeZone.identifier
            }
        } else {
            chosen = deviceTimeZone.identifier
        }
        selectedZoneIdentifier = chosen

        // 4. Wall clock: the photo's instant read in the chosen zone.
        let zone = lookup[chosen] ?? deviceTimeZone
        wallClock = instant.addingTimeInterval(TimeInterval(zone.secondsFromGMT(for: instant)))
    }

    // MARK: - Derived values

    /// The chosen zone with its offset at the current wall clock — the same
    /// computation as the list rows and the sent string.
    var selectedEntry: TimeZoneEntry {
        let zone = zonesByIdentifier[selectedZoneIdentifier] ?? .gmt
        return TimeZoneEntry(
            identifier: selectedZoneIdentifier,
            offsetMinutes: Self.offsetMinutes(of: zone, atWallClock: wallClock)
        )
    }

    /// Zones sorted by offset then name, narrowed by `filterText`.
    var zoneEntries: [TimeZoneEntry] {
        let sorted = sortedEntries
        let query = Self.reduce(filterText)
        guard !query.isEmpty else { return sorted }
        let matching = Set(zones.filter { $0.reduced.contains(query) }.map(\.identifier))
        return sorted.filter { matching.contains($0.identifier) }
    }

    /// What `save()` would send now.
    var dateTimeOriginal: String {
        Self.dateTimeOriginal(wallClock: wallClock, offsetMinutes: selectedEntry.offsetMinutes)
    }

    /// Offsets and order only change with the wall clock: typing a filter reuses this.
    private var sortedEntries: [TimeZoneEntry] {
        let wall = wallClock
        if cachedWallClock == wall { return cachedSorted }
        let entries = zones.map {
            TimeZoneEntry(
                identifier: $0.identifier,
                offsetMinutes: Self.offsetMinutes(of: $0.timeZone, atWallClock: wall)
            )
        }.sorted {
            $0.offsetMinutes != $1.offsetMinutes ? $0.offsetMinutes < $1.offsetMinutes : $0.identifier < $1.identifier
        }
        cachedWallClock = wall
        cachedSorted = entries
        return entries
    }

    // MARK: - Actions

    /// Picks a zone from the list. The date and time on screen stay as they are.
    func selectZone(_ identifier: String) {
        guard zonesByIdentifier[identifier] != nil else { return }
        selectedZoneIdentifier = identifier
        filterText = ""
    }

    /// Sends the correction. Returns whether it persisted; a failure leaves the
    /// message on `detail.errorMessage` for the sheet.
    func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        detail.errorMessage = nil
        await detail.setDateTime(
            DateCorrection(
                dateTimeOriginal: dateTimeOriginal,
                timeZoneIdentifier: selectedZoneIdentifier,
                wallClock: wallClock
            )
        )
        isSaving = false
        return detail.errorMessage == nil
    }

    // MARK: - Pure helpers

    /// `+09:00`, `-03:30`, `+00:00`.
    nonisolated static func offsetText(minutes: Int) -> String {
        let magnitude = abs(minutes)
        return (minutes >= 0 ? "+" : "-") + String(format: "%02d:%02d", magnitude / 60, magnitude % 60)
    }

    /// Offset in force in `zone` when its local clock reads `wall` (read as UTC
    /// components). A repeated hour takes the first occurrence (offset before the
    /// change); a skipped hour takes the offset after the change.
    nonisolated static func offsetMinutes(of zone: TimeZone, atWallClock wall: Date) -> Int {
        let before = zone.secondsFromGMT(for: wall.addingTimeInterval(-86_400))
        let after = zone.secondsFromGMT(for: wall.addingTimeInterval(86_400))
        let seconds = zone.secondsFromGMT(for: wall.addingTimeInterval(-TimeInterval(before))) == before ? before : after
        return seconds / 60
    }

    /// `UTC+2` → 120, `UTC-3:30` → -210, `UTC+05:45` → 345; nil for anything else
    /// (`UTC`, `GMT+2`, `+02:00`, hours above 14, minutes above 59).
    nonisolated static func fixedOffsetMinutes(exifTimeZone: String) -> Int? {
        guard exifTimeZone.hasPrefix("UTC") else { return nil }
        let rest = exifTimeZone.dropFirst(3)
        guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
        let parts = rest.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), (1...2).contains(parts[0].count) else { return nil }
        if parts.count == 2, parts[1].count != 2 { return nil }
        guard parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hours = Int(parts[0]), hours <= 14 else { return nil }
        let minutes = parts.count == 2 ? Int(parts[1]) ?? 99 : 0
        guard minutes <= 59 else { return nil }
        return (sign == "-" ? -1 : 1) * (hours * 60 + minutes)
    }

    /// `yyyy-MM-dd'T'HH:mm:ss` from the wall clock's UTC components, then the
    /// offset. Never a fraction, never `Z`.
    nonisolated static func dateTimeOriginal(wallClock: Date, offsetMinutes: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: wallClock)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        ) + offsetText(minutes: offsetMinutes)
    }

    /// Case, accent and `_` insensitive form used to match a query against an identifier.
    nonisolated private static func reduce(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
