import Foundation
import CoreLocation

// MARK: - Geometry

/// A single point on a travel leg (lat/lon). Straight-line fallback legs carry
/// exactly two points (from, to); real MKDirections legs carry the full
/// polyline.
struct RoutePoint: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A travel leg between two consecutive clusters. Distance drives the travel
/// duration budget; route drives the map drawing.
struct RoadTripLeg: Equatable, Sendable {
    let fromClusterID: String
    let toClusterID: String
    let distanceMeters: Double
    let route: [RoutePoint]
}

// MARK: - Timeline

/// The fully-resolved, deterministic show plan. Both the live player and the
/// export renderer consume the same timeline — same seeds, same durations,
/// same transforms — so positions and motion match. (Travel legs: the player
/// renders real 3D MapKit; the export simulates the same chase perspective
/// from 2D snapshots via `RoadTripDriveCamera`.)
struct RoadTripTimeline: Equatable, Sendable {

    struct Slideshow: Equatable, Sendable {
        let clusterID: String
        /// Indices into the cluster's `assets` (resolved, possibly subsampled).
        let assetIndices: [Int]
        /// Per-photo display durations, parallel to `assetIndices` (mean preserved).
        let photoDurations: [TimeInterval]
        /// Per-cluster salt so Ken Burns recipes vary between clusters.
        let recipeOffset: Int
        /// Arc energy 0…1 at this cluster (drives pacing + Ken Burns speed).
        let energy: Double
    }

    struct Travel: Equatable, Sendable {
        let fromClusterID: String
        let toClusterID: String
        let distanceMeters: Double
        let route: [RoutePoint]
        let duration: TimeInterval
    }

    enum Segment: Equatable, Sendable {
        case opening(duration: TimeInterval)
        case slideshow(Slideshow)
        case travel(Travel)
        case ending(duration: TimeInterval)

        var duration: TimeInterval {
            switch self {
            case .opening(let d), .ending(let d): return d
            case .slideshow(let s): return s.photoDurations.reduce(0, +)
            case .travel(let t): return t.duration
            }
        }
    }

    let segments: [Segment]
    /// Cumulative start time of each segment (parallel to `segments`),
    /// precomputed once instead of per frame (playback + export hit this every
    /// tick).
    let segmentStartTimes: [TimeInterval]

    init(segments: [Segment]) {
        self.segments = segments
        var starts: [TimeInterval] = []
        var cursor: TimeInterval = 0
        for segment in segments {
            starts.append(cursor)
            cursor += segment.duration
        }
        self.segmentStartTimes = starts
    }

    var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// Index of the segment active at absolute time `t` (clamped to the last).
    func segmentIndex(at t: TimeInterval) -> Int {
        let starts = segmentStartTimes
        guard !starts.isEmpty else { return 0 }
        var index = 0
        for (i, start) in starts.enumerated() where start <= t {
            index = i
        }
        return index
    }

    /// Place names with duplicates collapsed — the ending credits list each
    /// place once (a trip that returns to Palma shows Palma once).
    static func dedupedPlaceNames(_ places: [String]) -> [String] {
        var seen = Set<String>()
        return places.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Active segment index + time local to that segment.
    func localTime(at t: TimeInterval) -> (segmentIndex: Int, local: TimeInterval) {
        let index = segmentIndex(at: t)
        let local = t - segmentStartTimes[index]
        return (index, local)
    }
}

// MARK: - Builder + pacing

/// Builds the timeline from clusters + legs — the "best of the trip" film.
///
/// Structure: a deterministic energy arc across the trip (build-up → climax →
/// resolution) drives photo durations (on a rhythm grid), travel pacing and
/// Ken Burns speed. A global budget keeps the film at the social-media target
/// (~78 s max), the best photos are picked first (favorites weighted, quality
/// scored), and every duration stays quantized so the cuts land on a steady
/// tempo even without music.
enum RoadTripTimelineBuilder {

    static let openingDuration: TimeInterval = 2.5
    static let endingDuration: TimeInterval = 3.5
    /// Hard duration target: budgets shrink toward it (social-media friendly).
    /// Raised from 78 s to fund slower, readable travel legs.
    static let targetDuration: TimeInterval = 90
    /// Rhythm grid — photo durations are multiples of this unit.
    static let gridUnit: TimeInterval = 1.3
    static let maxPhotosPerCluster: Int = 6
    /// Desired photo count across the whole trip (duration is the hard cap).
    /// Trimmed from 18 so the slower travel legs still fit the budget.
    static let desiredTotalPhotos = 14
    static let crossfadeDuration: TimeInterval = 0.4
    /// Photo duration multipliers (grid units) at peak / lowest energy.
    static let maxMultiplier = 3.0
    static let minMultiplier = 1.0

    /// Energy arc across the cluster sequence: 0.35 → 1 (middle) → 0.35.
    static func energy(at index: Int, count: Int) -> Double {
        guard count > 1 else { return 0.9 }
        let x = Double(index) / Double(count - 1)
        return 0.35 + 0.65 * sin(.pi * x)
    }

    /// Travel duration from the leg's ARC length + energy. The old formula
    /// paced a 6 km leg at 2.5 s (2.4 km/s) — hairpins crossed in 1–2 frames,
    /// which is what made winding roads strobe. Now: ~1.2 km/s, 4–9 s per
    /// leg, so any corner receives ≥ 3 frames. Winding legs use their arc
    /// (≫ chord), not the straight-line distance.
    static func travelDuration(arcMeters: Double, energy: Double) -> TimeInterval {
        let base = min(max(arcMeters / 1_200.0, 4.0), 9.0)
        return max(3.5, base * (1.0 - 0.15 * energy))
    }

    /// Photo duration multiplier (grid units) at the given energy.
    static func photoMultiplier(energy: Double) -> Double {
        maxMultiplier - (maxMultiplier - minMultiplier) * min(max(energy, 0), 1)
    }

    static func build(
        clusters: [RoadTripCluster],
        legs: [RoadTripLeg],
        scores: [String: Double]? = nil
    ) -> RoadTripTimeline? {
        guard !clusters.isEmpty, clusters.allSatisfy({ !$0.assets.isEmpty }) else { return nil }

        let legAfter: [String: RoadTripLeg] = Dictionary(uniqueKeysWithValues: legs.map { ($0.fromClusterID, $0) })

        // Pass 1: travel durations — paced by the leg's ARC length (a winding
        // road is longer than its chord), trimmed at the climax.
        var travelDurations: [Int: TimeInterval] = [:]
        var travelTotal: TimeInterval = 0
        for (index, cluster) in clusters.enumerated() {
            guard let leg = legAfter[cluster.id] else { continue }
            let arc = RoadTripTravelTiming.cumulativeLengths(leg.route).last ?? leg.distanceMeters
            let duration = travelDuration(
                arcMeters: arc,
                energy: energy(at: index, count: clusters.count)
            )
            travelDurations[index] = duration
            travelTotal += duration
        }

        // Pass 2: photo budget — fit the remaining time under the target.
        let photoTimeBudget = max(gridUnit, targetDuration - openingDuration - endingDuration - travelTotal)
        let desiredPhotos = min(desiredTotalPhotos, max(clusters.count, Int(photoTimeBudget / gridUnit)))

        let caps = clusters.map { min($0.assets.count, maxPhotosPerCluster) }
        let capTotal = caps.reduce(0, +)
        var counts = caps.map { cap in
            capTotal > 0 ? max(1, Int((Double(desiredPhotos) * Double(cap) / Double(capTotal)).rounded())) : 1
        }
        // Trim the largest shares (from the end, deterministic) until the
        // budget holds — never below one photo per stop.
        while counts.reduce(0, +) > desiredPhotos {
            var drop = counts.count - 1
            for i in stride(from: counts.count - 1, through: 0, by: -1) where counts[i] > counts[drop] {
                drop = i
            }
            if counts[drop] > 1 { counts[drop] -= 1 } else { break }
        }

        var slideshows: [RoadTripTimeline.Slideshow] = []
        for (index, cluster) in clusters.enumerated() {
            let e = energy(at: index, count: clusters.count)
            let rank = rank(for: cluster, scores: scores)
            let indices = selectedIndices(kept: counts[index], count: cluster.assets.count, rank: rank)
            slideshows.append(RoadTripTimeline.Slideshow(
                clusterID: cluster.id,
                assetIndices: indices,
                photoDurations: photoDurations(kept: indices.count, multiplier: photoMultiplier(energy: e)),
                recipeOffset: stableHash(cluster.id),
                energy: e
            ))
        }

        var segments: [RoadTripTimeline.Segment] = [.opening(duration: openingDuration)]
        for (index, cluster) in clusters.enumerated() {
            segments.append(.slideshow(slideshows[index]))
            if let leg = legAfter[cluster.id], let duration = travelDurations[index] {
                segments.append(.travel(RoadTripTimeline.Travel(
                    fromClusterID: leg.fromClusterID,
                    toClusterID: leg.toClusterID,
                    distanceMeters: leg.distanceMeters,
                    route: leg.route,
                    duration: duration
                )))
            }
        }
        segments.append(.ending(duration: endingDuration))

        return RoadTripTimeline(segments: segments)
    }

    /// Preference order for a cluster's assets: favorites first, then quality
    /// score (ties by index — stable and deterministic).
    static func rank(for cluster: RoadTripCluster, scores: [String: Double]?) -> [Int] {
        let indices = Array(cluster.assets.indices)
        return indices.sorted { a, b in
            let fa = cluster.assets[a].isFavorite ? 1.0 : 0.0
            let fb = cluster.assets[b].isFavorite ? 1.0 : 0.0
            if fa != fb { return fa > fb }
            let sa = scores?[cluster.assets[a].id] ?? 0.5
            let sb = scores?[cluster.assets[b].id] ?? 0.5
            if sa != sb { return sa > sb }
            return a < b
        }
    }

    /// Top-`kept` of the ranked indices, back in chronological order so the
    /// film keeps telling the trip's story. Evenly-spaced fallback when no
    /// rank is supplied.
    static func selectedIndices(kept: Int, count: Int, rank: [Int]? = nil) -> [Int] {
        guard count > 0 else { return [] }
        let k = min(max(kept, 1), count)
        if let rank, rank.count == count {
            return Array(rank.prefix(k)).sorted()
        }
        if k == 1 { return [0] }
        if k == count { return Array(0..<count) }
        return (0..<k).map { Int((Double($0) * Double(count - 1) / Double(k - 1)).rounded()) }
    }

    /// Per-photo durations on the rhythm grid, alternating ⌈m⌉/⌊m⌋ units so
    /// the mean stays at `multiplier` units (last duration absorbs the
    /// remainder) — a musical feel that holds the budget.
    static func photoDurations(kept: Int, multiplier: Double) -> [TimeInterval] {
        guard kept > 0 else { return [] }
        let low = max(1.0, floor(multiplier))
        let high = max(low, ceil(multiplier))
        var result = (0..<kept).map { i in (i % 2 == 0 ? high : low) * gridUnit }
        let target = multiplier * gridUnit * Double(kept)
        let sum = result.reduce(0, +)
        result[kept - 1] += target - sum
        return result
    }

    /// FNV-1a-ish stable hash (deterministic across launches) for recipe salts.
    static func stableHash(_ string: String) -> Int {
        var hash = 0x811c9dc5
        for scalar in string.unicodeScalars {
            hash = (hash ^ Int(scalar.value)) &* 0x01000193
        }
        return hash & 0x7FFFFFFF
    }
}

// MARK: - Ken Burns recipes

struct KenBurnsTransform: Equatable, Sendable {
    var scale: Double = 1
    /// Fraction of canvas width / height (presenters scale by their size).
    var offsetX: Double = 0
    var offsetY: Double = 0

    static let identity = KenBurnsTransform()
}

enum KenBurnsMotion: String, CaseIterable, Sendable {
    case zoomIn, zoomOut, panLeft, panRight, panUp, panDown
}

enum KenBurnsRecipe {

    /// Picks a motion deterministically from a slide's global position + the
    /// cluster's recipe salt (variety across clusters, identical live/export).
    static func motion(at position: Int, offset: Int) -> KenBurnsMotion {
        let cases = KenBurnsMotion.allCases
        let index = ((position + offset) % cases.count + cases.count) % cases.count
        return cases[index]
    }

    static func transform(motion: KenBurnsMotion, progress: Double, reduceMotion: Bool, energy: Double = 0.7) -> KenBurnsTransform {
        guard !reduceMotion else { return .identity }
        let e = smoothstep(min(max(progress, 0), 1))
        // Amplitude follows the arc energy: calm at build-up, punchy at the climax.
        let amplitude = 0.55 + 0.65 * min(max(energy, 0), 1)
        switch motion {
        case .zoomIn:
            return KenBurnsTransform(scale: 1 + 0.12 * e * amplitude)
        case .zoomOut:
            return KenBurnsTransform(scale: 1 + 0.12 * (1 - e) * amplitude)
        case .panLeft:
            return KenBurnsTransform(scale: 1.06, offsetX: (0.03 - 0.06 * e) * amplitude, offsetY: (0.015 - 0.03 * e) * amplitude)
        case .panRight:
            return KenBurnsTransform(scale: 1.06, offsetX: (-0.03 + 0.06 * e) * amplitude, offsetY: (-0.015 + 0.03 * e) * amplitude)
        case .panUp:
            return KenBurnsTransform(scale: 1.06, offsetX: (0.015 - 0.03 * e) * amplitude, offsetY: (0.03 - 0.06 * e) * amplitude)
        case .panDown:
            return KenBurnsTransform(scale: 1.06, offsetX: (-0.015 + 0.03 * e) * amplitude, offsetY: (-0.03 + 0.06 * e) * amplitude)
        }
    }

    /// Smoothstep ease (0→1), the shared motion curve for Ken Burns + travel.
    static func smoothstep(_ x: Double) -> Double {
        x * x * (3 - 2 * x)
    }
}

// MARK: - Slide timing

enum RoadTripSlideTiming {

    struct Frame: Equatable, Sendable {
        /// Position into `slideshow.assetIndices`.
        let currentIndex: Int
        let currentTransform: KenBurnsTransform
        /// Set during the tail crossfade of the current slide.
        let nextIndex: Int?
        let nextTransform: KenBurnsTransform?
        /// 0..1 alpha of the incoming (next) slide.
        let crossfade: Double
    }

    /// Resolves what to draw at `localTime` within a slideshow segment: the
    /// active photo, its Ken Burns transform, and the tail crossfade state.
    static func frame(
        slideshow: RoadTripTimeline.Slideshow,
        localTime: TimeInterval,
        reduceMotion: Bool
    ) -> Frame {
        let durations = slideshow.photoDurations
        let count = durations.count
        guard count > 0 else {
            return Frame(currentIndex: 0, currentTransform: .identity, nextIndex: nil, nextTransform: nil, crossfade: 0)
        }

        var remaining = max(localTime, 0)
        var index = 0
        while index < count - 1 && remaining >= durations[index] {
            remaining -= durations[index]
            index += 1
        }
        let duration = max(durations[index], 0.001)
        let progress = min(max(remaining / duration, 0), 1)
        let motion = KenBurnsRecipe.motion(at: index, offset: slideshow.recipeOffset)
        let transform = KenBurnsRecipe.transform(motion: motion, progress: progress, reduceMotion: reduceMotion, energy: slideshow.energy)

        var nextIndex: Int?
        var nextTransform: KenBurnsTransform?
        var crossfade = 0.0
        if index < count - 1 {
            let window = min(RoadTripTimelineBuilder.crossfadeDuration, duration * 0.25, durations[index + 1] * 0.25)
            if remaining >= duration - window {
                crossfade = min(max((remaining - (duration - window)) / window, 0), 1)
                nextIndex = index + 1
                let nextMotion = KenBurnsRecipe.motion(at: index + 1, offset: slideshow.recipeOffset)
                nextTransform = KenBurnsRecipe.transform(motion: nextMotion, progress: 0, reduceMotion: reduceMotion, energy: slideshow.energy)
            }
        }

        return Frame(
            currentIndex: index,
            currentTransform: transform,
            nextIndex: nextIndex,
            nextTransform: nextTransform,
            crossfade: crossfade
        )
    }
}

// MARK: - Segment transitions

/// Timing for the map↔media transitions, shared by the live player and the
/// export renderer so the film moves identically in both.
enum RoadTripSegue {
    /// Slideshow→travel: the last photo of the outgoing slideshow fades out
    /// over the first moments of the map leg.
    static let photoFadeOutDuration: TimeInterval = 0.4
    /// Travel→slideshow: the "arrival dive" window at the tail of the leg —
    /// a pin pops at the destination, the first photo of the next stop
    /// thumbnails up from the pin and fills the screen as the map fades.
    static let diveDuration: TimeInterval = 0.6
    /// Fraction of the dive spent revealing the thumbnail before the map
    /// starts fading.
    static let thumbRevealFraction = 0.35
    /// Size of the dive thumbnail (canvas fraction) at the destination.
    static let thumbSizeFraction = 0.13

    /// 0..1 dive progress during the leg tail (0 outside the dive window).
    static func diveProgress(localTime: TimeInterval, legDuration: TimeInterval) -> Double {
        let tail = max(legDuration - diveDuration, 0)
        return min(max((localTime - tail) / diveDuration, 0), 1)
    }

    /// 0..1 map fade-out through the dive (starts after the thumbnail reveal).
    static func mapFade(_ dive: Double) -> Double {
        let p = min(max((dive - thumbRevealFraction) / (1 - thumbRevealFraction), 0), 1)
        return KenBurnsRecipe.smoothstep(p)
    }

    /// Thumbnail opacity through the dive: quick reveal, held to the end.
    static func thumbnailAlpha(_ dive: Double) -> Double {
        KenBurnsRecipe.smoothstep(min(max(dive / 0.25, 0), 1))
    }

    /// Pop scale of the destination pin: overshoots in at the dive start and
    /// settles to 1.
    static func pinPop(_ dive: Double) -> Double {
        1 + 0.35 * (1 - KenBurnsRecipe.smoothstep(min(max(dive * 2.5, 0), 1)))
    }

    /// Thumbnail rect from the destination pin to full canvas (linear lerp of
    /// the dive — the Ken Burns motion stays on the slideshow side).
    static func thumbnailRect(pinCenter: CGPoint, pinSize: CGSize, canvas: CGSize, dive: Double) -> CGRect {
        let t = min(max(dive, 0), 1)
        let from = CGRect(x: pinCenter.x - pinSize.width / 2, y: pinCenter.y - pinSize.height / 2,
                          width: pinSize.width, height: pinSize.height)
        let to = CGRect(origin: .zero, size: canvas)
        return CGRect(
            x: from.minX + (to.minX - from.minX) * t,
            y: from.minY + (to.minY - from.minY) * t,
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t
        )
    }

    /// Outgoing-photo fade-out alpha over the incoming map (1 → 0).
    static func outgoingPhotoAlpha(localTime: TimeInterval) -> Double {
        guard localTime < photoFadeOutDuration else { return 0 }
        return 1 - KenBurnsRecipe.smoothstep(localTime / photoFadeOutDuration)
    }
}

// MARK: - Travel timing

enum RoadTripTravelTiming {

    struct Frame: Equatable, Sendable {
        /// Eased 0..1 progress along the leg.
        let progress: Double
        let carCoordinate: RoutePoint
        let routeDrawnFraction: Double
        /// Growing prefix of the route (for progressive drawing).
        let trimmedRoute: [RoutePoint]
    }

    static func frame(travel: RoadTripTimeline.Travel, localTime: TimeInterval) -> Frame {
        let duration = max(travel.duration, 0.001)
        let raw = min(max(localTime / duration, 0), 1)
        let eased = easeInOut(raw)
        // Map film time → physical arc fraction through the curvature-weighted
        // speed profile, so the car slows through corners and accelerates on
        // straights while the global ease-in/out still holds the leg's rhythm.
        let fraction = arcFraction(atTimeFraction: eased, route: travel.route)
        let car = interpolate(travel.route, fraction: fraction)
        return Frame(
            progress: fraction,
            carCoordinate: car,
            routeDrawnFraction: fraction,
            trimmedRoute: trimmed(travel.route, fraction: fraction)
        )
    }

    /// Cubic ease-in-out (shared with the renderer so map motion feels the same
    /// live and in the export).
    static func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// Cumulative haversine lengths [0, d0, d0+d1, ...]. Cached per route: this
    /// runs on every frame during playback and export (the timing, heading and
    /// camera math all call it per frame), so an uncached O(n) haversine sweep
    /// would drop frames on long legs.
    private final class CumulativeEntry: NSObject {
        let lengths: [Double]
        init(_ lengths: [Double]) { self.lengths = lengths }
    }
    private static let cumulativeCache = NSCache<NSString, CumulativeEntry>()

    static func cumulativeLengths(_ route: [RoutePoint]) -> [Double] {
        guard !route.isEmpty else { return [] }
        var hash = 0
        for p in route {
            hash = hash &* 31 &+ Int(p.latitude * 1e6) &+ Int(p.longitude * 1e6)
        }
        let key = "\(route.count)|\(hash)" as NSString
        if let cached = cumulativeCache.object(forKey: key) { return cached.lengths }
        var result: [Double] = [0]
        var total = 0.0
        for i in 1..<route.count {
            total += RoadTripClusterer.haversine(route[i - 1].coordinate, route[i].coordinate)
            result.append(total)
        }
        cumulativeCache.countLimit = 64
        cumulativeCache.setObject(CumulativeEntry(result), forKey: key)
        return result
    }

    /// Interpolates the coordinate at arc-length `fraction` along the route.
    static func interpolate(_ route: [RoutePoint], fraction: Double) -> RoutePoint {
        guard let first = route.first else {
            return RoutePoint(latitude: 0, longitude: 0)
        }
        guard route.count > 1 else { return first }
        let cumulative = cumulativeLengths(route)
        let total = cumulative.last ?? 0
        guard total > 0 else { return first }
        let target = min(max(fraction, 0), 1) * total
        var segment = 0
        while segment < route.count - 2 && cumulative[segment + 1] < target {
            segment += 1
        }
        let a = route[segment]
        let b = route[min(segment + 1, route.count - 1)]
        let segLength = cumulative[segment + 1] - cumulative[segment]
        let t = segLength > 0 ? min(max((target - cumulative[segment]) / segLength, 0), 1) : 0
        return RoutePoint(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    /// Route prefix drawn up to `fraction`, ending at the interpolated car.
    static func trimmed(_ route: [RoutePoint], fraction: Double) -> [RoutePoint] {
        guard let first = route.first else { return [] }
        let cumulative = cumulativeLengths(route)
        let total = cumulative.last ?? 0
        let target = min(max(fraction, 0), 1) * total
        var result: [RoutePoint] = [first]
        for i in 1..<route.count where cumulative[i] <= target {
            result.append(route[i])
        }
        let car = interpolate(route, fraction: fraction)
        if result.last != car {
            result.append(car)
        }
        return result
    }

    // MARK: - Curvature-aware speed

    /// 0..1 how much the route deviates from a straight line (tortuosity):
    /// 0 = straight, 1 = strongly winding. Deterministic (pure geometry),
    /// cached per route so the live player and the export agree exactly.
    static func twistiness(_ route: [RoutePoint]) -> Double {
        guard route.count >= 2 else { return 0 }
        var hash = 0
        for p in route {
            hash = hash &* 31 &+ Int(p.latitude * 1e6) &+ Int(p.longitude * 1e6)
        }
        let key = "t|\(route.count)|\(hash)" as NSString
        if let cached = twistinessCache.object(forKey: key) { return cached.doubleValue }
        let cumulative = cumulativeLengths(route)
        let total = cumulative.last ?? 0
        guard total > 0, let first = route.first, let last = route.last else { return 0 }
        let straight = RoadTripClusterer.haversine(first.coordinate, last.coordinate)
        guard straight > 0 else { return 0 }
        let deviation = total / straight - 1.0
        guard deviation > 1e-3 else { return 0 }
        let value = min(deviation / 0.5, 1)
        twistinessCache.countLimit = 64
        twistinessCache.setObject(NSNumber(value: value), forKey: key)
        return value
    }

    /// Arc-length fraction at a given *time* fraction, following the curvature-
    /// weighted speed profile: segments through corners contribute more time
    /// (slower), straights less (faster). Deterministic, cached per route.
    static func arcFraction(atTimeFraction t: Double, route: [RoutePoint]) -> Double {
        let profile = speedProfile(route)
        let tf = profile.timeFraction
        let af = profile.arcFraction
        let n = tf.count
        guard n > 1 else { return 0 }
        let target = min(max(t, 0), 1)
        var lo = 0, hi = n - 2
        while lo < hi {
            let mid = (lo + hi) / 2
            if tf[mid + 1] < target { lo = mid + 1 } else { hi = mid }
        }
        let span = max(tf[lo + 1] - tf[lo], 1e-12)
        let frac = min(max((target - tf[lo]) / span, 0), 1)
        return af[lo] + (af[lo + 1] - af[lo]) * frac
    }

    private final class SpeedProfile: NSObject {
        let timeFraction: [Double]
        let arcFraction: [Double]
        init(_ timeFraction: [Double], _ arcFraction: [Double]) {
            self.timeFraction = timeFraction
            self.arcFraction = arcFraction
        }
    }
    private static let speedProfileCache = NSCache<NSString, SpeedProfile>()
    private static let twistinessCache = NSCache<NSString, NSNumber>()

    /// Cumulative time fraction + arc fraction at each route point, weighting
    /// each segment by its curvature so the car brakes through corners and
    /// accelerates on straights. The factor curve is blurred over ~±350 m of
    /// arc first — sampled per-vertex it wobbled every few frames, which read
    /// as surging on winding roads.
    private static func speedProfile(_ route: [RoutePoint]) -> SpeedProfile {
        guard route.count >= 2 else { return SpeedProfile([0], [0]) }
        var hash = 0
        for p in route {
            hash = hash &* 31 &+ Int(p.latitude * 1e6) &+ Int(p.longitude * 1e6)
        }
        let key = "sp|\(route.count)|\(hash)" as NSString
        if let cached = speedProfileCache.object(forKey: key) { return cached }

        let cum = cumulativeLengths(route)
        let total = cum.last ?? 0
        var factors: [Double] = []
        factors.reserveCapacity(route.count - 1)
        for i in 1..<route.count {
            factors.append(segmentSpeedFactor(route, at: i))
        }
        let blurred = blurByArc(factors, cumulative: cum, radius: 350)

        var arcFrac: [Double] = [0]
        var rawTime: [Double] = [0]
        var t = 0.0
        for i in 1..<route.count {
            let segLen = cum[i] - cum[i - 1]
            t += segLen / blurred[i - 1]
            arcFrac.append(total > 0 ? cum[i] / total : 0)
            rawTime.append(t)
        }
        let maxT = t
        var timeFrac = rawTime.map { maxT > 0 ? $0 / maxT : 0 }
        timeFrac[timeFrac.count - 1] = 1
        speedProfileCache.countLimit = 64
        let profile = SpeedProfile(timeFrac, arcFrac)
        speedProfileCache.setObject(profile, forKey: key)
        return profile
    }

    /// Two box-blur passes over an arc-length radius (per-segment values).
    private static func blurByArc(_ values: [Double], cumulative: [Double], radius: Double) -> [Double] {
        let n = values.count
        guard n > 1, radius > 0 else { return values }
        let mid = (0..<n).map { (cumulative[$0] + cumulative[$0 + 1]) / 2 }
        var current = values
        for _ in 0..<2 {
            var out = current
            var lo = 0
            for i in 0..<n {
                while lo < i && mid[i] - mid[lo] > radius { lo += 1 }
                var hi = i
                while hi + 1 < n && mid[hi + 1] - mid[i] <= radius { hi += 1 }
                var sum = 0.0
                for j in lo...hi { sum += current[j] }
                out[i] = sum / Double(hi - lo + 1)
            }
            current = out
        }
        return current
    }

    /// 0..1 speed factor for the segment ending at `index`: 1 on straights,
    /// lower through corners (curvature = bearing change per meter). Sampled
    /// over ±5 points (~±200 m densified) so single kinks don't spike it;
    /// clamped so the car never stalls in a hairpin.
    private static func segmentSpeedFactor(_ route: [RoutePoint], at i: Int) -> Double {
        guard i > 0, i < route.count - 1 else { return 1 }
        let back = max(i - 5, 0)
        let forward = min(i + 5, route.count - 1)
        let a = route[back].coordinate, b = route[i].coordinate, c = route[forward].coordinate
        let inBearing = bearing(a, b)
        let outBearing = bearing(b, c)
        var turn = abs(outBearing - inBearing)
        if turn > .pi { turn = 2 * .pi - turn }
        let segLen = RoadTripClusterer.haversine(b, c) + RoadTripClusterer.haversine(a, b)
        let turnPerMeter = turn / max(segLen, 1)
        let sharpness = min(turnPerMeter / 0.02, 1)
        return max(1.0 - 0.8 * sharpness, 0.2)
    }

    /// Initial compass bearing (radians, north = 0, clockwise) a→b.
    private static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x)
    }
}
