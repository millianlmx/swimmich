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
    /// The photo at a position of the slideshow segment at an index — those
    /// of its first and last frames (`RoadTripSlideTiming.edgeTiles`) play
    /// the arrival dive and the outgoing fade.
    let photo: (_ segmentIndex: Int, _ position: Int) -> UIImage?
    /// The photo a stop shows on the ending's map.
    let stopPhoto: (_ clusterID: String) -> UIImage?
    /// "Paris, France → Versailles, France": what VoiceOver reads for a leg.
    let legLabel: (RoadTripTimeline.Travel) -> String
    /// The photos' Ken Burns framing is off: the transitions land on and
    /// leave from the plain photo.
    var reduceMotion = false
    /// The car's paint (`RoadTripSettings`).
    var carColor: RoadTripSettings.CarColor = .white
    /// Called once the opening's map is drawn with its imagery (or after a
    /// timeout): the film starts on a finished map, not on grey tiles.
    var onReady: () -> Void = {}

    func makeUIView(context: Context) -> RoadTripLiveMapView {
        let view = RoadTripLiveMapView(
            timeline: timeline, clock: clock, stops: stops,
            photo: photo, stopPhoto: stopPhoto, legLabel: legLabel
        )
        view.reduceMotion = reduceMotion
        view.carColor = carColor
        view.onReady = onReady
        return view
    }

    func updateUIView(_ view: RoadTripLiveMapView, context: Context) {
        view.reduceMotion = reduceMotion
        view.carColor = carColor
        view.onReady = onReady
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
    /// The outgoing slideshow's last frame: one photo, or a collage's tiles
    /// over its black.
    private let outgoingBackdrop = UIView()
    private let outgoingTiles: [RoadTripTileView] = (0..<RoadTripTimelineBuilder.maxCollageTiles).map { _ in RoadTripTileView() }
    /// A collage's other photos, fading in around the dive's growing one.
    private let arrivingTiles: [RoadTripTileView] = (1..<RoadTripTimelineBuilder.maxCollageTiles).map { _ in RoadTripTileView() }
    /// Every view of the map↔photo transitions, bottom to top.
    private var transitionViews: [UIView] {
        [dimView, pinRing, pinDot, diveImageView] + arrivingTiles + [outgoingBackdrop] + outgoingTiles
    }

    private var timeline: RoadTripTimeline
    private let clock: RoadTripFilmClock
    private var stops: [RoadTripMapStop]
    private var photo: (Int, Int) -> UIImage?
    private var stopPhoto: (String) -> UIImage?
    private var legLabel: (RoadTripTimeline.Travel) -> String

    private var displayLink: CADisplayLink?

    var reduceMotion = false
    /// The car's paint: its sprites are cached per heading for this paint.
    var carColor: RoadTripSettings.CarColor = .white {
        didSet { if carColor != oldValue { carImages = [:] } }
    }
    /// See `RoadTripLiveMap.onReady`; fired once.
    var onReady: () -> Void = {}
    private var readyFired = false
    /// How long the opening waits for MapKit's imagery before playing anyway.
    static let readyTimeout: TimeInterval = 3

    /// A leg's road as drawn: map points and their arc fractions.
    private struct LegLine {
        let segmentIndex: Int
        let points: [MKMapPoint]
        let fractions: [Double]
    }
    private var legLines: [LegLine] = []
    /// The trip's line — glow under white casing under color — drawn over the
    /// map at every refresh, like the car and the pins. Not MapKit overlays:
    /// their tiles are only redrawn once the camera rests, and this camera
    /// never rests, so pulling back showed only the bit of an old leg that had
    /// been on screen while zoomed in.
    private let lineLayers: [CAShapeLayer] = (0..<3).map { _ in CAShapeLayer() }
    private let lineHost = UIView()
    /// The stems of the ending's photo pins pushed off their stops (over the
    /// line, under the pins).
    private let stemLayer = CAShapeLayer()
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
        photo: @escaping (Int, Int) -> UIImage?,
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

        lineHost.isUserInteractionEnabled = false
        let strokes: [(UIColor, Double)] = [
            (RoadTripMapStyle.routeGlow, RoadTripMapStyle.glowWidth),
            (RoadTripMapStyle.casing, RoadTripMapStyle.casingWidth),
            (RoadTripMapStyle.route, RoadTripMapStyle.lineWidth)
        ]
        for (layer, stroke) in zip(lineLayers, strokes) {
            layer.fillColor = nil
            layer.strokeColor = stroke.0.cgColor
            layer.lineCap = .round
            layer.lineJoin = .round
            lineHost.layer.addSublayer(layer)
        }
        stemLayer.strokeColor = UIColor.white.cgColor
        stemLayer.fillColor = nil
        stemLayer.lineCap = .round
        stemLayer.isHidden = true
        lineHost.layer.addSublayer(stemLayer)
        addSubview(lineHost)

        carView.contentMode = .scaleAspectFit
        dimView.backgroundColor = .black
        outgoingBackdrop.backgroundColor = .black
        pinRing.backgroundColor = .white
        pinDot.backgroundColor = RoadTripMapStyle.pin
        diveImageView.contentMode = .scaleAspectFill
        diveImageView.clipsToBounds = true
        buildStops()
        for overlay in [carView] + transitionViews {
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
        photo: @escaping (Int, Int) -> UIImage?,
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
        lineHost.frame = bounds
        dimView.frame = bounds
        let width = max(bounds.width, 320)
        for (layer, style) in zip(lineLayers, [RoadTripMapStyle.glowWidth, RoadTripMapStyle.casingWidth, RoadTripMapStyle.lineWidth]) {
            layer.frame = lineHost.bounds
            layer.lineWidth = width * CGFloat(style)
        }
        stemLayer.frame = lineHost.bounds
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
            if lineHost.superview === self {
                insertSubview(view, aboveSubview: lineHost)
            } else {
                addSubview(view)
            }
        }
        // The photo pins above every stop pin.
        for view in photoPins { bringSubviewToFront(view) }
        for view in [carView] + transitionViews where view.superview === self {
            bringSubviewToFront(view)
        }
    }

    private func buildLines() {
        legLines = []
        lineState = [:]
        for (index, segment) in timeline.segments.enumerated() {
            guard case .travel(let travel) = segment else { continue }
            let drawn = RoadTripRouteDrawing.drawnRoute(travel.route)
            guard drawn.coordinates.count >= 2 else { continue }
            legLines.append(LegLine(segmentIndex: index, points: drawn.coordinates.map { MKMapPoint($0) }, fractions: drawn.fractions))
            lineState[index] = (0, 1)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in
                self?.fireReady()
            }
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
            fireReady()
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
        let arriving = RoadTripSlideTiming.edgeTiles(
            segmentIndex: index + 1, in: timeline, first: true, reduceMotion: reduceMotion, canvas: bounds.size
        )
        diveImageView.image = arriving.first.flatMap { photo(index + 1, $0.position) }
        for (k, view) in arrivingTiles.enumerated() {
            view.image = arriving.indices.contains(k + 1) ? photo(index + 1, arriving[k + 1].position) : nil
        }
        let leaving = RoadTripSlideTiming.edgeTiles(
            segmentIndex: index - 1, in: timeline, first: false, reduceMotion: reduceMotion, canvas: bounds.size
        )
        for (k, view) in outgoingTiles.enumerated() {
            view.image = leaving.indices.contains(k) ? photo(index - 1, leaving[k].position) : nil
        }
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
        let image = UIImage(cgImage: RoadTripCar3D.sprite(forBearing: nearestHeading, color: carColor))
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
            dimView.alpha = RoadTripSegue.mapDim(dive)
            place(pinRing, at: point, diameter: canvas.width * CGFloat(RoadTripMapStyle.pinRingDiameter) * 1.4 * pop)
            place(pinDot, at: point, diameter: canvas.width * CGFloat(RoadTripMapStyle.pinDotDiameter) * 1.4 * pop)
            pinRing.alpha = RoadTripSegue.pinAlpha(dive)
            pinDot.alpha = RoadTripSegue.pinAlpha(dive)
            let thumb = CGSize(
                width: canvas.width * RoadTripSegue.thumbSizeFraction,
                height: canvas.width * RoadTripSegue.thumbSizeFraction * 0.75
            )
            // The next stop's first frame: its photo, or its collage's tiles —
            // the first grows from the pin, the others fade in in place.
            let arriving = RoadTripSlideTiming.edgeTiles(
                segmentIndex: (legIndex ?? 0) + 1, in: timeline, first: true, reduceMotion: reduceMotion, canvas: canvas
            )
            diveImageView.frame = RoadTripSegue.thumbnailRect(
                pinCenter: point, pinSize: thumb, canvas: canvas, dive: dive, landing: arriving.first?.rect
            )
            diveImageView.layer.cornerRadius = dive >= 0.99 ? 0 : 18 * (1 - dive)
            diveImageView.alpha = RoadTripSegue.thumbnailAlpha(dive)
            for view in [dimView, pinRing, pinDot] { view.isHidden = false }
            diveImageView.isHidden = diveImageView.image == nil
            let rim = canvas.width * CGFloat(RoadTripCollage.frameBorder)
            for (k, view) in arrivingTiles.enumerated() {
                guard arriving.indices.contains(k + 1), view.image != nil else {
                    view.isHidden = true
                    continue
                }
                view.place(arriving[k + 1], rim: rim, alpha: RoadTripSegue.mapDim(dive))
            }
        } else {
            for view in [dimView, pinRing, pinDot, diveImageView] + arrivingTiles { view.isHidden = true }
        }

        let outgoing = driving ? RoadTripSegue.outgoingPhotoAlpha(localTime: localTime) : 0
        // Framed as the slideshow's last frame left them.
        let tiles = outgoing > 0
            ? RoadTripSlideTiming.edgeTiles(
                segmentIndex: (legIndex ?? 0) - 1, in: timeline, first: false, reduceMotion: reduceMotion, canvas: canvas
            )
            : []
        let rim = canvas.width * CGFloat(RoadTripCollage.frameBorder)
        // A collage's black between its tiles fades out with them.
        outgoingBackdrop.frame = bounds
        outgoingBackdrop.alpha = outgoing
        outgoingBackdrop.isHidden = tiles.count < 2
        for (k, view) in outgoingTiles.enumerated() {
            guard tiles.indices.contains(k), view.image != nil else {
                view.isHidden = true
                continue
            }
            view.place(tiles[k], rim: rim, alpha: outgoing * tiles[k].alpha)
        }
    }

    private func hideTransitions() {
        for view in transitionViews { view.isHidden = true }
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
        // Laid out together (every stop with a photo, popped or not) so a
        // photo never jumps when the next one pops — as the export does.
        var laidOut: [(index: Int, point: CGPoint)] = []
        for (index, pin) in photoPins.enumerated() where pin.image != nil {
            if let point = projected(stops[index].coordinate.coordinate) {
                laidOut.append((index, point))
            }
        }
        let centers = RoadTripMapStyle.photoPinCenters(pins: laidOut.map(\.point), diameter: diameter, canvas: bounds.size)
        var placement: [Int: (point: CGPoint, center: CGPoint)] = [:]
        for (entry, center) in zip(laidOut, centers) {
            placement[entry.index] = (entry.point, center)
        }
        let stems = UIBezierPath()
        for (index, pin) in photoPins.enumerated() {
            let pop = RoadTripMapStyle.photoPinPop(index: index, count: photoPins.count, endingProgress: endingProgress)
            guard pop > 0.01, let placed = placement[index] else {
                pin.isHidden = true
                continue
            }
            if pop > 0.5, RoadTripMapStyle.photoPinNeedsStem(center: placed.center, pin: placed.point, diameter: diameter) {
                stems.move(to: placed.point)
                stems.addLine(to: placed.center)
            }
            pin.transform = .identity
            place(pin, at: placed.center, diameter: diameter)
            pin.layer.borderWidth = bounds.width * CGFloat(RoadTripMapStyle.photoPinBorder)
            pin.transform = CGAffineTransform(scaleX: CGFloat(pop), y: CGFloat(pop))
            pin.isHidden = false
        }
        stemLayer.lineWidth = bounds.width * CGFloat(RoadTripMapStyle.photoPinStemWidth)
        stemLayer.path = stems.cgPath
        stemLayer.isHidden = false
    }

    private func hidePhotoPins() {
        for pin in photoPins { pin.isHidden = true }
        stemLayer.isHidden = true
    }

    // MARK: - Lines

    /// Sets how much of each leg's line shows, and how opaque, and redraws the
    /// line where the camera is now. Every glow under every casing under every
    /// line: a leg crossing an earlier one stays readable.
    private func setLines(_ state: (Int) -> (end: CGFloat, alpha: CGFloat)) {
        for leg in legLines {
            lineState[leg.segmentIndex] = state(leg.segmentIndex)
        }
        // Map points → screen: a north-up flat map is a scale and a shift,
        // read off MapKit itself so the line sits exactly under the car and
        // the pins (placed with `convert` too).
        guard let rect = shotRect, rect.size.width > 0, rect.size.height > 0,
              let a = projected(MKMapPoint(x: rect.minX, y: rect.minY).coordinate),
              let b = projected(MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate) else { return }
        let scaleX = (b.x - a.x) / CGFloat(rect.size.width)
        let scaleY = (b.y - a.y) / CGFloat(rect.size.height)
        func screen(_ point: MKMapPoint) -> CGPoint {
            CGPoint(x: a.x + CGFloat(point.x - rect.minX) * scaleX, y: a.y + CGFloat(point.y - rect.minY) * scaleY)
        }

        let path = CGMutablePath()
        var alpha: CGFloat = 0
        for leg in legLines {
            guard let state = lineState[leg.segmentIndex], state.end > 0 else { continue }
            alpha = max(alpha, state.alpha)
            let end = Double(state.end)
            var last = screen(leg.points[0])
            path.move(to: last)
            for i in 1..<leg.points.count {
                var point = screen(leg.points[i])
                let fraction = leg.fractions[i]
                if fraction > end {
                    // The partial segment up to the car.
                    let previous = leg.fractions[i - 1]
                    let t = CGFloat((end - previous) / max(fraction - previous, 1e-9))
                    let from = screen(leg.points[i - 1])
                    point = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
                    path.addLine(to: point)
                    break
                }
                // Points closer than a pixel add nothing but work.
                guard abs(point.x - last.x) + abs(point.y - last.y) >= 1 || i == leg.points.count - 1 else { continue }
                path.addLine(to: point)
                last = point
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in lineLayers { layer.path = path }
        lineHost.alpha = alpha
        CATransaction.commit()
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

    private func fireReady() {
        guard !readyFired else { return }
        readyFired = true
        // Out of the current layout/render pass: the callback updates SwiftUI
        // state.
        DispatchQueue.main.async { [weak self] in self?.onReady() }
    }

    // MARK: - MKMapViewDelegate

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        if fullyRendered { fireReady() }
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
    /// Where the trip's line lies on screen now.
    var drawnLineBounds: CGRect { lineLayers[2].path?.boundingBoxOfPath ?? .null }
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

/// A photo of the map↔photo transitions placed as the export draws it
/// (`RoadTripCollage.DrawnTile`): tilted about its center, the photo filled
/// into its tile and pushed in by the tile's zoom, inside a white rim when
/// framed.
private final class RoadTripTileView: UIView {
    private let clip = UIView()
    private let imageView = UIImageView()

    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clip.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        clip.addSubview(imageView)
        addSubview(clip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `rim`: the white border of a framed tile, outside its photo.
    func place(_ tile: RoadTripCollage.DrawnTile, rim: CGFloat, alpha: Double) {
        let border = tile.framed ? rim : 0
        transform = .identity
        bounds = CGRect(origin: .zero, size: tile.rect.insetBy(dx: -border, dy: -border).size)
        center = CGPoint(x: tile.rect.midX, y: tile.rect.midY)
        transform = CGAffineTransform(rotationAngle: CGFloat(tile.rotation))
        backgroundColor = tile.framed ? .white : .clear
        clip.frame = CGRect(x: border, y: border, width: tile.rect.width, height: tile.rect.height)
        let zoom = CGFloat(tile.zoom)
        imageView.frame = clip.bounds.insetBy(dx: -clip.bounds.width * (zoom - 1) / 2, dy: -clip.bounds.height * (zoom - 1) / 2)
        self.alpha = CGFloat(alpha)
        isHidden = false
    }
}

