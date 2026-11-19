import UIKit

/// A best shot: its preview and where its subject is.
struct WrappedShot: Sendable {
    let image: UIImage
    let focus: CGPoint
}

/// Everything the cards show, gathered by `WrappedViewModel`.
struct WrappedContent {
    let year: Int
    let total: Int
    let monthCounts: [Int]
    let busiestDay: (day: CalendarDay, photos: Int)?
    let people: [(person: WrappedPerson, face: UIImage?)]
    /// The year's map poster (`MapPosterRenderer`, story format).
    let placesPoster: UIImage?
    let places: MapPosterStats?
    /// The year's photos as colors (their thumbhashes).
    let colors: [MosaicTile]
    /// The thumbnails of the photos the colors card shows, by asset id: a
    /// photo missing keeps its color.
    let colorImages: [String: UIImage]
    let best: [WrappedShot]
}

/// Draws the story's cards, 1080 × 1920 each: bold color, big numbers, one
/// idea a card — the shape of the year-in-review stories people share.
enum WrappedRenderer {

    static let size = CGSize(width: 1080, height: 1920)
    static let margin: CGFloat = 72

    static func render(_ card: WrappedCard, content: WrappedContent, showsCredit: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            switch card {
            case .intro: intro(content, context: context.cgContext)
            case .months: months(content, context: context.cgContext)
            case .people: people(content, context: context.cgContext)
            case .places: places(content, context: context.cgContext)
            case .colors: colors(content, context: context.cgContext)
            case .best: best(content, context: context.cgContext)
            case .outro: outro(content, context: context.cgContext, showsCredit: showsCredit)
            }
            if showsCredit, card != .places {
                text(String(localized: "Swimmich Wrapped · \(String(content.year))"), size: 30, weight: .bold,
                     color: UIColor.white.withAlphaComponent(0.75), in: CGRect(x: margin, y: 64, width: size.width - margin * 2, height: 40))
            }
        }
    }

    // MARK: - Cards

    private static func intro(_ content: WrappedContent, context: CGContext) {
        gradient(context, top: UIColor(red: 0.45, green: 0.18, blue: 0.95, alpha: 1), bottom: UIColor(red: 1, green: 0.42, blue: 0.32, alpha: 1))
        text(String(localized: "Your year in photos"), size: 60, weight: .bold, color: .white,
             in: CGRect(x: margin, y: 560, width: size.width - margin * 2, height: 80))
        text(String(content.year), size: 300, weight: .black, color: .white,
             in: CGRect(x: margin - 20, y: 640, width: size.width, height: 340))
        text(String(localized: "\(content.total) photos"), size: 72, weight: .heavy, color: UIColor.white.withAlphaComponent(0.92),
             in: CGRect(x: margin, y: 1010, width: size.width - margin * 2, height: 96))
    }

    private static func months(_ content: WrappedContent, context: CGContext) {
        let accent = UIColor(red: 0.35, green: 0.95, blue: 0.65, alpha: 1)
        gradient(context, top: UIColor(red: 0.04, green: 0.10, blue: 0.22, alpha: 1), bottom: UIColor(red: 0.02, green: 0.05, blue: 0.12, alpha: 1))
        text(String(localized: "Month by month"), size: 76, weight: .heavy, color: .white,
             in: CGRect(x: margin, y: 200, width: size.width - margin * 2, height: 100))
        let chart = CGRect(x: margin, y: 420, width: size.width - margin * 2, height: 760)
        let gap: CGFloat = 14
        let barWidth = (chart.width - gap * 11) / 12
        let maximum = max(content.monthCounts.max() ?? 0, 1)
        let busiest = WrappedPlan.busiestMonth(content.monthCounts)
        let initials = Calendar.current.veryShortStandaloneMonthSymbols
        for (month, count) in content.monthCounts.enumerated() {
            let height = max(chart.height * CGFloat(count) / CGFloat(maximum), count > 0 ? 8 : 4)
            let bar = CGRect(x: chart.minX + CGFloat(month) * (barWidth + gap), y: chart.maxY - height, width: barWidth, height: height)
            (month == busiest ? accent : UIColor.white.withAlphaComponent(0.28)).setFill()
            UIBezierPath(roundedRect: bar, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 12, height: 12)).fill()
            if initials.indices.contains(month) {
                text(initials[month], size: 32, weight: .bold, color: UIColor.white.withAlphaComponent(0.7),
                     in: CGRect(x: bar.minX - 10, y: chart.maxY + 18, width: barWidth + 20, height: 44), align: .center)
            }
        }
        var y = chart.maxY + 120
        if let busiest {
            let name = Calendar.current.standaloneMonthSymbols[busiest].localizedCapitalized
            text(String(localized: "Busiest month"), size: 36, weight: .semibold, color: UIColor.white.withAlphaComponent(0.7),
                 in: CGRect(x: margin, y: y, width: size.width - margin * 2, height: 48))
            text(String(localized: "\(name) · \(content.monthCounts[busiest]) photos"), size: 60, weight: .heavy, color: accent,
                 in: CGRect(x: margin, y: y + 48, width: size.width - margin * 2, height: 80))
            y += 170
        }
        if let day = content.busiestDay, let date = date(day.day) {
            text(String(localized: "Busiest day"), size: 36, weight: .semibold, color: UIColor.white.withAlphaComponent(0.7),
                 in: CGRect(x: margin, y: y, width: size.width - margin * 2, height: 48))
            let label = date.formatted(.dateTime.day().month(.wide))
            text(String(localized: "\(label) · \(day.photos) photos"), size: 60, weight: .heavy, color: .white,
                 in: CGRect(x: margin, y: y + 48, width: size.width - margin * 2, height: 80))
        }
    }

    private static func people(_ content: WrappedContent, context: CGContext) {
        gradient(context, top: UIColor(red: 0.05, green: 0.42, blue: 0.30, alpha: 1), bottom: UIColor(red: 0.01, green: 0.16, blue: 0.12, alpha: 1))
        text(String(localized: "Your people"), size: 84, weight: .heavy, color: .white,
             in: CGRect(x: margin, y: 200, width: size.width - margin * 2, height: 110))
        var y: CGFloat = 400
        let face: CGFloat = 200
        for (rank, entry) in content.people.enumerated() {
            let circle = CGRect(x: margin + 70, y: y, width: face, height: face)
            text("\(rank + 1)", size: 64, weight: .black, color: UIColor.white.withAlphaComponent(0.5),
                 in: CGRect(x: margin - 10, y: y + 60, width: 70, height: 84))
            context.saveGState()
            UIBezierPath(ovalIn: circle).addClip()
            UIColor.white.withAlphaComponent(0.15).setFill()
            context.fill(circle)
            if let image = entry.face {
                let visible = ReelPlan.visibleRect(imageSize: image.size, canvas: circle.size, focus: CGPoint(x: 0.5, y: 0.45), progress: 0)
                image.draw(in: ReelPlan.drawRect(imageSize: image.size, visible: visible, canvas: circle.size).offsetBy(dx: circle.minX, dy: circle.minY))
            }
            context.restoreGState()
            let textX = circle.maxX + 40
            text(entry.person.name, size: 56, weight: .heavy, color: .white,
                 in: CGRect(x: textX, y: y + 40, width: size.width - textX - margin, height: 72))
            text(String(localized: "\(entry.person.photos) photos"), size: 38, weight: .semibold, color: UIColor.white.withAlphaComponent(0.75),
                 in: CGRect(x: textX, y: y + 112, width: size.width - textX - margin, height: 52))
            y += face + 56
        }
    }

    private static func places(_ content: WrappedContent, context: CGContext) {
        if let poster = content.placesPoster {
            poster.draw(in: CGRect(origin: .zero, size: size))
        } else {
            MapPosterRenderer.background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func colors(_ content: WrappedContent, context: CGContext) {
        if let layout = MosaicLayoutBuilder.build(tiles: content.colors, format: .story, arrangement: .rainbow) {
            MosaicRenderer.render(layout: layout, format: .story, images: content.colorImages, showsCredit: false)
                .draw(in: CGRect(origin: .zero, size: size))
        }
        UIColor.black.withAlphaComponent(0.55).setFill()
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: 420))
        // Two lines when the words need them ("Votre année en couleurs").
        text(String(localized: "Your year in colors"), size: 76, weight: .heavy, color: .white,
             in: CGRect(x: margin, y: 180, width: size.width - margin * 2, height: 230))
    }

    private static func best(_ content: WrappedContent, context: CGContext) {
        UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: size))
        text(String(localized: "Your best shots"), size: 84, weight: .heavy, color: .white,
             in: CGRect(x: margin, y: 200, width: size.width - margin * 2, height: 110))
        let gap: CGFloat = 12
        let side = (size.width - margin * 2 - gap * 2) / 3
        for (index, shot) in content.best.prefix(WrappedPlan.bestCount).enumerated() {
            let tile = CGRect(
                x: margin + CGFloat(index % 3) * (side + gap), y: 420 + CGFloat(index / 3) * (side + gap),
                width: side, height: side
            )
            context.saveGState()
            UIBezierPath(roundedRect: tile, cornerRadius: 18).addClip()
            let visible = ReelPlan.visibleRect(imageSize: shot.image.size, canvas: tile.size, focus: shot.focus, progress: 0)
            shot.image.draw(in: ReelPlan.drawRect(imageSize: shot.image.size, visible: visible, canvas: tile.size).offsetBy(dx: tile.minX, dy: tile.minY))
            context.restoreGState()
        }
    }

    private static func outro(_ content: WrappedContent, context: CGContext, showsCredit: Bool) {
        gradient(context, top: UIColor(red: 1, green: 0.42, blue: 0.32, alpha: 1), bottom: UIColor(red: 0.45, green: 0.18, blue: 0.95, alpha: 1))
        text(String(localized: "That was your \(String(content.year))"), size: 92, weight: .black, color: .white,
             in: CGRect(x: margin, y: 520, width: size.width - margin * 2, height: 240))
        var lines = [String(localized: "\(content.total) photos")]
        if let places = content.places, places.countryCount > 0 {
            lines.append(String(localized: "\(places.countryCount) countries"))
        }
        let names = content.people.prefix(3).map(\.person.name)
        if !names.isEmpty {
            lines.append(String(localized: "With \(names.formatted(.list(type: .and)))"))
        }
        var y: CGFloat = 820
        for line in lines {
            text(line, size: 58, weight: .bold, color: .white, in: CGRect(x: margin, y: y, width: size.width - margin * 2, height: 140))
            y += 110
        }
        if showsCredit {
            let label = String(localized: "Made with Swimmich") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.white]
            let textSize = label.size(withAttributes: attributes)
            let pill = CGRect(x: (size.width - textSize.width) / 2 - 28, y: size.height - 200, width: textSize.width + 56, height: textSize.height + 24)
            UIColor.black.withAlphaComponent(0.3).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
            label.draw(at: CGPoint(x: pill.minX + 28, y: pill.minY + 12), withAttributes: attributes)
        }
    }

    // MARK: - Helpers

    private static func gradient(_ context: CGContext, top: UIColor, bottom: UIColor) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]
        ) else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width * 0.3, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func text(
        _ string: String, size: CGFloat, weight: UIFont.Weight, color: UIColor, in rect: CGRect,
        align: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = align
        paragraph.lineBreakMode = .byWordWrapping
        (string as NSString).draw(
            with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph],
            context: nil
        )
    }

    private static func date(_ day: CalendarDay) -> Date? {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }

    // MARK: - Video

    /// The cards one after the other, each fading into the next.
    static func renderVideo(cards: [UIImage], progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let duration = WrappedPlan.videoDuration(cardCount: cards.count)
        return try await ReelRenderer.writeVideo(name: "wrapped", size: size, fps: 30, duration: duration, progress: progress) { time in
            let (index, fade) = WrappedPlan.card(at: time, cardCount: cards.count)
            cards[index].draw(in: CGRect(origin: .zero, size: size))
            if fade > 0, cards.indices.contains(index + 1) {
                cards[index + 1].draw(in: CGRect(origin: .zero, size: size), blendMode: .normal, alpha: fade)
            }
        }
    }
}
