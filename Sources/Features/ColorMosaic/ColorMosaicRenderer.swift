import UIKit

/// Draws the exported mosaic: every cell aspect-filled with its photo (its
/// average color when the photo did not load), and the "Made with Swimmich"
/// credit when it is on.
enum MosaicRenderer {

    static func render(
        layout: MosaicLayout,
        format: MosaicFormat,
        images: [String: UIImage],
        showsCredit: Bool
    ) -> UIImage {
        let size = format.pixelSize
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        return UIGraphicsImageRenderer(size: size, format: rendererFormat).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, tile) in layout.cells.enumerated() {
                let rect = cellRect(index, layout: layout, size: size)
                if let image = images[tile.id] {
                    drawAspectFill(image, in: rect, context: context.cgContext)
                } else {
                    UIColor(red: tile.color.red, green: tile.color.green, blue: tile.color.blue, alpha: 1).setFill()
                    context.fill(rect)
                }
            }
            if showsCredit { drawCredit(in: size) }
        }
    }

    /// The cell's rectangle, its edges rounded to whole pixels so neighbors
    /// meet without a hairline between them.
    static func cellRect(_ index: Int, layout: MosaicLayout, size: CGSize) -> CGRect {
        let column = index % layout.columns
        let row = index / layout.columns
        let x0 = (CGFloat(column) * size.width / CGFloat(layout.columns)).rounded()
        let x1 = (CGFloat(column + 1) * size.width / CGFloat(layout.columns)).rounded()
        let y0 = (CGFloat(row) * size.height / CGFloat(layout.rows)).rounded()
        let y1 = (CGFloat(row + 1) * size.height / CGFloat(layout.rows)).rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func drawAspectFill(_ image: UIImage, in rect: CGRect, context: CGContext) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        context.saveGState()
        context.clip(to: rect)
        image.draw(in: CGRect(
            x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
            width: drawn.width, height: drawn.height
        ))
        context.restoreGState()
    }

    /// A dark pill at the bottom center: readable over any photo, small
    /// enough to leave the mosaic the picture.
    private static func drawCredit(in size: CGSize) {
        let text = String(localized: "Made with Swimmich") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let pill = CGRect(
            x: (size.width - textSize.width) / 2 - 24,
            y: size.height - textSize.height - 64,
            width: textSize.width + 48,
            height: textSize.height + 20
        )
        UIColor.black.withAlphaComponent(0.6).setFill()
        UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 24, y: pill.minY + 10), withAttributes: attributes)
    }
}
