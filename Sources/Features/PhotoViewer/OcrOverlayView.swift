import SwiftUI

/// Detected-text layer drawn **on** the photo (gap #8, ocr-text).
///
/// Pure and non-interactive: it receives the boxes, the fitted image rect and
/// the viewer's zoom state, draws a quadrilateral per box, and attaches no
/// gesture — the pinch, double-tap and pan of `ZoomableImageView` keep
/// reaching the image underneath.
///
/// One mapping formula, normalized (0–1) → viewport points:
///
///     p  = (imageRect.minX + nx * imageRect.width, imageRect.minY + ny * imageRect.height)
///     p' = viewportCenter + (p - viewportCenter) * scale + offset
///
/// The second step mirrors the image's own `.scaleEffect(scale)` (anchored at
/// `.center`) followed by `.offset(offset)`. Point sizes stay constant: the
/// stroke is always 1.5 pt and the labels never scale, because this layer is a
/// sibling of the scaled image, not a child of it.
struct OcrOverlayView: View {
    let boxes: [AssetOcrResponseDto]
    /// Aspect-fit rect of the image inside the viewport, **before** zoom.
    let imageRect: CGRect
    let scale: CGFloat
    let offset: CGSize
    let viewportSize: CGSize

    /// Boxes worth labelling/announcing — a low-confidence box is drawn but
    /// never labelled (display threshold, not a data filter).
    private var confidentBoxes: [AssetOcrResponseDto] { boxes.filter(\.isConfident) }

    var body: some View {
        Canvas { context, _ in
            for box in boxes {
                let quad = box.quad.path(
                    in: imageRect, scale: scale, offset: offset, viewport: viewportSize
                )
                // The layer sits on the viewer's black: `immichPrimary` in light
                // appearance (#4250AF) is 2.996:1 there, under the 3:1 glyph bar.
                context.fill(quad, with: .color(PVFloating.accent.opacity(0.18)))
                context.stroke(quad, with: .color(PVFloating.accent), lineWidth: 1.5)

                guard box.isConfident else { continue }
                let label = context.resolve(
                    Text(box.text)
                        .font(.pvCaption)
                        .foregroundStyle(Color.textPrimaryPV)
                )
                let measured = label.measure(
                    in: CGSize(
                        width: max(viewportSize.width * 0.5, PVSpacing.s48),
                        height: .greatestFiniteMagnitude
                    )
                )
                let padding = PVSpacing.s4
                let boxSize = CGSize(
                    width: measured.width + padding * 2,
                    height: measured.height + padding * 2
                )
                let anchor = Self.screenPoint(
                    box.quad.topLeft,
                    imageRect: imageRect, scale: scale, offset: offset, viewport: viewportSize
                )
                // Sits above the box's top-left corner, kept inside the screen
                // so a box touching an edge keeps its label readable.
                let origin = CGPoint(
                    x: Self.clamp(anchor.x, min: 0, max: max(viewportSize.width - boxSize.width, 0)),
                    y: Self.clamp(anchor.y - boxSize.height, min: 0, max: max(viewportSize.height - boxSize.height, 0))
                )
                let plate = Path(
                    roundedRect: CGRect(origin: origin, size: boxSize),
                    cornerRadius: PVRadius.sm,
                    style: .continuous
                )
                context.fill(plate, with: .color(Color.bgPrimary))
                context.stroke(plate, with: .color(Color.separatorPV), lineWidth: 0.5)
                context.draw(label, in: plate.boundingRect.insetBy(dx: padding, dy: padding))
            }
        }
        .allowsHitTesting(false)
        // A `Canvas` publishes no element and the layer is not hit-testable:
        // without this the recognized text would be invisible to VoiceOver and
        // unreachable by identifier. Text order follows the ViewModel's.
        .accessibilityRepresentation {
            OcrTextBoxList(boxes: confidentBoxes)
        }
    }

    /// Maps one normalized point through the single formula documented above.
    static func screenPoint(
        _ normalized: CGPoint,
        imageRect: CGRect,
        scale: CGFloat,
        offset: CGSize,
        viewport: CGSize
    ) -> CGPoint {
        let point = CGPoint(
            x: imageRect.minX + normalized.x * imageRect.width,
            y: imageRect.minY + normalized.y * imageRect.height
        )
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        return CGPoint(
            x: center.x + (point.x - center.x) * scale + offset.width,
            y: center.y + (point.y - center.y) * scale + offset.height
        )
    }

    private static func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, lower), upper)
    }
}

extension OcrQuad {
    /// The box in viewport coordinates — four corners, so a tilted box stays
    /// tilted (an axis-aligned rect would erase the angle).
    func path(in imageRect: CGRect, scale: CGFloat, offset: CGSize, viewport: CGSize) -> Path {
        let points = corners.map {
            OcrOverlayView.screenPoint(
                $0, imageRect: imageRect, scale: scale, offset: offset, viewport: viewport
            )
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

/// Accessibility stand-in for the drawn layer: the recognized texts, in the
/// ViewModel's reading order, each reachable by `viewerOcrText_<index>`.
private struct OcrTextBoxList: View {
    let boxes: [AssetOcrResponseDto]

    var body: some View {
        VStack(alignment: .leading) {
            ForEach(Array(boxes.enumerated()), id: \.element.id) { index, box in
                Text(box.text)
                    .accessibilityIdentifier("viewerOcrText_\(index)")
            }
        }
    }
}
