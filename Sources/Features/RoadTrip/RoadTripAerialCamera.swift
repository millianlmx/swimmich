import CoreGraphics
import CoreLocation
import MapKit
import UIKit

/// A located stop of the trip, as the map shows it.
struct RoadTripMapStop: Equatable, Sendable {
    let clusterID: String
    let coordinate: RoutePoint

    /// The located stops of `clusters`, in film order.
    static func stops(of clusters: [RoadTripCluster]) -> [RoadTripMapStop] {
        clusters.compactMap { cluster in
            guard let latitude = cluster.latitude, let longitude = cluster.longitude else { return nil }
            return RoadTripMapStop(clusterID: cluster.id, coordinate: RoutePoint(latitude: latitude, longitude: longitude))
        }
    }
}

/// What the film's map shows at an instant.
enum RoadTripMapShot: Equatable {
    /// The hook: the whole trip, pushing in, its road drawn faint.
    case opening(progress: Double)
    /// The leg at `segmentIndex`, `localTime` into it (0 while the pictures
    /// before it play: the map is set up under them).
    case leg(segmentIndex: Int, localTime: TimeInterval)
    /// The finale: the whole trip, its road drawn, a photo on every stop.
    case ending(progress: Double)

    /// The shot at film time `time` (clamped to the film).
    static func at(_ time: TimeInterval, in timeline: RoadTripTimeline) -> RoadTripMapShot {
        let clamped = min(max(time, 0), timeline.totalDuration)
        let (index, local) = timeline.localTime(at: clamped)
        switch timeline.segments[index] {
        case .opening(let duration):
            return .opening(progress: local / max(duration, 0.001))
        case .travel:
            return .leg(segmentIndex: index, localTime: local)
        case .ending(let duration):
            return .ending(progress: local / max(duration, 0.001))
        case .slideshow:
            // Under the pictures: the next leg waits on its start, or the
            // finale once the last leg is behind.
            for next in (index + 1)..<timeline.segments.count {
                if case .travel = timeline.segments[next] {
                    return .leg(segmentIndex: next, localTime: 0)
                }
            }
            return .ending(progress: 0)
        }
    }
}

/// The film's map camera: north-up, straight down over satellite imagery —
/// the look of the travel-map videos people share — and the trip's road drawn
/// in a bright line behind the car.
///
/// A leg opens close on its start, pulls back to show the whole road while the
/// car crosses it, and pushes in on the destination for the arrival dive. The
/// opening pushes in on the whole trip; the ending pulls back onto it.
///
/// Shared by the live player (an `MKMapView` shown that rect) and the export
/// (crops of satellite snapshots), so both frame the same ground at the same
/// instant. Rects are aspect-correct for the canvas (`aspect` = width / height).
enum RoadTripAerialCamera {

    /// Margin around what a shot frames, each side, as a fraction of the span.
    static let fitMargin = 0.22
    /// Narrowest ground a shot shows (meters across): a leg across town still
    /// shows where it is.
    static let minimumSpanMeters = 3_000.0
    /// How close the start and the end of a leg are framed, as a fraction of
    /// the whole leg's frame.
    static let closeUpFactor = 0.5
    /// Fraction of the leg spent pulling back from the start (and pushing in
    /// on the destination).
    static let zoomRampFraction = 0.35
    /// The opening pushes in from this much wider than the trip.
    static let openingPullFactor = 1.18
    /// The ending pulls back onto the trip from this much closer.
    static let endingPushFactor = 0.86

    // MARK: Shots

    /// The map rect of `shot`, or nil when the trip has nothing located.
    static func rect(
        for shot: RoadTripMapShot,
        timeline: RoadTripTimeline,
        stops: [RoadTripMapStop],
        aspect: Double
    ) -> MKMapRect? {
        switch shot {
        case .opening(let progress):
            guard let overview = overview(timeline: timeline, stops: stops, aspect: aspect) else { return nil }
            return openingRect(overview: overview, progress: progress)
        case .ending(let progress):
            guard let overview = overview(timeline: timeline, stops: stops, aspect: aspect) else { return nil }
            return endingRect(overview: overview, progress: progress)
        case .leg(let index, let localTime):
            guard timeline.segments.indices.contains(index),
                  case .travel(let travel) = timeline.segments[index],
                  travel.route.count >= 2 else { return nil }
            return legRect(travel: travel, localTime: localTime, aspect: aspect)
        }
    }

    static func openingRect(overview: MKMapRect, progress: Double) -> MKMapRect {
        let eased = easeOut(progress)
        return scaled(overview, by: openingPullFactor + (1 - openingPullFactor) * eased)
    }

    static func endingRect(overview: MKMapRect, progress: Double) -> MKMapRect {
        let eased = easeOut(progress)
        return scaled(overview, by: endingPushFactor + (1 - endingPushFactor) * eased)
    }

    /// The whole trip: every stop and every road.
    static func overview(timeline: RoadTripTimeline, stops: [RoadTripMapStop], aspect: Double) -> MKMapRect? {
        var points = stops.map { MKMapPoint($0.coordinate.coordinate) }
        for segment in timeline.segments {
            guard case .travel(let travel) = segment else { continue }
            points.append(contentsOf: sampled(travel.route, count: 200))
        }
        return fit(points, aspect: aspect)
    }

    /// The leg's frame at `localTime`: close on the car at both ends, the
    /// whole road through the middle. The car is always inside it.
    static func legRect(travel: RoadTripTimeline.Travel, localTime: TimeInterval, aspect: Double) -> MKMapRect {
        let full = legFrame(travel, aspect: aspect)
        let progress = min(max(localTime / max(travel.duration, 0.001), 0), 1)
        let car = RoadTripTravelTiming.frame(travel: travel, localTime: localTime).carCoordinate
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(car.latitude)
        let closeWidth = min(max(full.width * closeUpFactor, minimumSpanMeters * pointsPerMeter), full.width)
        let close = rect(center: MKMapPoint(car.coordinate), width: closeWidth, aspect: aspect)
        return lerp(close, full, wideness(progress))
    }

    /// 0 at the leg's ends (close on the car), 1 through its middle.
    static func wideness(_ progress: Double) -> Double {
        let up = KenBurnsRecipe.smoothstep(min(max(progress / zoomRampFraction, 0), 1))
        let down = KenBurnsRecipe.smoothstep(min(max((1 - progress) / zoomRampFraction, 0), 1))
        return min(up, down)
    }

    /// Every rect the leg's camera shows, in one aspect-correct rect: what
    /// the export snapshots once for the leg.
    static func legEnvelope(travel: RoadTripTimeline.Travel, aspect: Double) -> MKMapRect {
        var union = legRect(travel: travel, localTime: 0, aspect: aspect)
        let steps = 48
        for step in 1...steps {
            let time = travel.duration * Double(step) / Double(steps)
            union = union.union(legRect(travel: travel, localTime: time, aspect: aspect))
        }
        return aspectFilled(union, aspect: aspect)
    }

    // MARK: Geometry

    /// The aspect-correct rect framing `points` with the margin, never
    /// narrower than `minimumSpanMeters`.
    static func fit(_ points: [MKMapPoint], aspect: Double) -> MKMapRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let center = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
        let grow = 1 + 2 * fitMargin
        let width = max((maxX - minX) * grow, (maxY - minY) * grow * aspect, minimumSpanMeters * pointsPerMeter)
        return rect(center: center, width: width, aspect: aspect)
    }

    static func rect(center: MKMapPoint, width: Double, aspect: Double) -> MKMapRect {
        let w = max(width, 1)
        let h = w / max(aspect, 0.01)
        return MKMapRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    static func scaled(_ rect: MKMapRect, by factor: Double) -> MKMapRect {
        let aspect = rect.size.width / max(rect.size.height, 1e-9)
        return self.rect(center: MKMapPoint(x: rect.midX, y: rect.midY), width: rect.size.width * factor, aspect: aspect)
    }

    static func lerp(_ a: MKMapRect, _ b: MKMapRect, _ t: Double) -> MKMapRect {
        MKMapRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.size.width + (b.size.width - a.size.width) * t,
            height: a.size.height + (b.size.height - a.size.height) * t
        )
    }

    /// `rect` grown to `aspect` around its center.
    static func aspectFilled(_ rect: MKMapRect, aspect: Double) -> MKMapRect {
        let width = max(rect.size.width, rect.size.height * aspect)
        return self.rect(center: MKMapPoint(x: rect.midX, y: rect.midY), width: width, aspect: aspect)
    }

    /// Where `point` lands on a canvas showing `rect` (y down).
    static func project(_ point: MKMapPoint, in rect: MKMapRect, canvas: CGSize) -> CGPoint {
        CGPoint(
            x: (point.x - rect.minX) / max(rect.size.width, 1e-9) * canvas.width,
            y: (point.y - rect.minY) / max(rect.size.height, 1e-9) * canvas.height
        )
    }

    /// Decelerating ease (0→1).
    static func easeOut(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    /// The car's compass heading (radians, clockwise from north): on a
    /// north-up map, its angle on screen.
    static func carHeading(travel: RoadTripTimeline.Travel, localTime: TimeInterval) -> Double {
        RoadTripDriveCamera.carHeading(travel: travel, localTime: localTime)
    }

    // MARK: Caches

    private final class RectBox: NSObject {
        let rect: MKMapRect
        init(_ rect: MKMapRect) { self.rect = rect }
    }

    private static let legFrameCache = NSCache<NSString, RectBox>()

    /// The whole leg framed (cached: every frame reads it).
    static func legFrame(_ travel: RoadTripTimeline.Travel, aspect: Double) -> MKMapRect {
        let first = travel.route.first, last = travel.route.last
        let key = "\(aspect)|\(travel.route.count)|\(first?.latitude ?? 0),\(first?.longitude ?? 0)|\(last?.latitude ?? 0),\(last?.longitude ?? 0)" as NSString
        if let cached = legFrameCache.object(forKey: key) { return cached.rect }
        let points = travel.route.map { MKMapPoint($0.coordinate) }
        let rect = fit(points, aspect: aspect) ?? MKMapRect.world
        legFrameCache.setObject(RectBox(rect), forKey: key)
        return rect
    }

    /// At most `count` points of `route`, its ends included.
    static func sampled(_ route: [RoutePoint], count: Int) -> [MKMapPoint] {
        guard route.count > count, count >= 2 else { return route.map { MKMapPoint($0.coordinate) } }
        return (0..<count).map { i in
            let index = Int((Double(i) * Double(route.count - 1) / Double(count - 1)).rounded())
            return MKMapPoint(route[index].coordinate)
        }
    }
}

/// The colors and widths of the film's map, shared by the live map and the
/// export (widths as fractions of the canvas width, so the line looks the same
/// on a phone screen and in a 1080 × 1920 video).
enum RoadTripMapStyle {
    /// The trip's line: a warm yellow that reads over sea, forest and town.
    static let route = UIColor(red: 1.0, green: 0.80, blue: 0.16, alpha: 1)
    static let routeGlow = UIColor(red: 1.0, green: 0.62, blue: 0.10, alpha: 0.35)
    static let casing = UIColor.white
    static let pin = UIColor(red: 1.0, green: 0.26, blue: 0.36, alpha: 1)

    static let glowWidth = 0.050
    static let casingWidth = 0.028
    static let lineWidth = 0.016
    /// The opening's road: a preview of what is coming.
    static let previewAlpha = 0.45

    /// Stop pin: white ring, colored dot.
    static let pinRingDiameter = 0.060
    static let pinDotDiameter = 0.036
    /// The car sprite (the car itself fills about 70 % of it): ~15 % of the
    /// frame's width, big enough to read as a Tesla over the imagery.
    static let carSpriteSize = 0.21
    /// The ending's photo pins.
    static let photoPinDiameter = 0.17
    static let photoPinBorder = 0.008

    /// The stem joining a photo pin pushed off its stop back to the stop.
    static let photoPinStemWidth = 0.006

    /// Where the ending's photo pins sit (screen points, y down): each one
    /// above its stop pin, then pushed apart until no two overlap and kept
    /// inside the canvas — stops a few kilometers apart (Sóller, Fornalutx,
    /// Escorca) no longer pile their photos on each other. Deterministic, so
    /// the preview and the export lay them out alike.
    static func photoPinCenters(pins: [CGPoint], diameter: CGFloat, canvas: CGSize) -> [CGPoint] {
        guard !pins.isEmpty, diameter > 0 else { return [] }
        let homes = pins.map { CGPoint(x: $0.x, y: $0.y - diameter * 0.62) }
        var centers = homes
        let spacing = diameter * 1.06
        let margin = diameter * 0.5 + canvas.width * 0.02
        for _ in 0..<60 {
            var moved = false
            for i in centers.indices {
                for j in centers.indices where j > i {
                    var dx = centers[j].x - centers[i].x
                    var dy = centers[j].y - centers[i].y
                    var distance = (dx * dx + dy * dy).squareRoot()
                    guard distance < spacing else { continue }
                    if distance < 0.001 {
                        // Same spot: split them sideways, in film order.
                        dx = 1; dy = 0; distance = 1
                    }
                    let push = (spacing - distance) / 2
                    let ux = dx / distance, uy = dy / distance
                    centers[i].x -= ux * push; centers[i].y -= uy * push
                    centers[j].x += ux * push; centers[j].y += uy * push
                    moved = true
                }
            }
            for i in centers.indices {
                // A weak pull home keeps every photo near its stop.
                centers[i].x += (homes[i].x - centers[i].x) * 0.02
                centers[i].y += (homes[i].y - centers[i].y) * 0.02
                if canvas.width > 2 * margin {
                    centers[i].x = min(max(centers[i].x, margin), canvas.width - margin)
                }
                if canvas.height > 2 * margin {
                    centers[i].y = min(max(centers[i].y, margin), canvas.height - margin)
                }
            }
            if !moved { break }
        }
        return centers
    }

    /// Whether the photo pin at `center` left its place above `pin` far
    /// enough to need a stem back to it.
    static func photoPinNeedsStem(center: CGPoint, pin: CGPoint, diameter: CGFloat) -> Bool {
        let home = CGPoint(x: pin.x, y: pin.y - diameter * 0.62)
        let dx = center.x - home.x, dy = center.y - home.y
        return (dx * dx + dy * dy).squareRoot() > diameter * 0.12
    }

    /// Scale of the photo pin of stop `index` (of `count`): the pins pop in one
    /// after the other over the ending's first half, 0 → a little over 1 → 1.
    static func photoPinPop(index: Int, count: Int, endingProgress: Double) -> Double {
        let start = count > 1 ? 0.45 * Double(index) / Double(count - 1) : 0
        let t = min(max((endingProgress - start) / 0.12, 0), 1)
        // Ease-out-back: overshoots then settles on 1.
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
}
