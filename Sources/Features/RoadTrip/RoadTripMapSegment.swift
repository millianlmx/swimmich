import SwiftUI
import MapKit

/// Map leg of the live preview: a real 3D MapKit navigation-style chase camera
/// — pitched low toward the horizon, heading following the road, street-level
/// zoom — with the 3D car riding the route ahead of it. The camera geometry is
/// shared with the export (`RoadTripDriveCamera`), which simulates the same
/// driving perspective from 2D snapshots, so the car's position and motion
/// match the exported film.
///
/// Transitions also match the export: the outgoing photo fades out over the
/// first moments of the leg, and the arrival dive (pin pop + destination
/// thumbnail growing to full screen) plays over the leg's tail.
struct RoadTripMapSegment: View {
    let travel: RoadTripTimeline.Travel
    let localTime: TimeInterval
    var token: String?
    /// First photo of the destination stop — dives up from the arrival pin.
    var divePhoto: RoadTripPhotoSource?
    /// Last photo of the previous stop — fades out over the map's opening.
    var outgoingPhoto: RoadTripPhotoSource?

    /// The leg's drawn route and the last camera applied. A reference: `body`
    /// updates it every frame, which a `@State` value cannot take (a state
    /// change during a view update is undefined behavior).
    @State private var memo = RoadTripMapMemo()

    var body: some View {
        let timing = RoadTripTravelTiming.frame(travel: travel, localTime: localTime)
        let bearing = RoadTripDriveCamera.carHeading(travel: travel, localTime: localTime)
        let state = RoadTripDriveCamera.cameraState(travel: travel, localTime: localTime)

        ZStack(alignment: .top) {
            mapView(
                car: timing.carCoordinate,
                camera: state.cameraCoordinate,
                bearing: bearing,
                heading: state.bearing,
                lookAhead: state.lookAheadMeters,
                carFraction: timing.routeDrawnFraction
            )
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func mapView(car: RoutePoint, camera: RoutePoint, bearing: Double, heading: Double, lookAhead: Double, carFraction: Double) -> some View {
        // Street-level chase: distance tracks the look-ahead (constant per
        // leg), heading follows the smoothed road direction, pitched low.
        let cameraPosition = chaseCamera(center: camera.coordinate, heading: heading, lookAhead: lookAhead)
        let drawn = memo.route(for: travel)
        let traveled = RoadTripMapMemo.traveledParts(drawn, carFraction: carFraction, car: car.coordinate)

        MapReader { proxy in
            GeometryReader { geo in
                ZStack {
                    Map(position: Binding(get: { .camera(cameraPosition) }, set: { _ in })) {
                        // The whole road, then the part already driven over it.
                        // Only the short tail behind the car changes every
                        // frame: the long polylines change a few dozen times
                        // per leg, never with thousands of points.
                        if drawn.coordinates.count >= 2 {
                            MapPolyline(coordinates: drawn.coordinates)
                                .stroke(.black.opacity(0.35), lineWidth: 9)
                            MapPolyline(coordinates: drawn.coordinates)
                                .stroke(.gray.opacity(0.6), lineWidth: 5)
                        }
                        if traveled.body.count >= 2 {
                            MapPolyline(coordinates: traveled.body)
                                .stroke(routeBlue.opacity(0.9), lineWidth: 5)
                        }
                        if traveled.tail.count >= 2 {
                            MapPolyline(coordinates: traveled.tail)
                                .stroke(routeBlue.opacity(0.9), lineWidth: 5)
                        }
                        Annotation("", coordinate: car.coordinate) {
                            chaseCar(bearing: bearing, heading: heading, lookAhead: lookAhead)
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
                    .id(travel.fromClusterID + travel.toClusterID)

                    overlayMarkers(proxy: proxy, canvas: geo.size)
                }
            }
        }
    }

    /// Start pulse, arrival pin, dive thumbnail and outgoing-photo fade —
    /// projected onto the map via `MapReader` so they follow the live camera.
    @ViewBuilder
    private func overlayMarkers(proxy: MapProxy, canvas: CGSize) -> some View {
        let dive = RoadTripSegue.diveProgress(localTime: localTime, legDuration: travel.duration)

        if let start = travel.route.first, let p = clamp(proxy.convert(start.coordinate, to: .local), canvas: canvas) {
            let pulse = 0.5 + 0.5 * sin(2 * .pi * localTime * 1.2)
            Circle()
                .fill(.white.opacity(0.25 + 0.3 * pulse))
                .frame(width: 32 + pulse * 10, height: 32 + pulse * 10)
                .position(p)
                .allowsHitTesting(false)
            Circle()
                .fill(.white)
                .frame(width: 20, height: 20)
                .position(p)
                .allowsHitTesting(false)
        }

        if dive > 0, let destination = travel.route.last, let p = clamp(proxy.convert(destination.coordinate, to: .local), canvas: canvas) {
            let pop = RoadTripSegue.pinPop(dive)
            ZStack {
                Color.black.opacity(RoadTripSegue.mapFade(dive) * 0.92)
                Circle()
                    .fill(.white)
                    .frame(width: 32 * pop, height: 32 * pop)
                    .position(p)
                Circle()
                    .fill(Color(red: 0.95, green: 0.25, blue: 0.22))
                    .frame(width: 20 * pop, height: 20 * pop)
                    .position(p)
                if let divePhoto {
                    let size = CGSize(width: canvas.width * RoadTripSegue.thumbSizeFraction,
                                      height: canvas.width * RoadTripSegue.thumbSizeFraction * 0.75)
                    let rect = RoadTripSegue.thumbnailRect(pinCenter: p, pinSize: size, canvas: canvas, dive: dive)
                    RoadTripPhoto(source: divePhoto, token: token)
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(RoundedRectangle(cornerRadius: dive >= 0.99 ? 0 : 18 * (1 - dive), style: .continuous))
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(RoadTripSegue.thumbnailAlpha(dive))
                }
            }
            .allowsHitTesting(false)
        }

        if let outgoingPhoto {
            let alpha = RoadTripSegue.outgoingPhotoAlpha(localTime: localTime)
            if alpha > 0 {
                RoadTripPhoto(source: outgoingPhoto, token: token)
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
                    .opacity(alpha)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Clamps a projected map point into the canvas (with the same margins as
    /// the export) so the markers never pop at the screen edge.
    private func clamp(_ point: CGPoint?, canvas: CGSize) -> CGPoint? {
        guard let point, canvas.width > 0 else { return nil }
        return CGPoint(
            x: min(max(point.x, canvas.width * 0.12), canvas.width * 0.88),
            y: min(max(point.y, canvas.height * 0.15), canvas.height * 0.85)
        )
    }

    private var routeBlue: Color { Color(red: 0.10, green: 0.42, blue: 0.90) }

    /// Builds the chase camera, but only updates it when it moved/turned enough
    /// to matter (~5 m / 0.25°) — otherwise MapKit re-projects and stutters.
    /// The pitch blends from street (60°) to top-down (0°) as the leg zooms
    /// out, matching the export's aerial trapezoid.
    private func chaseCamera(center: CLLocationCoordinate2D, heading: Double, lookAhead: Double) -> MapCamera {
        let distance = min(max(lookAhead * 2.0, RoadTripDriveCamera.zoomInMeters * 2.0), RoadTripDriveCamera.maxFitLookAheadMeters * 2.0)
        let pitch = 60.0 * (1.0 - RoadTripDriveCamera.aerialBlend(lookAheadMeters: lookAhead))
        let candidate = MapCamera(
            centerCoordinate: center,
            distance: distance,
            heading: heading * 180 / .pi,
            pitch: pitch
        )
        guard let last = memo.camera else {
            memo.camera = candidate
            return candidate
        }
        let dLat = abs(last.centerCoordinate.latitude - candidate.centerCoordinate.latitude)
        let dLon = abs(last.centerCoordinate.longitude - candidate.centerCoordinate.longitude)
        let dHead = abs(last.heading - candidate.heading)
        let dDist = abs(last.distance - candidate.distance)
        let moved = dLat > 0.00005 || dLon > 0.00005
        let turned = dHead > 0.25
        let zoomed = dDist > 25
        guard moved || turned || zoomed else { return last }
        memo.camera = candidate
        return candidate
    }

    /// Rear 3/4 view of the 3D car with a soft ground shadow, anchored so its
    /// ground contact sits on the map coordinate. Map annotations stay
    /// screen-aligned, so the sprite's yaw compensates the perspective
    /// compression of the RELATIVE bearing (true bearing minus the camera
    /// heading) — nose + body end up exactly on the road as seen on screen.
    private func chaseCar(bearing: Double, heading: Double, lookAhead: Double) -> some View {
        let contact = RoadTripCar3D.chaseContactFraction
        let scale = RoadTripDriveCamera.carSpriteScale(lookAheadMeters: lookAhead)
        let height: CGFloat = 164 * scale
        let yaw = RoadTripCar3D.chaseYaw(forScreenAngle: bearing - heading)
        let frameYaw = RoadTripCar3D.chaseNearestYaw(yaw)
        return ZStack {
            Ellipse()
                .fill(.black.opacity(0.26))
                .frame(width: 120 * scale, height: 22 * scale)
                .blur(radius: 3)
                .offset(y: 4 * scale)
            Image(decorative: RoadTripCar3D.chaseSprite(forBearing: frameYaw), scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 164 * scale, height: height)
                .offset(y: (0.5 - contact) * height)
                .rotationEffect(.radians(yaw - frameYaw))
        }
    }
}

/// Per-leg memory of `RoadTripMapSegment` that its `body` updates without
/// invalidating the view: the route as drawn, and the last camera applied (the
/// dead zone that keeps MapKit from re-projecting for sub-meter moves).
final class RoadTripMapMemo {

    /// A leg's route as drawn, with each point's arc fraction.
    struct DrawnRoute {
        let coordinates: [CLLocationCoordinate2D]
        let fractions: [Double]
    }

    /// Ceiling on the drawn route. MapKit rebuilds a polyline whose content
    /// changed; the old code split a route densified to 40 m (tens of
    /// thousands of points on a long leg) into two new polylines every frame.
    static let maxDrawnPoints = 1_200
    /// The driven part's long body moves in this many steps per leg; the
    /// short tail from its end to the car follows every frame.
    static let traveledSteps = 48

    private var key = ""
    private var drawn = DrawnRoute(coordinates: [], fractions: [])
    var camera: MapCamera?

    /// The drawn route of `travel`, built once per leg.
    func route(for travel: RoadTripTimeline.Travel) -> DrawnRoute {
        let key = "\(travel.fromClusterID)>\(travel.toClusterID)|\(travel.route.count)"
        if key != self.key {
            self.key = key
            camera = nil
            drawn = Self.drawnRoute(travel.route)
        }
        return drawn
    }

    /// `route` resampled to ~40 m (smooth at street zoom), the spacing widened
    /// on long legs, then thinned so it never exceeds `maxDrawnPoints`.
    static func drawnRoute(_ route: [RoutePoint]) -> DrawnRoute {
        guard route.count >= 2 else {
            return DrawnRoute(coordinates: route.map(\.coordinate), fractions: route.map { _ in 0 })
        }
        let cumulative = RoadTripTravelTiming.cumulativeLengths(route)
        let total = cumulative.last ?? 0
        let fractions = cumulative.map { total > 0 ? $0 / total : 0 }
        let spacing = max(40, total / Double(maxDrawnPoints))
        let dense = RoadTripDriveCamera.densified(route: route, fractions: fractions, spacing: spacing)
        var coordinates = dense.points.map(\.coordinate)
        var drawnFractions = dense.fractions
        if coordinates.count > maxDrawnPoints {
            let step = Int((Double(coordinates.count) / Double(maxDrawnPoints - 1)).rounded(.up))
            var thinned: [CLLocationCoordinate2D] = []
            var thinnedFractions: [Double] = []
            for i in Swift.stride(from: 0, to: coordinates.count, by: step) {
                thinned.append(coordinates[i])
                thinnedFractions.append(drawnFractions[i])
            }
            if thinnedFractions.last != drawnFractions.last, let lastPoint = coordinates.last, let lastFraction = drawnFractions.last {
                thinned.append(lastPoint)
                thinnedFractions.append(lastFraction)
            }
            coordinates = thinned
            drawnFractions = thinnedFractions
        }
        return DrawnRoute(coordinates: coordinates, fractions: drawnFractions)
    }

    /// The driven part of `route` up to `carFraction`, in two polylines: a
    /// body that only grows by whole steps (`traveledSteps` per leg), and the
    /// short tail from the end of that body to the car.
    static func traveledParts(
        _ route: DrawnRoute,
        carFraction: Double,
        car: CLLocationCoordinate2D
    ) -> (body: [CLLocationCoordinate2D], tail: [CLLocationCoordinate2D]) {
        let n = route.coordinates.count
        guard n >= 2, route.fractions.count == n else { return ([], []) }
        // Last drawn point at or behind the car (binary search on fractions).
        var lo = 0, hi = n - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if route.fractions[mid] <= carFraction { lo = mid } else { hi = mid - 1 }
        }
        let behind = lo
        let quantum = max(1, n / traveledSteps)
        let bodyEnd = (behind / quantum) * quantum
        let body = bodyEnd >= 1 ? Array(route.coordinates[0...bodyEnd]) : []
        let tail = Array(route.coordinates[bodyEnd...behind]) + [car]
        return (body, tail)
    }
}
