import SwiftUI

// MARK: - ImmichMark
//
// The app's mark: a lens. A barrel band cut into five arcs, five iris slits,
// and an opening whose *negative space* is the petal motif — five rounded
// lobes with crisp valleys. Five-fold rotation and photography are the family
// it lives in; the petals are a pupil, the colour is one sweep, and the blades
// are cut where the petal valleys meet the barrel.
//
// Every contour is a formula — circles, radial wedges, and one sampled polar
// curve — not traced data, so the mark is retuned by editing the numbers in
// `ImmichMarkGeometry` and nothing else. No Apple asset, no upstream logo, and
// nothing that has to be licensed: the shape is ours, and the palette is
// `ImmichLogoColors`, two colours derived from the app's accent.
//
// Read it at the two sizes it ships at: 24 pt beside the wordmark in
// `ImmichLogo` (the app bar of nine screens) and 40 pt in the onboarding
// badge. The barrel and the slits fade below 40 pt — deliberately: at 24 pt the
// mark is a disc with a petal-shaped pupil, which is legible; the blades appear
// as it grows, which is what keeps the 1024 pt icon interesting.

/// The mark's geometry, in units of the disc's radius.
enum ImmichMarkGeometry {
    /// Barrel band: the outer ring, cut into one arc per blade.
    static let barrelOuter: CGFloat = 1.00
    static let barrelInner: CGFloat = 0.84
    /// Air between the barrel and the iris plate that carries the opening.
    static let gap: CGFloat = 0.05
    /// The opening: radius at a valley, petal height above it, and how square
    /// the valleys are (1 = a plain cosine, higher = crisper petals).
    static let openingBase: CGFloat = 0.48
    static let openingRise: CGFloat = 0.16
    static let openingSharpness: CGFloat = 1.6
    static let openingSamples = 240
    /// The iris slits: width at the rim, the air they leave around the
    /// opening, and how many blades cut the barrel.
    static let slitWidth: CGFloat = 0.06
    static let slitMargin: CGFloat = 0.04
    static let blades = 5
    /// One petal points straight up; the valleys sit half a blade further on.
    static let petalPhase = -CGFloat.pi / 2
    static let valleyPhase = petalPhase + CGFloat.pi / 5
}

struct ImmichMarkShape: Shape {
    /// The mark is the same drawing at every size, so the path is built once, in
    /// the unit circle, and mapped into whatever rect the shape is given.
    static let unitPath: Path = {
        var path = Path()
        let centre = CGPoint.zero
        let radius: CGFloat = 1

        // Barrel band: an outer disc with the iris plate's circle taken out of
        // it, then the plate itself, one gap wider.
        path.addEllipse(in: circleRect(centre, radius * ImmichMarkGeometry.barrelOuter))
        let barrelInner = radius * ImmichMarkGeometry.barrelInner
        path.addEllipse(in: circleRect(centre, barrelInner))
        let plate = barrelInner - radius * ImmichMarkGeometry.gap
        path.addEllipse(in: circleRect(centre, plate))

        // The opening: the petal motif, as a closed curve through a polar
        // profile, smoothed by Catmull-Rom.
        addSmoothClosed(openingPoints(centre: centre, radius: radius), to: &path)

        // The blades: each cut runs in two pieces, one per ring, so the air
        // between the barrel and the plate stays air.
        let inner = radius * (ImmichMarkGeometry.openingBase + ImmichMarkGeometry.openingRise
                              + ImmichMarkGeometry.slitMargin)
        let halfWidth = radius * ImmichMarkGeometry.slitWidth / 2
        for blade in 0..<ImmichMarkGeometry.blades {
            let angle = ImmichMarkGeometry.valleyPhase + CGFloat(blade) * 2 * .pi
                / CGFloat(ImmichMarkGeometry.blades)
            addSlit(from: inner, to: plate, halfWidth: halfWidth, at: angle, centre: centre, to: &path)
            addSlit(from: barrelInner, to: radius * ImmichMarkGeometry.barrelOuter,
                    halfWidth: halfWidth, at: angle, centre: centre, to: &path)
        }
        return path
    }()

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let transform = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: side / 2, y: side / 2)
        return Self.unitPath.applying(transform)
    }

    private static func circleRect(_ centre: CGPoint, _ radius: CGFloat) -> CGRect {
        CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius)
    }

    /// r(θ) for the petal opening: rounded petals, valleys squared off.
    private static func openingPoints(centre: CGPoint, radius: CGFloat) -> [CGPoint] {
        let samples = ImmichMarkGeometry.openingSamples
        let blades = CGFloat(ImmichMarkGeometry.blades)
        return (0..<samples).map { index in
            let theta = CGFloat(index) / CGFloat(samples) * 2 * .pi
            let wave = pow(0.5 + 0.5 * cos(blades * (theta - ImmichMarkGeometry.petalPhase)),
                           ImmichMarkGeometry.openingSharpness)
            let r = radius * (ImmichMarkGeometry.openingBase + ImmichMarkGeometry.openingRise * wave)
            return CGPoint(x: centre.x + r * cos(theta), y: centre.y + r * sin(theta))
        }
    }

    /// One blade: a radial wedge from `from` out past the rim, closing on the
    /// rim itself so the cut can never leave ink outside the disc.
    private static func addSlit(from inner: CGFloat, to outer: CGFloat, halfWidth: CGFloat,
                                at angle: CGFloat, centre: CGPoint, to path: inout Path) {
        func point(_ r: CGFloat, _ a: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + r * cos(a), y: centre.y + r * sin(a))
        }
        let halfInner = halfWidth / inner
        let halfOuter = halfWidth / outer
        path.move(to: point(inner, angle - halfInner))
        path.addArc(center: centre, radius: inner,
                    startAngle: .radians(Double(angle - halfInner)),
                    endAngle: .radians(Double(angle + halfInner)),
                    clockwise: false)
        path.addLine(to: point(outer, angle + halfOuter))
        path.addLine(to: point(outer, angle - halfOuter))
        path.closeSubpath()
    }

    /// Catmull-Rom through the points, as cubics — a closed, smooth opening.
    private static func addSmoothClosed(_ points: [CGPoint], to path: inout Path) {
        guard points.count > 2 else { return }
        path.move(to: points[0])
        for index in points.indices {
            let p0 = points[(index - 1 + points.count) % points.count]
            let p1 = points[index]
            let p2 = points[(index + 1) % points.count]
            let p3 = points[(index + 2) % points.count]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
    }
}

/// The mark: the lens, filled with the Swimmich sweep.
///
/// ```swift
/// ImmichMark().frame(width: 24, height: 24)   // app bar glyph
/// ImmichMark().frame(width: 40, height: 40)   // header badge
/// ```
///
/// Purely decorative: it carries no text, so `Text`-bearing parents own the
/// accessibility label (see `ImmichLogo`, which names the wordmark beside it).
struct ImmichMark: View {
    var body: some View {
        ImmichMarkShape()
            .fill(LinearGradient.immichLogo, style: FillStyle(eoFill: true))
            .aspectRatio(1, contentMode: .fit)
    }
}
