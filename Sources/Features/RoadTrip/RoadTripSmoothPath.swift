import Foundation
import CoreLocation
import MapKit

/// A smoothed, arc-length-parameterized centerline derived from a route
/// polyline. The camera follows this "rail" while the car stays on the raw
/// route, so the camera trajectory is continuous and free of the polyline's
/// vertex snaps. Smoothing is purely spatial (a Gaussian over arc length), so
/// the rail is deterministic and identical for the live player and the export
/// renderer — no temporal state that could drift between the two.
///
/// The rail is parameterized by the *raw* route's arc length (each smoothed
/// point keeps its original arc-length label), so `total` matches
/// `RoadTripTravelTiming.cumulativeLengths(route).last` exactly and the camera
/// trails the car by a well-defined distance.
struct RoadTripSmoothPath: Sendable {

    let points: [RoutePoint]
    let total: Double
    fileprivate let mapPoints: [MKMapPoint]
    fileprivate let cumulative: [Double]
    /// Cache identity assigned by `make(route:sigma:...)` — nil for direct
    /// `init` builds. Lets derived artifacts (heading rails) share the cache.
    fileprivate let cacheKey: String?

    private final class Box: NSObject {
        let path: RoadTripSmoothPath
        init(_ path: RoadTripSmoothPath) { self.path = path }
    }
    private static let cache = NSCache<NSString, Box>()

    /// Ceiling on the resampled points of a rail (the spacing widens past it).
    static let maxResampledPoints = 20_000.0

    /// Builds (or fetches from cache) the smoothed rail for a route.
    static func make(route: [RoutePoint], sigma: Double, spacing: Double = 10, minSigma: Double? = nil) -> RoadTripSmoothPath {
        guard route.count >= 2 else { return RoadTripSmoothPath(route: route) }
        var hash = 0
        for p in route {
            hash = hash &* 31 &+ Int(p.latitude * 1e6) &+ Int(p.longitude * 1e6)
        }
        let key = "\(route.count)|\(hash)|\(sigma)|\(spacing)|\(minSigma ?? -1)" as NSString
        if let box = cache.object(forKey: key) { return box.path }
        let path = RoadTripSmoothPath(route: route, sigma: sigma, spacing: spacing, minSigma: minSigma, cacheKey: key as String)
        cache.countLimit = 24
        cache.setObject(Box(path), forKey: key)
        return path
    }

    init(route: [RoutePoint], sigma: Double = 0, spacing: Double = 10, minSigma: Double? = nil, cacheKey: String? = nil) {
        self.cacheKey = cacheKey
        guard route.count >= 2 else {
            self.points = route
            self.total = 0
            self.mapPoints = route.map { MKMapPoint($0.coordinate) }
            self.cumulative = [0]
            return
        }

        let rawMP = route.map { MKMapPoint($0.coordinate) }
        let rawArc = Self.cumulativeMeters(route)
        let rawTotal = rawArc.last ?? 0

        let midLat = route.map(\.latitude).reduce(0, +) / Double(route.count)
        let ppm = MKMapPointsPerMeterAtLatitude(midLat)
        // Never more than ~`maxResampledPoints` samples: at 10 m a long leg
        // (a 1 000 km straight line between two far stops) made 100 000
        // points, smoothed on the main actor at the leg's first frame.
        let spacingMP = max(spacing, rawTotal / Self.maxResampledPoints) * ppm

        // Resample linearly in map-point space, carrying each point's raw
        // arc-length label so smoothing never changes the parameterization.
        var denseMP: [MKMapPoint] = [rawMP[0]]
        var denseArc: [Double] = [0]
        for i in 1..<rawMP.count {
            let a = rawMP[i - 1], b = rawMP[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = sqrt(dx * dx + dy * dy)
            let steps = max(1, Int(len / max(spacingMP, 1)))
            for s in 1..<steps {
                let t = Double(s) / Double(steps)
                denseMP.append(MKMapPoint(x: a.x + dx * t, y: a.y + dy * t))
                denseArc.append(rawArc[i - 1] + (rawArc[i] - rawArc[i - 1]) * t)
            }
            denseMP.append(b)
            denseArc.append(rawArc[i])
        }

        let smoothed: [MKMapPoint]
        if sigma > 0 {
            let sigmas = Self.adaptiveSigmas(mp: denseMP, arc: denseArc, sigma: sigma, minSigma: minSigma)
            smoothed = Self.gaussianSmooth(denseMP, arc: denseArc, sigmas: sigmas)
        } else {
            smoothed = denseMP
        }

        self.mapPoints = smoothed
        self.points = smoothed.map {
            RoutePoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
        }
        self.cumulative = denseArc
        self.total = rawTotal
    }

    // MARK: - Queries

    func fraction(atDistance distance: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(max(distance / total, 0), 1)
    }

    /// Point on the rail at arc-length `distance` meters (clamped).
    func point(atDistance distance: Double) -> RoutePoint {
        point(at: fraction(atDistance: distance))
    }

    /// Point on the rail at arc-length fraction 0…1 (clamped).
    func point(at fraction: Double) -> RoutePoint {
        let n = mapPoints.count
        guard n > 0 else { return RoutePoint(latitude: 0, longitude: 0) }
        guard n > 1, total > 0 else { return points[0] }
        let target = min(max(fraction, 0), 1) * total
        var lo = 0, hi = n - 2
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid + 1] < target { lo = mid + 1 } else { hi = mid }
        }
        let span = max(cumulative[lo + 1] - cumulative[lo], 1e-12)
        let t = min(max((target - cumulative[lo]) / span, 0), 1)
        let a = mapPoints[lo], b = mapPoints[lo + 1]
        let mp = MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        return RoutePoint(latitude: mp.coordinate.latitude, longitude: mp.coordinate.longitude)
    }

    /// Unit tangent (map-point space: +x east, +y south) at arc-length fraction.
    func tangent(at fraction: Double) -> (dx: Double, dy: Double) {
        let n = mapPoints.count
        guard n > 1, total > 0 else { return (1, 0) }
        let target = min(max(fraction, 0), 1) * total
        var lo = 0, hi = n - 2
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid + 1] < target { lo = mid + 1 } else { hi = mid }
        }
        let t0 = tangent(atIndex: lo)
        let t1 = tangent(atIndex: lo + 1)
        let span = max(cumulative[lo + 1] - cumulative[lo], 1e-12)
        let t = min(max((target - cumulative[lo]) / span, 0), 1)
        var dx = t0.dx + (t1.dx - t0.dx) * t
        var dy = t0.dy + (t1.dy - t0.dy) * t
        let len = sqrt(dx * dx + dy * dy)
        guard len > 1e-12 else { return t0 }
        dx /= len; dy /= len
        return (dx, dy)
    }

    /// Compass heading (radians, north = 0, clockwise) at arc-length fraction.
    func heading(at fraction: Double) -> Double {
        let t = tangent(at: fraction)
        // Map point y grows SOUTHWARD: compass bearing = atan2(east, −mapY).
        return atan2(t.dx, -t.dy)
    }

    // MARK: - Building

    private func tangent(atIndex i: Int) -> (dx: Double, dy: Double) {
        let n = mapPoints.count
        let a = mapPoints[max(i - 1, 0)]
        let b = mapPoints[min(i + 1, n - 1)]
        return (b.x - a.x, b.y - a.y)
    }

    /// Per-point smoothing sigma: full `sigma` on straights and gentle curves,
    /// shrunk toward ~`minSigma` (default 40 m) on tight hairpins (turn rate
    /// above ~0.03 rad/m). Keeps the rail gliding through ordinary winding
    /// roads while hugging genuine switchbacks instead of cutting across them.
    /// The camera rail passes a higher floor (`RoadTripDriveCamera`) so the
    /// chase view stays fluid through hairpins while the car rail keeps the
    /// default to stay glued to the road.
    private static func adaptiveSigmas(mp: [MKMapPoint], arc: [Double], sigma: Double, minSigma: Double?) -> [Double] {
        let n = mp.count
        guard n > 3 else { return Array(repeating: sigma, count: n) }
        let sigmaMin = min(sigma, minSigma ?? 40.0)

        // Bearing at each point from neighbors ±3 samples (~30 m), noise-robust.
        var bearings = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = mp[max(i - 3, 0)]
            let b = mp[min(i + 3, n - 1)]
            bearings[i] = atan2(b.x - a.x, -(b.y - a.y))
        }

        let windowMeters = 40.0
        var sigmas = [Double](repeating: sigma, count: n)
        for i in 0..<n {
            let di = arc[i]
            var lo = i
            while lo > 0 && di - arc[lo - 1] < windowMeters { lo -= 1 }
            var hi = i
            while hi < n - 1 && arc[hi + 1] - di < windowMeters { hi += 1 }
            var totalTurn = 0.0
            for j in lo..<hi {
                var d = abs(bearings[j + 1] - bearings[j])
                if d > .pi { d = 2 * .pi - d }
                totalTurn += d
            }
            let length = max(arc[hi] - arc[lo], 1)
            let turnRate = totalTurn / length
            let sharpness = min(max((turnRate - 0.03) / 0.02, 0), 1)
            sigmas[i] = sigma - (sigma - sigmaMin) * sharpness
        }
        return sigmas
    }

    /// Gaussian arc-length smoothing (two-pointer window, O(n)) with a per-point
    /// sigma. The route is reflected beyond each end so the kernel stays
    /// symmetric at the endpoints — the endpoints stay anchored and the
    /// parameterization stays uniform right up to the ends (no inward pull /
    /// arc-length compression). Each point's arc-length label is preserved, so
    /// `total` never changes.
    private static func gaussianSmooth(_ pts: [MKMapPoint], arc: [Double], sigmas: [Double]) -> [MKMapPoint] {
        let n = pts.count
        guard n > 2 else { return pts }
        let maxSigma = sigmas.max() ?? 0
        let window = 3 * maxSigma

        var ext = pts
        var extArc = arc
        var leftCount = 0
        for j in 1..<n {
            let d = arc[j] - arc[0]
            if d > window { break }
            ext.insert(MKMapPoint(x: 2 * pts[0].x - pts[j].x, y: 2 * pts[0].y - pts[j].y), at: 0)
            extArc.insert(-d, at: 0)
            leftCount += 1
        }
        for j in stride(from: n - 2, through: 0, by: -1) {
            let d = arc[n - 1] - arc[j]
            if d > window { break }
            ext.append(MKMapPoint(x: 2 * pts[n - 1].x - pts[j].x, y: 2 * pts[n - 1].y - pts[j].y))
            extArc.append(arc[n - 1] + d)
        }

        let m = ext.count
        var out = ext
        let extSigmas = Array(repeating: maxSigma, count: leftCount)
            + sigmas
            + Array(repeating: maxSigma, count: m - n - leftCount)
        var lo = 0
        for i in 0..<m {
            let di = extArc[i]
            let sigma = extSigmas[i]
            let w = 3 * sigma
            while lo > 0 && extArc[lo] >= di - w { lo -= 1 }
            while lo < m && extArc[lo] < di - w { lo += 1 }
            var hi = lo
            while hi < m && extArc[hi] <= di + w { hi += 1 }
            var wx = 0.0, wy = 0.0, wsum = 0.0
            for j in lo..<hi {
                let d = extArc[j] - di
                let weight = exp(-(d * d) / (2 * sigma * sigma))
                wx += ext[j].x * weight
                wy += ext[j].y * weight
                wsum += weight
            }
            out[i] = MKMapPoint(x: wx / wsum, y: wy / wsum)
        }
        return Array(out[leftCount..<(leftCount + n)])
    }

    /// Cumulative arc length in true meters (haversine) over a route.
    private static func cumulativeMeters(_ points: [RoutePoint]) -> [Double] {
        guard !points.isEmpty else { return [] }
        var result: [Double] = [0]
        var total = 0.0
        for i in 1..<points.count {
            total += RoadTripClusterer.haversine(points[i - 1].coordinate, points[i].coordinate)
            result.append(total)
        }
        return result
    }
}

// MARK: - Heading rail

/// A deterministic heading signal over a smoothed rail — what the chase
/// camera and the car sprite face. Pipeline (all spatial, no temporal state):
///
/// 1. raw per-point bearings from neighbors ±3 samples;
/// 2. optional look-ahead blend toward the tangent ahead — engaged with a
///    smoothstep ramp above `blendThreshold`, so crossing the threshold never
///    snaps the heading (the old hard `guard` produced ±15° jumps exactly on
///    winding roads);
/// 3. circular Gaussian over arc length (`sigma` meters) — spreads each
///    corner's rotation instead of concentrating it;
/// 4. double-pass rate limiter (forward + backward): |dθ/ds| ≤ `maxTurnRate`
///    everywhere, so on-screen angular speed stays ≤ maxTurnRate × filmSpeed.
struct RoadTripHeadingRail: Sendable {

    let headings: [Double]
    let total: Double
    fileprivate let cumulative: [Double]

    func heading(at fraction: Double) -> Double {
        let n = headings.count
        guard n > 1, total > 0 else { return headings.first ?? 0 }
        let target = min(max(fraction, 0), 1) * total
        var lo = 0, hi = n - 2
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid + 1] < target { lo = mid + 1 } else { hi = mid }
        }
        let span = max(cumulative[lo + 1] - cumulative[lo], 1e-12)
        let t = min(max((target - cumulative[lo]) / span, 0), 1)
        var d = headings[lo + 1] - headings[lo]
        d = atan2(sin(d), cos(d))
        return headings[lo] + d * t
    }

    private final class Box: NSObject {
        let rail: RoadTripHeadingRail
        init(_ rail: RoadTripHeadingRail) { self.rail = rail }
    }

    private static let cache = NSCache<NSString, Box>()

    /// Builds (or fetches) the heading rail for a source rail + config.
    static func make(
        rail: RoadTripSmoothPath,
        sigma: Double,
        maxTurnRate: Double,
        lookAheadFraction: Double = 0,
        lookAheadBlend: Double = 0,
        blendThreshold: Double = 0,
        blendRamp: Double = 0
    ) -> RoadTripHeadingRail {
        let key = "h|\(rail.cacheKey ?? "uncached-\(rail.points.count)-\(Int(rail.total))")|\(sigma)|\(maxTurnRate)|\(lookAheadFraction)|\(lookAheadBlend)|\(blendThreshold)|\(blendRamp)" as NSString
        if let box = cache.object(forKey: key) { return box.rail }
        let built = RoadTripHeadingRail.build(
            rail: rail, sigma: sigma, maxTurnRate: maxTurnRate,
            lookAheadFraction: lookAheadFraction, lookAheadBlend: lookAheadBlend,
            blendThreshold: blendThreshold, blendRamp: blendRamp
        )
        cache.countLimit = 24
        cache.setObject(Box(built), forKey: key)
        return built
    }

    private static func build(
        rail: RoadTripSmoothPath,
        sigma: Double,
        maxTurnRate: Double,
        lookAheadFraction: Double,
        lookAheadBlend: Double,
        blendThreshold: Double,
        blendRamp: Double
    ) -> RoadTripHeadingRail {
        let mp = rail.mapPoints
        let arc = rail.cumulative
        let n = mp.count
        guard n > 3, rail.total > 0 else {
            return RoadTripHeadingRail(headings: [rail.heading(at: 0)], total: rail.total, cumulative: [0])
        }

        // 1. Raw bearings (±3 samples ≈ 30 m — noise-robust).
        var theta = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = mp[max(i - 3, 0)]
            let b = mp[min(i + 3, n - 1)]
            theta[i] = atan2(b.x - a.x, -(b.y - a.y))
        }

        // 2. Look-ahead blend, continuously engaged.
        if lookAheadBlend > 0, lookAheadFraction > 0 {
            for i in 0..<n {
                let targetArc = min(arc[i] + lookAheadFraction * rail.total, rail.total)
                var lo = 0, hi = n - 2
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if arc[mid + 1] < targetArc { lo = mid + 1 } else { hi = mid }
                }
                let j = min(lo + 1, n - 1)
                var d = theta[j] - theta[i]
                d = atan2(sin(d), cos(d))
                let t0 = blendThreshold
                let t1 = blendThreshold + max(blendRamp, 1e-9)
                let w = min(max((abs(d) - t0) / (t1 - t0), 0), 1)
                theta[i] += d * lookAheadBlend * (w * w * (3 - 2 * w))
            }
        }

        // 3. Circular Gaussian over arc length.
        if sigma > 0 {
            theta = circularGaussian(theta, arc: arc, sigma: sigma)
        }

        // 4. Double-pass rate limiter.
        theta = rateLimit(theta, arc: arc, maxTurnRate: maxTurnRate)

        return RoadTripHeadingRail(headings: theta, total: rail.total, cumulative: arc)
    }

    /// Gaussian smoothing of angles (sin/cos space) with an arc-length window.
    private static func circularGaussian(_ theta: [Double], arc: [Double], sigma: Double) -> [Double] {
        let n = theta.count
        var out = theta
        let w = 3 * sigma
        var lo = 0
        for i in 0..<n {
            let di = arc[i]
            while lo > 0 && di - arc[lo - 1] < w { lo -= 1 }
            while lo < i && arc[lo] < di - w { lo += 1 }
            var hi = lo
            while hi < n && arc[hi] <= di + w { hi += 1 }
            var sx = 0.0, sy = 0.0, wsum = 0.0
            for j in lo..<hi {
                let d = arc[j] - di
                let weight = exp(-(d * d) / (2 * sigma * sigma))
                sx += sin(theta[j]) * weight
                sy += cos(theta[j]) * weight
                wsum += weight
            }
            out[i] = atan2(sx / wsum, sy / wsum)
        }
        return out
    }

    /// Clamps |Δθ| between consecutive samples to `maxTurnRate × Δarc`.
    /// Forward pass then backward pass — the result is bounded everywhere and
    /// stays as close to the input as the cap allows.
    private static func rateLimit(_ theta: [Double], arc: [Double], maxTurnRate: Double) -> [Double] {
        let n = theta.count
        guard n > 1, maxTurnRate > 0 else { return theta }
        var out = theta
        for i in 1..<n {
            let cap = maxTurnRate * max(arc[i] - arc[i - 1], 0)
            var d = out[i] - out[i - 1]
            d = atan2(sin(d), cos(d))
            out[i] = out[i - 1] + min(max(d, -cap), cap)
        }
        // Unwrap to continuous values before the backward pass so clamping
        // works on the same number line.
        for i in 1..<n {
            while out[i] - out[i - 1] > .pi { out[i] -= 2 * .pi }
            while out[i] - out[i - 1] < -.pi { out[i] += 2 * .pi }
        }
        for i in stride(from: n - 2, through: 0, by: -1) {
            let cap = maxTurnRate * max(arc[i + 1] - arc[i], 0)
            var d = out[i] - out[i + 1]
            d = atan2(sin(d), cos(d))
            out[i] = out[i + 1] + min(max(d, -cap), cap)
        }
        return out
    }
}
