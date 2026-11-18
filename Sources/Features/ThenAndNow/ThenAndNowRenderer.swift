import UIKit

/// A photo of the pair: its preview and where its subject is.
struct ThenNowPhoto: Sendable {
    let id: String
    let image: UIImage
    let focus: CGPoint
    let year: Int
}

/// Draws then & now: the wipe frame (the now photo uncovering the then one
/// from the left — the player and the video), and the stacked image.
enum ThenAndNowRenderer {

    static let videoSize = CGSize(width: 1080, height: 1920)
    static let fps: Int32 = 30

    /// `photo` filling `rect`, cropped around its subject.
    static func draw(_ photo: ThenNowPhoto, in rect: CGRect) {
        let visible = ReelPlan.visibleRect(imageSize: photo.image.size, canvas: rect.size, focus: photo.focus, progress: 0)
        let drawn = ReelPlan.drawRect(imageSize: photo.image.size, visible: visible, canvas: rect.size)
        photo.image.draw(in: drawn.offsetBy(dx: rect.minX, dy: rect.minY))
    }

    /// One frame of the wipe, in UIKit coordinates, in the current context:
    /// the now photo covers the share `wipe` of the frame from the left.
    static func drawWipe(
        then: ThenNowPhoto, now: ThenNowPhoto, wipe: Double, place: String?, credit: Bool, in size: CGSize
    ) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let frame = CGRect(origin: .zero, size: size)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: frame)
        UIColor.black.setFill()
        UIRectFill(frame)
        draw(then, in: frame)
        let x = size.width * CGFloat(min(max(wipe, 0), 1))
        if x > 0 {
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: x, height: size.height))
            draw(now, in: frame)
            context.restoreGState()
            // The dividing line.
            context.setShadow(offset: .zero, blur: 12 * size.width / 1080, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            UIColor.white.setFill()
            UIRectFill(CGRect(x: x - 3 * size.width / 1080, y: 0, width: 6 * size.width / 1080, height: size.height))
            context.setShadow(offset: .zero, blur: 0)
        }
        let unit = size.width / 1080
        // Each year on its own side, while that side shows.
        if x > size.width * 0.15 { yearPill(String(now.year), at: CGPoint(x: 48 * unit, y: size.height - 260 * unit), alignRight: false, unit: unit) }
        if x < size.width * 0.85 { yearPill(String(then.year), at: CGPoint(x: size.width - 48 * unit, y: size.height - 260 * unit), alignRight: true, unit: unit) }
        header(place: place, years: "\(then.year) → \(now.year)", width: size.width, unit: unit)
        if credit { creditPill(in: size, unit: unit) }
    }

    /// One frame of the wipe as an image, for the screen. Drawn in a bitmap
    /// context: in a SwiftUI `Canvas`, the photos (decoded for display) and
    /// the copying fill did not draw, the picture stayed blank.
    static func wipeImage(then: ThenNowPhoto, now: ThenNowPhoto, wipe: Double, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawWipe(then: then, now: now, wipe: wipe, place: nil, credit: false, in: size)
        }
    }

    /// The pair one above the other — then on top, now under it — with the
    /// place and the years: the image for a post or a story.
    static func stacked(then: ThenNowPhoto, now: ThenNowPhoto, place: String?, credit: Bool) -> UIImage {
        let size = videoSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let photoHeight: CGFloat = 800
            let top = CGRect(x: 0, y: 200, width: size.width, height: photoHeight)
            let bottom = CGRect(x: 0, y: top.maxY + 20, width: size.width, height: photoHeight)
            for (photo, rect) in [(then, top), (now, bottom)] {
                context.cgContext.saveGState()
                context.cgContext.clip(to: rect)
                draw(photo, in: rect)
                context.cgContext.restoreGState()
                yearPill(String(photo.year), at: CGPoint(x: 48, y: rect.maxY - 110), alignRight: false, unit: 1)
            }
            header(place: place, years: "\(then.year) → \(now.year)", width: size.width, unit: 1)
            if credit { creditPill(in: size, unit: 1, bottom: 16) }
        }
    }

    // MARK: - Pieces

    private static func header(place: String?, years: String, width: CGFloat, unit: CGFloat) {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 12 * unit
        var y = 70 * unit
        if let place {
            (place as NSString).draw(
                with: CGRect(x: 48 * unit, y: y, width: width - 96 * unit, height: 70 * unit),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: UIFont.systemFont(ofSize: 56 * unit, weight: .heavy), .foregroundColor: UIColor.white,
                             .shadow: shadow, .paragraphStyle: center],
                context: nil
            )
            y += 68 * unit
        }
        (years as NSString).draw(
            with: CGRect(x: 48 * unit, y: y, width: width - 96 * unit, height: 50 * unit),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: UIFont.systemFont(ofSize: 38 * unit, weight: .semibold),
                         .foregroundColor: UIColor.white.withAlphaComponent(0.85), .shadow: shadow, .paragraphStyle: center],
            context: nil
        )
    }

    private static func yearPill(_ text: String, at point: CGPoint, alignRight: Bool, unit: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 54 * unit, weight: .heavy), .foregroundColor: UIColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let width = textSize.width + 40 * unit
        let rect = CGRect(
            x: alignRight ? point.x - width : point.x, y: point.y,
            width: width, height: textSize.height + 16 * unit
        )
        UIColor.black.withAlphaComponent(0.55).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 20 * unit, y: rect.minY + 8 * unit), withAttributes: attributes)
    }

    private static func creditPill(in size: CGSize, unit: CGFloat, bottom: CGFloat = 84) {
        let text = String(localized: "Made with Swimmich") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 30 * unit, weight: .semibold), .foregroundColor: UIColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let pill = CGRect(
            x: (size.width - textSize.width) / 2 - 24 * unit, y: size.height - textSize.height - bottom * unit - 20 * unit,
            width: textSize.width + 48 * unit, height: textSize.height + 20 * unit
        )
        UIColor.black.withAlphaComponent(0.6).setFill()
        UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 24 * unit, y: pill.minY + 10 * unit), withAttributes: attributes)
    }

    // MARK: - Video

    /// The wipe film: the then photo, the now photo sweeping in from the
    /// left, held under the credit.
    static func render(
        then: ThenNowPhoto, now: ThenNowPhoto, place: String?, showsCredit: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let size = videoSize
        let duration = ThenAndNowPlan.videoDuration
        return try await ReelRenderer.writeVideo(name: "then-now", size: size, fps: fps, duration: duration, progress: progress) { time in
            drawWipe(
                then: then, now: now, wipe: ThenAndNowPlan.wipe(at: time), place: place,
                credit: showsCredit && time >= duration - ThenAndNowPlan.videoEnd, in: size
            )
        }
    }
}
