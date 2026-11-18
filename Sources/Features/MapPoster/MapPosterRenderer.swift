import MapKit
import UIKit

/// The span of time the poster covers.
enum MapPosterScope: String, CaseIterable, Identifiable, Sendable {
    case allTime
    case thisYear
    case lastYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTime: String(localized: "All time")
        case .thisYear: String(localized: "This year")
        case .lastYear: String(localized: "Last year")
        }
    }

    /// The year it covers, nil for all time.
    func year(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let current = calendar.component(.year, from: now)
        switch self {
        case .allTime: return nil
        case .thisYear: return current
        case .lastYear: return current - 1
        }
    }

    /// The map markers' filter: the year's first day to its last.
    func filter(now: Date = Date(), calendar: Calendar = .current) -> MapMarkerFilter {
        guard let year = year(now: now, calendar: calendar),
              let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else { return .all }
        var filter = MapMarkerFilter()
        filter.from = start
        filter.to = end
        return filter
    }
}

/// Draws the poster: a dark map of every place the photos were taken, a glow
/// for each, the title, the numbers (countries, cities, share of the world),
/// the furthest place from home, the flags.
enum MapPosterRenderer {

    static let background = UIColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1)
    static let accent = UIColor(red: 1, green: 0.72, blue: 0.27, alpha: 1)
    static let margin: CGFloat = 60
    /// Flags under the numbers, at most.
    static let maxFlags = 10

    /// Where the map sits on a poster of `format`.
    static func mapFrame(format: MosaicFormat) -> CGRect {
        let size = format.pixelSize
        let height: CGFloat = format == .story ? 1120 : size.height - 800
        return CGRect(x: margin, y: 290, width: size.width - margin * 2, height: max(height, 400))
    }

    /// The part of the world to show: every place with room around it, at
    /// the map's shape — the whole world once the places span half of it.
    static func mapRect(for coordinates: [CLLocationCoordinate2D], aspect: Double) -> MKMapRect {
        let world = MKMapRect.world
        guard !coordinates.isEmpty else { return world }
        let points = coordinates.map(MKMapPoint.init)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        // At least ~300 km across: a single town still shows its region.
        let minimumWidth = world.width / 130
        var width = max((maxX - minX) * 1.3, minimumWidth)
        var height = max((maxY - minY) * 1.3, minimumWidth / aspect)
        if width / height > aspect { height = width / aspect } else { width = height * aspect }
        if width > world.width * 0.5 {
            width = world.width
            height = min(width / aspect, world.height)
            width = height * aspect
        }
        let center = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let x = min(max(center.x - width / 2, world.minX), world.maxX - width)
        let y = min(max(center.y - height / 2, world.minY), world.maxY - height)
        return MKMapRect(x: x, y: y, width: width, height: height)
    }

    /// The satellite view of `rect` at `size` points: no labels to compete
    /// with the glows (darkened when drawn — `mapShade`).
    static func snapshot(of rect: MKMapRect, size: CGSize) async throws -> MKMapSnapshotter.Snapshot {
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        options.scale = 1
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        return try await MKMapSnapshotter(options: options).start()
    }

    /// Black over the satellite view: the glows read like city lights at night.
    static let mapShade = 0.55

    static func render(
        markers: [MapPhoto],
        stats: MapPosterStats,
        snapshot: MKMapSnapshotter.Snapshot?,
        format: MosaicFormat,
        title: String,
        subtitle: String,
        showsCredit: Bool
    ) -> UIImage {
        let size = format.pixelSize
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        return UIGraphicsImageRenderer(size: size, format: rendererFormat).image { context in
            let cg = context.cgContext
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let center = NSMutableParagraphStyle()
            center.alignment = .center

            // Title and subtitle.
            draw(title, font: .systemFont(ofSize: 76, weight: .heavy), color: .white,
                 in: CGRect(x: margin, y: 100, width: size.width - margin * 2, height: 96), paragraph: center)
            draw(subtitle, font: .systemFont(ofSize: 38, weight: .semibold), color: UIColor.white.withAlphaComponent(0.65),
                 in: CGRect(x: margin, y: 200, width: size.width - margin * 2, height: 50), paragraph: center)

            // The map and its glows.
            let frame = mapFrame(format: format)
            cg.saveGState()
            UIBezierPath(roundedRect: frame, cornerRadius: 28).addClip()
            if let snapshot {
                snapshot.image.draw(in: frame)
                UIColor.black.withAlphaComponent(mapShade).setFill()
                context.fill(frame, blendMode: .normal)
            } else {
                UIColor(white: 0.12, alpha: 1).setFill()
                context.fill(frame)
            }
            var seen = Set<Int>()
            var dots: [CGPoint] = []
            for marker in markers {
                guard let snapshot else { break }
                let p = snapshot.point(for: marker.coordinate)
                let point = CGPoint(x: frame.minX + p.x, y: frame.minY + p.y)
                guard frame.contains(point) else { continue }
                // One dot per 4-pixel square: thousands of photos of one street stay one glow.
                let key = Int(point.x / 4) * 10_000 + Int(point.y / 4)
                if seen.insert(key).inserted { dots.append(point) }
            }
            // A wide faint halo, a tighter one, then the bright core.
            for (radius, alpha) in [(20.0, 0.10), (11.0, 0.22)] {
                accent.withAlphaComponent(alpha).setFill()
                for dot in dots { cg.fillEllipse(in: CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2)) }
            }
            UIColor(red: 1, green: 0.9, blue: 0.7, alpha: 1).setFill()
            for dot in dots { cg.fillEllipse(in: CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10)) }
            cg.restoreGState()

            // The numbers.
            var y = frame.maxY + 50
            let columns: [(String, String)] = [
                (stats.countryCount.formatted(), String(localized: "Countries")),
                (stats.cityCount.formatted(), String(localized: "Cities")),
                (stats.worldShare.formatted(.percent.precision(.fractionLength(0...1))), String(localized: "Of the world")),
            ]
            let columnWidth = (size.width - margin * 2) / CGFloat(columns.count)
            for (index, column) in columns.enumerated() {
                let x = margin + CGFloat(index) * columnWidth
                draw(column.0, font: .systemFont(ofSize: 84, weight: .heavy), color: accent,
                     in: CGRect(x: x, y: y, width: columnWidth, height: 100), paragraph: center)
                draw(column.1, font: .systemFont(ofSize: 30, weight: .semibold), color: UIColor.white.withAlphaComponent(0.7),
                     in: CGRect(x: x, y: y + 100, width: columnWidth, height: 40), paragraph: center)
            }
            y += 170

            if let furthest = stats.furthest, furthest.kilometers >= 1, let label = furthest.shortLabel {
                let distance = Measurement(value: furthest.kilometers, unit: UnitLength.kilometers)
                    .formatted(.measurement(width: .abbreviated, usage: .road))
                draw(String(localized: "Furthest from home: \(label) · \(distance)"),
                     font: .systemFont(ofSize: 34, weight: .semibold), color: .white,
                     in: CGRect(x: margin, y: y, width: size.width - margin * 2, height: 46), paragraph: center)
                y += 70
            }

            let flags = stats.countries.compactMap { MapPosterStats.flag(forCountry: $0.name) }.prefix(maxFlags)
            if !flags.isEmpty {
                draw(flags.joined(separator: " "), font: .systemFont(ofSize: 64), color: .white,
                     in: CGRect(x: margin, y: y, width: size.width - margin * 2, height: 86), paragraph: center)
            }

            if showsCredit {
                let text = String(localized: "Made with Swimmich") as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: UIColor.white
                ]
                let textSize = text.size(withAttributes: attributes)
                let pill = CGRect(
                    x: (size.width - textSize.width) / 2 - 24, y: size.height - textSize.height - 64,
                    width: textSize.width + 48, height: textSize.height + 20
                )
                UIColor.white.withAlphaComponent(0.12).setFill()
                UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
                text.draw(at: CGPoint(x: pill.minX + 24, y: pill.minY + 10), withAttributes: attributes)
            }
        }
    }

    private static func draw(_ text: String, font: UIFont, color: UIColor, in rect: CGRect, paragraph: NSParagraphStyle) {
        (text as NSString).draw(
            with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph], context: nil
        )
    }
}
