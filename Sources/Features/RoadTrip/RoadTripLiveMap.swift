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

/// The map of the film's travel legs, in the live player.
///
/// An `MKMapView` driven by a display link: at every refresh it reads the film
/// clock, finds the leg being driven — or the next one, set up under the
/// opaque pictures that precede it, so MapKit is up and its tiles are loaded
/// when the leg starts — and places the camera, the car, the driven route and
/// the transitions itself.
///
/// It replaces a SwiftUI `Map` inside a `MapReader` that never moved on a
/// device: nothing in it was redrawn after its first frame — camera, car,
/// route, even the SwiftUI overlays — so the car sat on its start while the
/// film's clock ran (and the next leg still showed the first one's road).
struct RoadTripLiveMap: UIViewRepresentable {
    let timeline: RoadTripTimeline
    let clock: RoadTripFilmClock
    /// The photo of the slideshow segment at an index: its first (`true`) or
    /// last (`false`) one — the arrival dive and the outgoing fade.
    let photo: (_ segmentIndex: Int, _ first: Bool) -> UIImage?
    /// "Paris, France → Versailles, France": what VoiceOver reads for a leg.
    let legLabel: (RoadTripTimeline.Travel) -> String

    func makeUIView(context: Context) -> RoadTripLiveMapView {
        RoadTripLiveMapView(timeline: timeline, clock: clock, photo: photo, legLabel: legLabel)
    }

    func updateUIView(_ view: RoadTripLiveMapView, context: Context) {
        view.update(timeline: timeline, photo: photo, legLabel: legLabel)
    }
}

/// See `RoadTripLiveMap`.
@MainActor
final class RoadTripLiveMapView: UIView, MKMapViewDelegate {

    private let mapView = MKMapView()
    private let dimView = UIView()
    private let startHalo = UIView()
    private let startDot = UIView()
    private let pinRing = UIView()
    private let pinDot = UIView()
    private let diveImageView = UIImageView()
    private let outgoingImageView = UIImageView()
    private let car = MKPointAnnotation()
    private var carView: RoadTripCarAnnotationView?

    private var timeline: RoadTripTimeline
    private let clock: RoadTripFilmClock
    private var photo: (Int, Bool) -> UIImage?
    private var legLabel: (RoadTripTimeline.Travel) -> String

    private var displayLink: CADisplayLink?
    /// Segment index of the leg on the map.
    private(set) var legIndex: Int?
    private var roadCasing: MKPolyline?
    private var road: MKPolyline?
    private var driven: MKPolyline?
    private weak var drivenRenderer: MKPolylineRenderer?
    /// Route fraction the driven line was last drawn to.
    private var drivenFraction: CGFloat = 0
    /// Arc fraction of the car on its leg (0 before the leg starts).
    private(set) var carProgress: Double = 0
    private var announcedPercent = -1

    private static let routeBlue = UIColor(red: 0.10, green: 0.42, blue: 0.90, alpha: 1)

    init(
        timeline: RoadTripTimeline,
        clock: RoadTripFilmClock,
        photo: @escaping (Int, Bool) -> UIImage?,
        legLabel: @escaping (RoadTripTimeline.Travel) -> String
    ) {
        self.timeline = timeline
        self.clock = clock
        self.photo = photo
        self.legLabel = legLabel
        super.init(frame: .zero)
        backgroundColor = .black
        accessibilityIdentifier = "roadTripMap"

        let configuration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = configuration
        mapView.isUserInteractionEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.delegate = self
        mapView.addAnnotation(car)
        addSubview(mapView)

        dimView.backgroundColor = .black
        for circle in [startHalo, startDot, pinRing, pinDot] {
            circle.isUserInteractionEnabled = false
        }
        startHalo.backgroundColor = .white
        startDot.backgroundColor = .white
        pinRing.backgroundColor = .white
        pinDot.backgroundColor = UIColor(red: 0.95, green: 0.25, blue: 0.22, alpha: 1)
        for imageView in [diveImageView, outgoingImageView] {
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
        }
        for overlay in [startHalo, startDot, dimView, pinRing, pinDot, diveImageView, outgoingImageView] {
            overlay.isUserInteractionEnabled = false
            overlay.isHidden = true
            addSubview(overlay)
        }
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(
        timeline: RoadTripTimeline,
        photo: @escaping (Int, Bool) -> UIImage?,
        legLabel: @escaping (RoadTripTimeline.Travel) -> String
    ) {
        if timeline != self.timeline {
            self.timeline = timeline
            legIndex = nil
        }
        self.photo = photo
        self.legLabel = legLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapView.frame = bounds
        dimView.frame = bounds
        outgoingImageView.frame = bounds
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

    /// The leg of the film at `index` or after it, with its segment index.
    static func leg(in timeline: RoadTripTimeline, from index: Int) -> (index: Int, travel: RoadTripTimeline.Travel)? {
        guard timeline.segments.indices.contains(index) else { return nil }
        for candidate in index..<timeline.segments.count {
            if case .travel(let travel) = timeline.segments[candidate] {
                return (candidate, travel)
            }
        }
        return nil
    }

    /// Draws the map at the film time of `now`.
    func render(at now: Date) {
        let time = min(max(clock.elapsed(at: now), 0), timeline.totalDuration)
        let index = timeline.segmentIndex(at: time)
        guard let leg = Self.leg(in: timeline, from: index) else {
            // Past the last leg: the ending covers everything.
            isHidden = true
            isAccessibilityElement = false
            accessibilityElementsHidden = true
            return
        }
        isHidden = false
        let driving = leg.index == index
        let localTime = driving ? time - timeline.segmentStartTimes[index] : 0
        if leg.index != legIndex {
            show(leg: leg)
        }
        draw(travel: leg.travel, localTime: localTime, driving: driving)
    }

    // MARK: - Leg

    private func show(leg: (index: Int, travel: RoadTripTimeline.Travel)) {
        legIndex = leg.index
        mapView.removeOverlays(mapView.overlays)
        drivenRenderer = nil
        drivenFraction = 0
        announcedPercent = -1
        let drawn = RoadTripRouteDrawing.drawnRoute(leg.travel.route)
        if drawn.coordinates.count >= 2 {
            let coordinates = drawn.coordinates
            let casing = MKPolyline(coordinates: coordinates, count: coordinates.count)
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            let drivenLine = MKPolyline(coordinates: coordinates, count: coordinates.count)
            roadCasing = casing
            road = line
            driven = drivenLine
            mapView.addOverlays([casing, line, drivenLine], level: .aboveRoads)
        } else {
            roadCasing = nil
            road = nil
            driven = nil
        }
        diveImageView.image = photo(leg.index + 1, true)
        outgoingImageView.image = photo(leg.index - 1, false)
        accessibilityLabel = legLabel(leg.travel)
    }

    private func draw(travel: RoadTripTimeline.Travel, localTime: TimeInterval, driving: Bool) {
        let timing = RoadTripTravelTiming.frame(travel: travel, localTime: localTime)
        let state = RoadTripDriveCamera.cameraState(travel: travel, localTime: localTime)
        let carBearing = RoadTripDriveCamera.carHeading(travel: travel, localTime: localTime)

        // Camera: the chase view of the export, pitched low at street level,
        // top-down once the leg zooms out.
        let lookAhead = state.lookAheadMeters
        let distance = min(
            max(lookAhead * 2.0, RoadTripDriveCamera.zoomInMeters * 2.0),
            RoadTripDriveCamera.maxFitLookAheadMeters * 2.0
        )
        let pitch = 60.0 * (1.0 - RoadTripDriveCamera.aerialBlend(lookAheadMeters: lookAhead))
        mapView.camera = MKMapCamera(
            lookingAtCenter: state.cameraCoordinate.coordinate,
            fromDistance: distance,
            pitch: CGFloat(pitch),
            heading: state.bearing * 180 / .pi
        )

        // Car.
        car.coordinate = timing.carCoordinate.coordinate
        carView?.pose(
            screenAngle: carBearing - state.bearing,
            scale: CGFloat(RoadTripDriveCamera.carSpriteScale(lookAheadMeters: lookAhead))
        )
        carProgress = timing.routeDrawnFraction

        // Driven part of the road, redrawn every 0.2 % of the leg.
        let fraction = CGFloat(min(max(timing.routeDrawnFraction, 0), 1))
        if abs(fraction - drivenFraction) >= 0.002 || (fraction >= 1 && drivenFraction < 1) {
            drivenFraction = fraction
            drivenRenderer?.strokeEnd = fraction
            drivenRenderer?.setNeedsDisplay()
        }

        drawMarkers(travel: travel, localTime: localTime, driving: driving)

        // VoiceOver (and the UI tests) read where the car is — only while a leg
        // plays. Under the pictures the whole map is hidden from it: MapKit's
        // own accessible parts (the legal link) made it a container with the
        // leg's label and a 0 % value before the leg had started.
        isAccessibilityElement = driving
        accessibilityElementsHidden = !driving
        let percent = Int((timing.routeDrawnFraction * 100).rounded())
        if percent != announcedPercent {
            announcedPercent = percent
            accessibilityValue = (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
        }
    }

    /// Start pulse, arrival dive (dim, pin, destination photo growing to full
    /// screen) and the outgoing photo's fade — the export's transitions.
    private func drawMarkers(travel: RoadTripTimeline.Travel, localTime: TimeInterval, driving: Bool) {
        let canvas = bounds.size
        guard canvas.width > 0 else { return }

        if let start = travel.route.first, let point = clamped(mapView.convert(start.coordinate, toPointTo: self), canvas: canvas) {
            let pulse = 0.5 + 0.5 * sin(2 * .pi * localTime * 1.2)
            place(startHalo, at: point, diameter: 32 + pulse * 10)
            startHalo.alpha = 0.25 + 0.3 * pulse
            place(startDot, at: point, diameter: 20)
            startHalo.isHidden = false
            startDot.isHidden = false
        } else {
            startHalo.isHidden = true
            startDot.isHidden = true
        }

        let dive = driving ? RoadTripSegue.diveProgress(localTime: localTime, legDuration: travel.duration) : 0
        if dive > 0, let destination = travel.route.last,
           let point = clamped(mapView.convert(destination.coordinate, toPointTo: self), canvas: canvas) {
            let pop = RoadTripSegue.pinPop(dive)
            dimView.alpha = RoadTripSegue.mapFade(dive) * 0.92
            place(pinRing, at: point, diameter: 32 * pop)
            place(pinDot, at: point, diameter: 20 * pop)
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

    private func place(_ circle: UIView, at center: CGPoint, diameter: CGFloat) {
        circle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        circle.center = center
        circle.layer.cornerRadius = diameter / 2
    }

    /// A projected point kept inside the canvas margins, so the markers never
    /// pop at the screen edge (the export's margins).
    private func clamped(_ point: CGPoint, canvas: CGSize) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return CGPoint(
            x: min(max(point.x, canvas.width * 0.12), canvas.width * 0.88),
            y: min(max(point.y, canvas.height * 0.15), canvas.height * 0.85)
        )
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.lineCap = .round
        renderer.lineJoin = .round
        if line === roadCasing {
            renderer.strokeColor = UIColor.black.withAlphaComponent(0.35)
            renderer.lineWidth = 9
        } else if line === driven {
            renderer.strokeColor = Self.routeBlue.withAlphaComponent(0.9)
            renderer.lineWidth = 5
            renderer.strokeEnd = drivenFraction
            drivenRenderer = renderer
        } else {
            renderer.strokeColor = UIColor.gray.withAlphaComponent(0.6)
            renderer.lineWidth = 5
        }
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation === car else { return nil }
        let view = carView ?? RoadTripCarAnnotationView(annotation: annotation, reuseIdentifier: nil)
        view.annotation = annotation
        carView = view
        return view
    }

    // MARK: - Test seams

    /// The car's coordinate on the map.
    var carCoordinate: CLLocationCoordinate2D { car.coordinate }
    /// The camera's centre.
    var cameraCenter: CLLocationCoordinate2D { mapView.camera.centerCoordinate }
}

/// The 3D car sprite riding the map: its ground contact sits on the coordinate,
/// and the sprite's yaw undoes the chase camera's perspective so the nose
/// follows the road on screen.
final class RoadTripCarAnnotationView: MKAnnotationView {
    private let shadow = UIView()
    private let sprite = UIImageView()
    private var images: [Int: UIImage] = [:]

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        isEnabled = false
        displayPriority = .required
        collisionMode = .none
        zPriority = .max
        clipsToBounds = false
        shadow.backgroundColor = UIColor.black.withAlphaComponent(0.26)
        addSubview(shadow)
        sprite.contentMode = .scaleAspectFit
        addSubview(sprite)
        pose(screenAngle: 0, scale: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `screenAngle`: the car's bearing minus the camera's heading (radians).
    func pose(screenAngle: Double, scale: CGFloat) {
        let contact = CGFloat(RoadTripCar3D.chaseContactFraction)
        let side = 164 * scale
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        // The view centres on the coordinate: move it so the contact row does.
        centerOffset = CGPoint(x: 0, y: (0.5 - contact) * side)

        shadow.bounds = CGRect(x: 0, y: 0, width: 120 * scale, height: 22 * scale)
        shadow.center = CGPoint(x: side / 2, y: contact * side + 4 * scale)
        shadow.layer.cornerRadius = 11 * scale

        let yaw = RoadTripCar3D.chaseYaw(forScreenAngle: screenAngle)
        let frameYaw = RoadTripCar3D.chaseNearestYaw(yaw)
        let key = Int((frameYaw / RoadTripCar3D.chaseYawStep).rounded())
        let image: UIImage
        if let cached = images[key] {
            image = cached
        } else {
            image = UIImage(cgImage: RoadTripCar3D.chaseSprite(forBearing: frameYaw))
            images[key] = image
        }
        sprite.image = image
        // Residual rotation about the ground contact (at most half a sprite step).
        sprite.transform = .identity
        sprite.layer.anchorPoint = CGPoint(x: 0.5, y: contact)
        sprite.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        sprite.center = CGPoint(x: side / 2, y: contact * side)
        sprite.transform = CGAffineTransform(rotationAngle: CGFloat(yaw - frameYaw))
    }
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
