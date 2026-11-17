import CoreLocation
import Foundation

/// A leg's road as the live map draws it.
enum RoadTripRouteDrawing {

    /// A leg's route as drawn, with each point's arc fraction.
    struct DrawnRoute {
        let coordinates: [CLLocationCoordinate2D]
        let fractions: [Double]
    }

    /// Ceiling on the drawn route: a polyline densified to 40 m along a long
    /// leg ran to tens of thousands of points.
    static let maxDrawnPoints = 1_200

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
}
