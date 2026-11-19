import CoreLocation
import Foundation

/// A geotagged photo and the year it was taken: a map marker asked for one
/// year at a time (the markers carry no date, their filter does).
struct DatedMarker: Equatable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let year: Int
    let city: String?
    let country: String?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// A place photographed years apart: its earliest year's photos and its
/// latest year's.
struct ThenNowSpot: Identifiable, Equatable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let thenYear: Int
    let nowYear: Int
    let thenIDs: [String]
    let nowIDs: [String]
    let photoCount: Int
    let place: String?

    var yearGap: Int { nowYear - thenYear }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Finds the places photographed years apart — pure functions of the dated
/// markers.
enum ThenAndNowPlan {

    /// Photos within this of each other stand on the same spot (~40 m).
    static let cellDegrees = 0.0004
    /// Two photos of a spot at least this many years apart make a then and now.
    static let minYearGap = 2
    /// Spots closer than this to a better one are left out: one street is
    /// one spot.
    static let spotSpacingMeters = 250.0
    static let maxSpots = 40
    /// Years asked for, at most, from this one back.
    static let earliestYear = 1990

    /// The markers' filter for the whole of `year`, local time.
    static func filter(year: Int, calendar: Calendar = .current) -> MapMarkerFilter {
        var filter = MapMarkerFilter()
        filter.from = calendar.date(from: DateComponents(year: year, month: 1, day: 1))
        filter.to = calendar.date(from: DateComponents(year: year, month: 12, day: 31))
        return filter
    }

    private struct Cell: Hashable {
        let row: Int
        let column: Int
    }

    /// The spots, the widest gap of years first (then the most photographed):
    /// markers grouped by ~40 m squares — each square with its eight
    /// neighbors, so two photos a meter apart on either side of a line are
    /// one spot — kept when they span `minYearGap` years or more, never two
    /// within `spotSpacingMeters`.
    static func spots(_ markers: [DatedMarker]) -> [ThenNowSpot] {
        var cells: [Cell: [DatedMarker]] = [:]
        for marker in markers {
            let lonCell = cellDegrees / max(cos(marker.latitude * .pi / 180), 0.1)
            let cell = Cell(
                row: Int((marker.latitude / cellDegrees).rounded(.down)),
                column: Int((marker.longitude / lonCell).rounded(.down))
            )
            cells[cell, default: []].append(marker)
        }
        var candidates: [ThenNowSpot] = []
        for cell in cells.keys {
            var group: [DatedMarker] = []
            for dr in -1...1 {
                for dc in -1...1 {
                    group += cells[Cell(row: cell.row + dr, column: cell.column + dc)] ?? []
                }
            }
            let key = "\(cell.row)|\(cell.column)"
            guard let first = group.map(\.year).min(), let last = group.map(\.year).max(),
                  last - first >= minYearGap else { continue }
            let latitude = group.map(\.latitude).reduce(0, +) / Double(group.count)
            let longitude = group.map(\.longitude).reduce(0, +) / Double(group.count)
            let named = group.first { $0.city != nil || $0.country != nil }
            candidates.append(ThenNowSpot(
                id: key, latitude: latitude, longitude: longitude,
                thenYear: first, nowYear: last,
                thenIDs: group.filter { $0.year == first }.map(\.id).sorted(),
                nowIDs: group.filter { $0.year == last }.map(\.id).sorted(),
                photoCount: group.count,
                place: ReelPlan.placeLabel(city: named?.city, country: named?.country)
            ))
        }
        candidates.sort {
            $0.yearGap != $1.yearGap ? $0.yearGap > $1.yearGap
                : $0.photoCount != $1.photoCount ? $0.photoCount > $1.photoCount : $0.id < $1.id
        }
        var spots: [ThenNowSpot] = []
        for candidate in candidates where spots.count < maxSpots {
            let crowded = spots.contains {
                MapPosterStats.distance($0.coordinate, candidate.coordinate) < spotSpacingMeters
            }
            if !crowded { spots.append(candidate) }
        }
        return spots
    }

    /// Every then-and-now pair, the most alike first (`distance`, smaller is
    /// closer — the same viewpoint; unknown last), ties in the lists' order.
    static func rankedPairs(
        then thenIDs: [String],
        now nowIDs: [String],
        distance: (String, String) -> Double?
    ) -> [(then: String, now: String)] {
        var all: [(then: String, now: String, distance: Double, order: Int)] = []
        for a in thenIDs {
            for b in nowIDs {
                all.append((a, b, distance(a, b) ?? .greatestFiniteMagnitude, all.count))
            }
        }
        return all.sorted { $0.distance != $1.distance ? $0.distance < $1.distance : $0.order < $1.order }
            .map { ($0.then, $0.now) }
    }

    /// The wipe of the video at `time`: the share of the frame, from the
    /// left, the now photo covers (eased).
    static let videoHold = 1.2
    static let videoWipe = 2.0
    static let videoEnd = 1.8
    static var videoDuration: Double { videoHold + videoWipe + videoEnd }

    static func wipe(at time: Double) -> Double {
        let t = min(max((time - videoHold) / videoWipe, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
