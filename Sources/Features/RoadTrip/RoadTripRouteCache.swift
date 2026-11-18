import Foundation

/// The driving routes found so far, on disk (Caches): a trip opened again
/// gets its roads at once, the same ones, and never meets MapKit's
/// throttling. Keyed by the two ends to the meter.
enum RoadTripRouteCache {

    private static let directory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("RoadTripRoutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The file of the route from `from` to `to` (internal for the tests).
    static func fileURL(from: RoutePoint, to: RoutePoint) -> URL? {
        func key(_ point: RoutePoint) -> String {
            String(format: "%.5f_%.5f", point.latitude, point.longitude)
        }
        return directory?.appendingPathComponent("\(key(from))__\(key(to)).json")
    }

    static func route(from: RoutePoint, to: RoutePoint) -> [RoutePoint]? {
        guard let url = fileURL(from: from, to: to),
              let data = try? Data(contentsOf: url),
              let pairs = try? JSONDecoder().decode([[Double]].self, from: data),
              pairs.count >= 2, pairs.allSatisfy({ $0.count == 2 }) else { return nil }
        return pairs.map { RoutePoint(latitude: $0[0], longitude: $0[1]) }
    }

    static func store(_ route: [RoutePoint], from: RoutePoint, to: RoutePoint) {
        guard route.count >= 2, let url = fileURL(from: from, to: to),
              let data = try? JSONEncoder().encode(route.map { [$0.latitude, $0.longitude] }) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
