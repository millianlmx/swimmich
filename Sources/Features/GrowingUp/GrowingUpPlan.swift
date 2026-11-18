import CoreGraphics
import Foundation

/// The two eyes of a face, in the pixels of its photo (top-left origin), the
/// one on the left of the picture first.
struct GrowingUpEyes: Equatable, Sendable {
    let left: CGPoint
    let right: CGPoint

    /// Sorted by `x`, whatever side Vision calls each eye.
    init(_ a: CGPoint, _ b: CGPoint) {
        if a.x <= b.x {
            left = a
            right = b
        } else {
            left = b
            right = a
        }
    }

    var distance: CGFloat { hypot(right.x - left.x, right.y - left.y) }

    /// How far the eye line leans, in degrees: what the alignment turns the
    /// photo by to level it.
    var tiltDegrees: Double { abs(atan2(Double(right.y - left.y), Double(right.x - left.x))) * 180 / .pi }
}

/// How fast the faces follow each other.
enum GrowingUpSpeed: String, CaseIterable, Identifiable, Sendable {
    case slow
    case normal
    case fast

    var id: String { rawValue }

    /// Seconds each face is on screen, its cross-fade into the next included.
    var hold: Double {
        switch self {
        case .slow: 0.6
        case .normal: 0.4
        case .fast: 0.25
        }
    }

    var title: String {
        switch self {
        case .slow: String(localized: "Slow")
        case .normal: String(localized: "Normal")
        case .fast: String(localized: "Fast")
        }
    }
}

/// The timelapse — pure functions of the photos, the eyes and the clock, so
/// the player and the export show the same frame at the same time.
enum GrowingUpPlan {

    /// Faces in the film at most: one per stretch of time.
    static let maxFrames = 60
    /// Photos looked at per stretch of time, the one with the largest face kept.
    static let candidatesPerStretch = 3
    /// Under this many faces there is no timelapse to watch.
    static let minFrames = 4
    /// Eyes closer than this in the preview make a blurry face once enlarged.
    static let minEyeDistance: CGFloat = 24
    /// The last face stays on screen this long, under the credit.
    static let endHold = 1.5
    /// A face leaning up to this is level enough: the first one found is kept.
    static let levelTilt = 15.0
    /// A face leaning further is turned so far that the photo spins between
    /// two faces: never in the film.
    static let maxTilt = 35.0
    /// Share of a face's time it is shown alone before it fades into the next.
    static let holdShare = 0.45

    /// Where the eyes land in the film, as a share of its width and height:
    /// every face the same size, at the same place.
    static let eyeLineY = 0.42
    static let eyeSpan = 0.26

    /// Up to `stretchCount` groups of candidates: the span from the first
    /// photo to the last cut into equal stretches of TIME (a birthday with
    /// two hundred photos counts as one day, not as half the childhood), each
    /// giving up to `candidatesPerStretch` of its photos, spread over it.
    /// Stretches with no photo are left out.
    static func stretches(
        _ assets: [AssetReactItem],
        dates: [String: Date],
        stretchCount: Int = maxFrames,
        perStretch: Int = candidatesPerStretch
    ) -> [[AssetReactItem]] {
        let dated = assets.compactMap { asset in dates[asset.id].map { (asset, $0) } }.sorted { $0.1 < $1.1 }
        guard let first = dated.first?.1, let last = dated.last?.1, stretchCount > 0 else { return [] }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return [Array(dated.prefix(perStretch).map(\.0))] }
        var groups = Array(repeating: [AssetReactItem](), count: stretchCount)
        for (asset, date) in dated {
            let index = min(Int(date.timeIntervalSince(first) / span * Double(stretchCount)), stretchCount - 1)
            groups[index].append(asset)
        }
        return groups.filter { !$0.isEmpty }.map { MosaicLayoutBuilder.spread($0, keeping: perStretch) }
    }

    /// The transform that puts `eyes` (in a photo's pixels) on the film's eye
    /// line, `eyeSpan` apart and level: scale, rotation and translation only.
    static func alignment(eyes: GrowingUpEyes, canvas: CGSize) -> CGAffineTransform {
        let targetLeft = CGPoint(x: canvas.width * (0.5 - eyeSpan / 2), y: canvas.height * eyeLineY)
        let dx = eyes.right.x - eyes.left.x
        let dy = eyes.right.y - eyes.left.y
        let distance = max(hypot(dx, dy), 0.0001)
        let scale = canvas.width * eyeSpan / distance
        let angle = -atan2(dy, dx)
        return CGAffineTransform(translationX: -eyes.left.x, y: -eyes.left.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: targetLeft.x, y: targetLeft.y))
    }

    /// The part of the photo the blurred backdrop shows: the largest crop of
    /// the film's shape, centered on the eyes, not turned. It always fills the
    /// film — a turned photo, or a close-up smaller than the film once its
    /// eyes are the right distance apart, leaves no black edge.
    static func backdropCrop(eyes: GrowingUpEyes, imageSize: CGSize, canvas: CGSize) -> CGRect {
        let focus = CGPoint(
            x: (eyes.left.x + eyes.right.x) / 2 / max(imageSize.width, 1),
            y: (eyes.left.y + eyes.right.y) / 2 / max(imageSize.height, 1)
        )
        return PhotoDumpPicker.cropRect(imageSize: imageSize, ratio: canvas.width / canvas.height, focus: focus)
    }

    /// The face to keep among `found` (in the order they were found, largest
    /// face first): the first level one, else the least leaning one under
    /// `maxTilt`.
    static func preferredFace<T>(_ found: [(T, GrowingUpEyes)]) -> T? {
        if let level = found.first(where: { $0.1.tiltDegrees <= levelTilt }) { return level.0 }
        return found.filter { $0.1.tiltDegrees <= maxTilt }.min { $0.1.tiltDegrees < $1.1.tiltDegrees }?.0
    }

    /// Lines of text from which a photo is a document (an ID card, a
    /// screen, a poster), not a portrait.
    static let documentTextLines = 5
    /// Share of the photo covered by text from which it is a document.
    static let documentTextArea = 0.04

    /// Whether a photo whose text Vision found in `textBoxes` (normalized
    /// rectangles) is a document: many lines, or large text. A sign behind
    /// someone is a line or two.
    static func looksLikeDocument(textBoxes: [CGRect]) -> Bool {
        let area = textBoxes.reduce(0.0) { $0 + Double($1.width * $1.height) }
        return textBoxes.count >= documentTextLines || area >= documentTextArea
    }

    /// Length of a film of `frameCount` faces.
    static func duration(frameCount: Int, speed: GrowingUpSpeed) -> Double {
        guard frameCount > 0 else { return 0 }
        return Double(frameCount - 1) * speed.hold + endHold
    }

    /// What is on screen at `time`: the face `index`, fading into the next one
    /// by `blend` (`0` alone, `1` the next one). Each face is shown alone for
    /// `holdShare` of its time, then cross-fades, eased, into the next; the
    /// last one stays.
    static func frame(at time: Double, frameCount: Int, speed: GrowingUpSpeed) -> (index: Int, blend: Double) {
        guard frameCount > 1 else { return (0, 0) }
        let position = max(time, 0) / speed.hold
        let index = Int(position)
        guard index < frameCount - 1 else { return (frameCount - 1, 0) }
        let local = position - Double(index)
        guard local > holdShare else { return (index, 0) }
        let t = (local - holdShare) / (1 - holdShare)
        return (index, t * t * (3 - 2 * t))
    }

    /// The age under the face on the day the photo was taken, nil without a
    /// birthday or for a photo taken before it.
    static func ageLabel(birthDate: String?, takenOn day: CalendarDay?) -> String? {
        guard let birth = PersonBirthday.day(from: birthDate), let day,
              let age = PersonAge.at(birth: birth, on: day) else { return nil }
        return age.label()
    }

    /// The day the photo was taken, where it was taken: Immich's UTC time
    /// moved by the photo's own offset.
    static func localDay(of asset: AssetReactItem, date: Date) -> CalendarDay? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let local = date.addingTimeInterval(asset.localOffsetHours * 3600)
        let parts = calendar.dateComponents([.year, .month, .day], from: local)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return CalendarDay(year: year, month: month, day: day)
    }
}
