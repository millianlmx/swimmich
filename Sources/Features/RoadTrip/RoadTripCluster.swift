import Foundation
import CoreLocation

/// A chronological group of photos — the road-trip unit. Each cluster becomes
/// one slideshow leg; travel legs connect consecutive clusters on the map.
struct RoadTripCluster: Identifiable, Equatable, Sendable {
    /// Stable id derived from member asset ids (deterministic across the live
    /// player and the export renderer, which must agree on every segment).
    let id: String
    let assets: [AssetReactItem]
    /// Where the stop sits: the geolocated member nearest the members' mean
    /// (a real photo spot — a mean can fall in a field or the sea); nil when
    /// none are located. Once the routes are known, `RoadTripAnchoring` moves
    /// it onto the road the car arrives by.
    let latitude: Double?
    let longitude: Double?
    /// "Paris, France" from EXIF (first asset carrying city/country).
    let placeName: String?
    /// Earliest / latest capture timestamps (chronological ordering keys).
    let startDate: Date?
    let endDate: Date?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Pure, unit-testable location+time clustering. No SwiftUI / MapKit state.
enum RoadTripClusterer {

    /// Greedy clustering:
    /// - Assets sorted by capture time.
    /// - Each geolocated asset joins the nearest existing cluster within
    ///   `radiusMeters` (distance to the cluster's anchor = first member),
    ///   otherwise opens a new cluster.
    /// - Unlocated assets attach to the temporally nearest cluster within
    ///   `timeGapThreshold`, else collect into a trailing "no location" cluster.
    /// - A lat/lon grid index keeps the nearest-anchor scan bounded, so a
    ///   10k-photo album clusters in one cheap pass (no O(n·k) full sweep).
    /// - A consecutive-merge pass then fuses clusters of the same place
    ///   (same EXIF place name, or anchors within `mergeRadiusMeters`) when the
    ///   time gap is small, so one town shot from several viewpoints never
    ///   becomes "Bunyola → Bunyola" legs or duplicated credits.
    static func cluster(
        _ assets: [AssetReactItem],
        radiusMeters: Double = 2500,
        timeGapThreshold: TimeInterval = 4 * 3600,
        mergeRadiusMeters: Double = 4000,
        maxMergeTimeGap: TimeInterval = 12 * 3600
    ) -> [RoadTripCluster] {
        guard !assets.isEmpty else { return [] }

        let sorted = assets.sorted {
            (parse($0.fileCreatedAt) ?? .distantFuture) < (parse($1.fileCreatedAt) ?? .distantFuture)
        }

        var members: [[AssetReactItem]] = []
        var anchors: [CLLocationCoordinate2D] = []   // parallel to located clusters only
        var grid: [GridKey: [Int]] = [:]             // cell -> located cluster indices (anchor-based)

        let latCell = radiusMeters / 110_000.0       // degrees of latitude per cell

        for asset in sorted {
            guard let lat = asset.latitude, let lon = asset.longitude else {
                // Unlocated: attach by time to the nearest cluster, else keep
                // for the trailing bucket.
                attachByTime(asset, members: &members, threshold: timeGapThreshold)
                continue
            }
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let key = GridKey(
                lat: Int((lat / latCell).rounded(.down)),
                lon: Int((lon / lonCellDegrees(lat, latCell)).rounded(.down))
            )
            var best: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for dLat in -1...1 {
                for dLon in -1...1 {
                    guard let indices = grid[GridKey(lat: key.lat + dLat, lon: key.lon + dLon)] else { continue }
                    for index in indices {
                        let d = haversine(coord, anchors[index])
                        if d < bestDistance { bestDistance = d; best = index }
                    }
                }
            }
            if let best, bestDistance <= radiusMeters {
                members[best].append(asset)
            } else {
                let newIndex = members.count
                members.append([asset])
                anchors.append(coord)
                grid[key, default: []].append(newIndex)
            }
        }

        return mergeConsecutive(
            members.map(makeCluster).sorted {
                ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture)
            },
            mergeRadiusMeters: mergeRadiusMeters,
            maxMergeTimeGap: maxMergeTimeGap
        )
    }

    // MARK: - Consecutive merge (same-place fusion)

    /// Fuses consecutive clusters that belong to the same stop: same place
    /// name, or anchors within `mergeRadiusMeters` — provided the time gap
    /// stays under `maxMergeTimeGap` (a return to the same city days later is
    /// a NEW stop in the story, not the same one). Only consecutive clusters
    /// merge, so the road-trip narrative (A → B → A) survives.
    private static func mergeConsecutive(
        _ clusters: [RoadTripCluster],
        mergeRadiusMeters: Double,
        maxMergeTimeGap: TimeInterval
    ) -> [RoadTripCluster] {
        guard clusters.count >= 2 else { return clusters }
        var result: [RoadTripCluster] = []
        for cluster in clusters {
            if let last = result.last,
               shouldMerge(last, cluster, radius: mergeRadiusMeters, timeGap: maxMergeTimeGap) {
                result[result.count - 1] = merged(last, cluster)
            } else {
                result.append(cluster)
            }
        }
        return result
    }

    private static func shouldMerge(
        _ a: RoadTripCluster,
        _ b: RoadTripCluster,
        radius: Double,
        timeGap: TimeInterval
    ) -> Bool {
        let samePlace: Bool
        if let pa = normalizedPlace(a.placeName), let pb = normalizedPlace(b.placeName) {
            samePlace = pa == pb
        } else {
            samePlace = false
        }
        let nearby: Bool
        if let ca = a.coordinate, let cb = b.coordinate {
            nearby = haversine(ca, cb) <= radius
        } else {
            nearby = false
        }
        guard samePlace || nearby else { return false }
        if let aEnd = a.endDate, let bStart = b.startDate {
            return max(0, bStart.timeIntervalSince(aEnd)) <= timeGap
        }
        // Dates unknown — merge freely (time cannot veto the merge).
        return true
    }

    private static func normalizedPlace(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    /// Merges `a` then `b` into one cluster (both are internally chronological,
    /// so concatenation keeps the order). Id stays deterministic — derived from
    /// the sorted member ids, so live and export agree.
    private static func merged(_ a: RoadTripCluster, _ b: RoadTripCluster) -> RoadTripCluster {
        let assets = a.assets + b.assets
        let center = medoid(of: assets)
        return RoadTripCluster(
            id: assets.map(\.id).sorted().joined(separator: "|"),
            assets: assets,
            latitude: center?.latitude,
            longitude: center?.longitude,
            placeName: a.placeName ?? b.placeName,
            startDate: min(a.startDate ?? .distantFuture, b.startDate ?? .distantFuture),
            endDate: max(a.endDate ?? .distantPast, b.endDate ?? .distantPast)
        )
    }

    // MARK: - Internals

    /// The located member nearest the located members' mean (ties: the first).
    static func medoid(of assets: [AssetReactItem]) -> CLLocationCoordinate2D? {
        let located = assets.compactMap { asset -> CLLocationCoordinate2D? in
            guard let lat = asset.latitude, let lon = asset.longitude else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        guard !located.isEmpty else { return nil }
        let mean = CLLocationCoordinate2D(
            latitude: located.map(\.latitude).reduce(0, +) / Double(located.count),
            longitude: located.map(\.longitude).reduce(0, +) / Double(located.count)
        )
        var best = located[0]
        var bestDistance = haversine(best, mean)
        for coordinate in located.dropFirst() {
            let d = haversine(coordinate, mean)
            if d < bestDistance { bestDistance = d; best = coordinate }
        }
        return best
    }

    private static func attachByTime(
        _ asset: AssetReactItem,
        members: inout [[AssetReactItem]],
        threshold: TimeInterval
    ) {
        let t = parse(asset.fileCreatedAt)
        var best: Int?
        var bestGap = threshold
        for (index, cluster) in members.enumerated() {
            guard let range = timeRange(cluster) else { continue }
            guard let t else { continue }
            let gap: TimeInterval
            if t < range.start {
                gap = range.start.timeIntervalSince(t)
            } else if t > range.end {
                gap = t.timeIntervalSince(range.end)
            } else {
                gap = 0
            }
            if gap < bestGap { bestGap = gap; best = index }
        }
        if let best {
            members[best].append(asset)
        } else {
            members.append([asset])
        }
    }

    private static func makeCluster(_ assets: [AssetReactItem]) -> RoadTripCluster {
        let id = assets.map(\.id).sorted().joined(separator: "|")
        let center = medoid(of: assets)
        let dates = assets.compactMap { parse($0.fileCreatedAt) }
        return RoadTripCluster(
            id: id,
            assets: assets,
            latitude: center?.latitude,
            longitude: center?.longitude,
            placeName: placeName(of: assets),
            startDate: dates.min(),
            endDate: dates.max()
        )
    }

    private static func placeName(of assets: [AssetReactItem]) -> String? {
        for asset in assets {
            let city = trimmed(asset.city)
            let country = trimmed(asset.country)
            switch (city, country) {
            case let (c?, co?): return "\(c), \(co)"
            case let (c?, nil): return c
            case let (nil, co?): return co
            case (nil, nil): continue
            }
        }
        return nil
    }

    private static func timeRange(_ assets: [AssetReactItem]) -> (start: Date, end: Date)? {
        let dates = assets.compactMap { parse($0.fileCreatedAt) }
        guard let min = dates.min(), let max = dates.max() else { return nil }
        return (min, max)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parse(_ iso: String) -> Date? {
        ISO8601.immichFormatter.date(from: iso) ?? ISO8601.fallbackFormatter.date(from: iso)
    }

    private static func lonCellDegrees(_ lat: Double, _ latCell: Double) -> Double {
        latCell / max(cos(lat * .pi / 180), 0.2)
    }

    /// Great-circle distance in meters.
    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    private struct GridKey: Hashable {
        let lat: Int
        let lon: Int
    }
}
