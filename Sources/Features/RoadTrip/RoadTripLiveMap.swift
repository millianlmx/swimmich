import MapKit
import SwiftUI
import UIKit

/// When the film started playing. Shared by reference between the SwiftUI
/// player and the live map, which reads it at every display refresh without
/// waiting for any SwiftUI update.
@MainActor
final class RoadTripFilmClock {
    var start: Date?

    /// Film time at `now`; 0 before the film starts.
    func elapsed(at now: Date) -> TimeInterval {
        start.map { now.timeIntervalSince($0) } ?? 0
    }
}

/// The film's map, in the live player.
///
/// An `MKMapView` over satellite imagery driven by a display link: at every
/// refresh it reads the film clock, takes the shot of that instant
/// (`RoadTripMapShot`: the opening's whole trip, a leg, the ending) and places
/// the camera (`RoadTripAerialCamera`, north-up, straight down), the trip's
/// line — every leg already driven, the current one up to the car — the car,
/// the stop pins and the transitions itself. Under the pictures it holds the
/// next leg's start, so MapKit is up and its tiles are loaded when it plays.
///
/// It replaces a SwiftUI `Map` inside a `MapReader` that never moved on a
/// device: nothing in it was redrawn after its first frame.
struct RoadTripLiveMap: UIViewRepresentable {
    let timeline: RoadTripTimeline
    let clock: RoadTripFilmClock
    /// The trip's located stops, in film order.
    let stops: [RoadTripMapStop]
    /// The photo of the slideshow segment at an index: its first (`true`) or
    /// last (`false`) one — the arrival dive and the outgoing fade.
    let photo: (_ segmentIndex: Int, _ first: Bool) -> UIImage?
    /// The photo a stop shows on the ending's map.
    let stopPhoto: (_ clusterID: String) -> UIImage?
    /// "Paris, France → Versailles, France": what VoiceOver reads for a leg.
    let legLabel: (RoadTripTimeline.Travel) -> String

    func makeUIView(context: Context) -> RoadTripLiveMapView {
        RoadTripLiveMapView(
            timeline: timeline, clock: clock, stops: stops,
            photo: photo, stopPhoto: stopPhoto, legLabel: legLabel
        )
    }

    func updateUIView(_ view: RoadTripLiveMapView, context: Context) {
        view.update(timeline: timeline, stops: stops, photo: photo, stopPhoto: stopPhoto, legLabel: legLabel)
    }
}

/// See `RoadTripLiveMap`.
@MainActor
final class RoadTripLiveMapView: UIView, MKMapViewDelegate {

    private let mapView = MKMapView()
    private let carView = UIImageView()
    private var stopPins: [UIView] = []
    private var photoPins: [UIImageView] = []
    private let dimView = UIView()
    private let pinRing = UIView()
    private let pinDot = UIView()
    private let diveImageView = UIImageView()
    private let outgoingImageView = UIImageView()

    private var timeline: RoadTripTimeline
    private let clock: RoadTripFilmClock
    private var stops: [RoadTripMapStop]
    private var photo: (Int, Bool) -> UIImage?
    private var stopPhoto: (String) -> UIImage?
    private var legLabel: (RoadTripTimeline.Travel) -> String

    private var displayLink: CADisplayLink?

    /// The three strokes of a leg's line (glow, white casing, color), drawn
    /// up to `strokeEnd`.
    private struct LegLine {
        let segmentIndex: Int
        let polylines: [MKPolyline]
    }
    private enum Stroke: Int {
        case glow, casing, line
    }
    private var legLines: [LegLine] = []
    /// Polyline → (segment index, stroke).
    private var strokeOf: [ObjectIdentifier: (segmentIndex: Int, stroke: Stroke)] = [:]
    private var renderers: [ObjectIdentifier: MKPolylineRenderer] = [:]
    /// What each leg's line shows now: how much of it, how opaque.
    private var lineState: [Int: (end: CGFloat, alpha: CGFloat)] = [:]
    private var carImages: [Int: UIImage] = [:]

    /// What the map shows (test seam).
    private(set) var shot: RoadTripMapShot?
    /// The ground the camera shows (test seam).
    private(set) var shotRect: MKMapRect?
    /// Segment index of the leg whose transitions are set up.
    private(set) var legIndex: Int?
    /// Arc fraction of the car on its leg (0 before the leg starts).
    private(set) var carProgress: Double = 0
    /// The car's coordinate on the map.
    private(set) var carCoordinate = CLLocationCoordinate2D()
    private var announcedPercent = -1

    init(
        timeline: RoadTripTimeline,
        clock: RoadTripFilmClock,
        stops: [RoadTripMapStop],
        photo: @escaping (Int, Bool) -> UIImage?,
        stopPhoto: @escaping (String) -> UIImage?,
        legLabel: @escaping (RoadTripTimeline.Travel) -> String
    ) {
        self.timeline = timeline
        self.clock = clock
        self.stops = stops
        self.photo = photo
        self.stopPhoto = stopPhoto
        self.legLabel = legLabel
        super.init(frame: .zero)
        backgroundColor = .black
        accessibilityIdentifier = "roadTripMap"

        mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        mapView.isUserInteractionEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.delegate = self
        addSubview(mapView)

        carView.contentMode = .scaleAspectFit
        dimView.backgroundColor = .black
        pinRing.backgroundColor = .white
        pinDot.backgroundColor = RoadTripMapStyle.pin
        for imageView in [diveImageView, outgoingImageView] {
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
        }
        buildStops()
        for overlay in [carView, dimView, pinRing, pinDot, diveImageView, outgoingImageView] {
            overlay.isUserInteractionEnabled = false
            overlay.isHidden = true
            addSubview(overlay)
        }
        buildLines()
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(
        timeline: RoadTripTimeline,
        stops: [RoadTripMapStop],
        photo: @escaping (Int, Bool) -> UIImage?,
        stopPhoto: @escaping (String) -> UIImage?,
        legLabel: @escaping (RoadTripTimeline.Travel) -> String
    ) {
        self.photo = photo
        self.stopPhoto = stopPhoto
        self.legLabel = legLabel
        if timeline != self.timeline || stops != self.stops {
            self.timeline = timeline
            self.stops = stops
            legIndex = nil
            shotRect = nil
            buildStops()
            buildLines()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapView.frame = bounds
        dimView.frame = bounds
        outgoingImageView.frame = bounds
    }

    // MARK: - Content

    private func buildStops() {
        for view in stopPins + photoPins { view.removeFromSuperview() }
        stopPins = stops.map { _ in
            let pin = UIView()
            pin.backgroundColor = .white
            let dot = UIView()
            dot.backgroundColor = RoadTripMapStyle.pin
            pin.addSubview(dot)
            return pin
        }
        photoPins = stops.map { stop in
            let view = UIImageView(image: stopPhoto(stop.clusterID))
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.backgroundColor = .darkGray
            view.layer.borderColor = UIColor.white.cgColor
            return view
        }
        // Above the map, under the car and the transitions.
        for view in stopPins + photoPins {
            view.isUserInteractionEnabled = false
            view.isHidden = true
            if mapView.superview === self {
                insertSubview(view, aboveSubview: mapView)
            } else {
                addSubview(view)
            }
        }
        // The photo pins above every stop pin.
        for view in photoPins { bringSubviewToFront(view) }
        for view in [carView, dimView, pinRing, pinDot, diveImageView, outgoingImageView] where view.superview === self {
            bringSubviewToFront(view)
        }
    }

    private func buildLines() {
        mapView.removeOverlays(mapView.overlays)
        legLines = []
        strokeOf = [:]
        renderers = [:]
        lineState = [:]
        for (index, segment) in timeline.segments.enumerated() {
            guard case .travel(let travel) = segment else { continue }
            let coordinates = RoadTripRouteDrawing.drawnRoute(travel.route).coordinates
            guard coordinates.count >= 2 else { continue }
            let polylines = [Stroke.glow, .casing, .line].map { stroke -> MKPolyline in
                let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                strokeOf[ObjectIdentifier(polyline)] = (index, stroke)
                return polyline
            }
            legLines.append(LegLine(segmentIndex: index, polylines: polylines))
            lineState[index] = (0, 1)
        }
        // Every glow under every casing under every line: a leg crossing an
        // earlier one stays readable.
        for stroke in [Stroke.glow, .casing, .line] {
            mapView.addOverlays(legLines.map { $0.polylines[stroke.rawValue] }, level: .aboveRoads)
        }
    }

    // MARK: - Display link

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: RoadTripDisplayLinkTarget(self), selector: #selector(RoadTripDisplayLinkTarget.fire(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
            render(at: Date())
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// Draws the map at the film time of `now`.
    func render(at now: Date) {
        let time = min(max(clock.elapsed(at: now), 0), timeline.totalDuration)
        let shot = RoadTripMapShot.at(time, in: timeline)
        self.shot = shot
        let canvas = bounds.size
        let aspect = canvas.width > 0 && canvas.height > 0 ? Double(canvas.width / canvas.height) : 390.0 / 844.0
        guard let rect = RoadTripAerialCamera.rect(for: shot, timeline: timeline, stops: stops, aspect: aspect) else {
            // Nothing located: the pictures play over black.
            isHidden = true
            setReadable(false)
            return
        }
        isHidden = false
        if !Self.same(rect, shotRect) {
            mapView.setVisibleMapRect(rect, animated: false)
            shotRect = rect
        }

        switch shot {
        case .opening:
            setLines { _ in (1, CGFloat(RoadTripMapStyle.previewAlpha)) }
            showStops(upTo: stops.count - 1)
            hidePhotoPins()
            carView.isHidden = true
            hideTransitions()
            setReadable(false)
        case .ending(let progress):
            setLines { _ in (1, 1) }
            showStops(upTo: stops.count - 1)
            showPhotoPins(endingProgress: progress)
            carView.isHidden = true
            hideTransitions()
            setReadable(false)
        case .leg(let index, let localTime):
            guard case .travel(let travel) = timeline.segments[index] else { return }
            let driving = timeline.segmentIndex(at: time) == index
            if index != legIndex {
                show(leg: index, travel: travel)
            }
            drawLeg(index: index, travel: travel, localTime: localTime, driving: driving)
        }
    }

    // MARK: - Leg

    private func show(leg index: Int, travel: RoadTripTimeline.Travel) {
        legIndex = index
        announcedPercent = -1
        diveImageView.image = photo(index + 1, true)
        outgoingImageView.image = photo(index - 1, false)
        accessibilityLabel = legLabel(travel)
    }

    private func drawLeg(index: Int, travel: RoadTripTimeline.Travel, localTime: TimeInterval, driving: Bool) {
        let timing = RoadTripTravelTiming.frame(travel: travel, localTime: localTime)
        let fraction = CGFloat(min(max(timing.routeDrawnFraction, 0), 1))
        setLines { segment in
            if segment < index { return (1, 1) }
            if segment == index { return (fraction, 1) }
            return (0, 1)
        }
        let destination = stops.firstIndex { $0.clusterID == travel.toClusterID } ?? (stops.count - 1)
        showStops(upTo: destination)
        hidePhotoPins()

        // The car, nose along the road (north-up map: heading = screen angle).
        carCoordinate = timing.carCoordinate.coordinate
        carProgress = timing.routeDrawnFraction
        let side = bounds.width * CGFloat(RoadTripMapStyle.carSpriteSize)
        if let point = projected(carCoordinate) {
            let heading = RoadTripAerialCamera.carHeading(travel: travel, localTime: localTime)
            let step = 2 * Double.pi / Double(RoadTripCar3D.spriteCount)
            let nearest = (heading / step).rounded() * step
            carView.image = carImage(nearestHeading: nearest, step: step)
            carView.transform = .identity
            carView.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            carView.center = point
            carView.transform = CGAffineTransform(rotationAngle: CGFloat(heading - nearest))
            carView.isHidden = false
        } else {
            carView.isHidden = true
        }

        drawTransitions(travel: travel, localTime: localTime, driving: driving)

        // VoiceOver (and the UI tests) read where the car is — only while a leg
        // plays. Under the pictures the whole map is hidden from it.
        setReadable(driving)
        let percent = Int((timing.routeDrawnFraction * 100).rounded())
        if percent != announcedPercent {
            announcedPercent = percent
            accessibilityValue = (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
        }
    }

    private func carImage(nearestHeading: Double, step: Double) -> UIImage {
        let count = RoadTripCar3D.spriteCount
        let key = ((Int((nearestHeading / step).rounded()) % count) + count) % count
        if let cached = carImages[key] { return cached }
        let image = UIImage(cgImage: RoadTripCar3D.sprite(forBearing: nearestHeading))
        carImages[key] = image
        return image
    }

    /// Arrival dive (dim, pin, destination photo growing to full screen) and
    /// the outgoing photo's fade — the export's transitions.
    private func drawTransitions(travel: RoadTripTimeline.Travel, localTime: TimeInterval, driving: Bool) {
        let canvas = bounds.size
        guard canvas.width > 0 else { return }

        let dive = driving ? RoadTripSegue.diveProgress(localTime: localTime, legDuration: travel.duration) : 0
        if dive > 0, let destination = travel.route.last, let projectedPoint = projected(destination.coordinate) {
            let point = RoadTripSegue.clampedToMargins(projectedPoint, canvas: canvas)
            let pop = RoadTripSegue.pinPop(dive)
            dimView.alpha = RoadTripSegue.mapFade(dive) * 0.92
            place(pinRing, at: point, diameter: canvas.width * CGFloat(RoadTripMapStyle.pinRingDiameter) * 1.4 * pop)
            place(pinDot, at: point, diameter: canvas.width * CGFloat(RoadTripMapStyle.pinDotDiameter) * 1.4 * pop)
            let thumb = CGSize(
                width: canvas.width * RoadTripSegue.thumbSizeFraction,
                height: canvas.width * RoadTripSegue.thumbSizeFraction * 0.75
            )
            diveImageView.frame = RoadTripSegue.thumbnailRect(pinCenter: point, pinSize: thumb, canvas: canvas, dive: dive)
            diveImageView.layer.cornerRadius = dive >= 0.99 ? 0 : 18 * (1 - dive)
            diveImageView.alpha = RoadTripSegue.thumbnailAlpha(dive)
            for view in [dimView, pinRing, pinDot] { view.isHidden = false }
            diveImageView.isHidden = diveImageView.image == nil
        } else {
            for view in [dimView, pinRing, pinDot, diveImageView] { view.isHidden = true }
        }

        let outgoing = driving ? RoadTripSegue.outgoingPhotoAlpha(localTime: localTime) : 0
        outgoingImageView.alpha = outgoing
        outgoingImageView.isHidden = outgoing <= 0 || outgoingImageView.image == nil
    }

    private func hideTransitions() {
        for view in [dimView, pinRing, pinDot, diveImageView, outgoingImageView] { view.isHidden = true }
    }

    // MARK: - Stops

    private func showStops(upTo last: Int) {
        let ring = bounds.width * CGFloat(RoadTripMapStyle.pinRingDiameter)
        let dot = bounds.width * CGFloat(RoadTripMapStyle.pinDotDiameter)
        for (index, pin) in stopPins.enumerated() {
            guard index <= last, let point = projected(stops[index].coordinate.coordinate) else {
                pin.isHidden = true
                continue
            }
            place(pin, at: point, diameter: ring)
            if let inner = pin.subviews.first {
                place(inner, at: CGPoint(x: ring / 2, y: ring / 2), diameter: dot)
            }
            pin.isHidden = false
        }
    }

    private func showPhotoPins(endingProgress: Double) {
        let diameter = bounds.width * CGFloat(RoadTripMapStyle.photoPinDiameter)
        for (index, pin) in photoPins.enumerated() {
            let pop = RoadTripMapStyle.photoPinPop(index: index, count: photoPins.count, endingProgress: endingProgress)
            guard pop > 0.01, pin.image != nil, let point = projected(stops[index].coordinate.coordinate) else {
                pin.isHidden = true
                continue
            }
            pin.transform = .identity
            place(pin, at: CGPoint(x: point.x, y: point.y - diameter * 0.62), diameter: diameter)
            pin.layer.borderWidth = bounds.width * CGFloat(RoadTripMapStyle.photoPinBorder)
            pin.transform = CGAffineTransform(scaleX: CGFloat(pop), y: CGFloat(pop))
            pin.isHidden = false
        }
    }

    private func hidePhotoPins() {
        for pin in photoPins { pin.isHidden = true }
    }

    // MARK: - Lines

    /// Sets how much of each leg's line shows, and how opaque, redrawing only
    /// the strokes that changed (every 0.2 % of a leg).
    private func setLines(_ state: (Int) -> (end: CGFloat, alpha: CGFloat)) {
        for leg in legLines {
            let target = state(leg.segmentIndex)
            let current = lineState[leg.segmentIndex] ?? (-1, -1)
            let moved = abs(target.end - current.end) >= 0.002 || (target.end >= 1 && current.end < 1) || (target.end <= 0 && current.end > 0)
            guard moved || target.alpha != current.alpha else { continue }
            lineState[leg.segmentIndex] = target
            for polyline in leg.polylines {
                guard let renderer = renderers[ObjectIdentifier(polyline)] else { continue }
                apply(target, to: renderer)
            }
        }
    }

    private func apply(_ state: (end: CGFloat, alpha: CGFloat), to renderer: MKPolylineRenderer) {
        renderer.strokeEnd = state.end
        renderer.alpha = state.end > 0 ? state.alpha : 0
        renderer.setNeedsDisplay()
    }

    // MARK: - Geometry

    private func projected(_ coordinate: CLLocationCoordinate2D) -> CGPoint? {
        let point = mapView.convert(coordinate, toPointTo: self)
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    private func place(_ view: UIView, at center: CGPoint, diameter: CGFloat) {
        view.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        view.center = center
        view.layer.cornerRadius = diameter / 2
    }

    private func setReadable(_ readable: Bool) {
        isAccessibilityElement = readable
        accessibilityElementsHidden = !readable
    }

    private static func same(_ a: MKMapRect, _ b: MKMapRect?) -> Bool {
        guard let b else { return false }
        return a.origin.x == b.origin.x && a.origin.y == b.origin.y
            && a.size.width == b.size.width && a.size.height == b.size.height
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline, let role = strokeOf[ObjectIdentifier(line)] else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.lineCap = .round
        renderer.lineJoin = .round
        let width = max(bounds.width, 320)
        switch role.stroke {
        case .glow:
            renderer.strokeColor = RoadTripMapStyle.routeGlow
            renderer.lineWidth = width * CGFloat(RoadTripMapStyle.glowWidth)
        case .casing:
            renderer.strokeColor = RoadTripMapStyle.casing
            renderer.lineWidth = width * CGFloat(RoadTripMapStyle.casingWidth)
        case .line:
            renderer.strokeColor = RoadTripMapStyle.route
            renderer.lineWidth = width * CGFloat(RoadTripMapStyle.lineWidth)
        }
        apply(lineState[role.segmentIndex] ?? (0, 1), to: renderer)
        renderers[ObjectIdentifier(line)] = renderer
        return renderer
    }

    // MARK: - Test seams

    /// The camera's centre.
    var cameraCenter: CLLocationCoordinate2D {
        guard let shotRect else { return mapView.camera.centerCoordinate }
        return MKMapPoint(x: shotRect.midX, y: shotRect.midY).coordinate
    }
    /// The drawn fraction and opacity of the line of the leg at `segmentIndex`.
    func line(ofLeg segmentIndex: Int) -> (end: CGFloat, alpha: CGFloat)? {
        lineState[segmentIndex]
    }
    /// Whether the car is on screen.
    var showsCar: Bool { !carView.isHidden }
    /// How many stop pins show.
    var shownStopCount: Int { stopPins.filter { !$0.isHidden }.count }
}

/// Display-link target holding its view weakly: the link retains its target.
@MainActor
private final class RoadTripDisplayLinkTarget: NSObject {
    private weak var view: RoadTripLiveMapView?

    init(_ view: RoadTripLiveMapView) {
        self.view = view
    }

    @objc func fire(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.render(at: Date())
    }
}
