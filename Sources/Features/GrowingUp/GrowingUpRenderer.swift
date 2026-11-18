import AVFoundation
import UIKit

/// A face of the timelapse: its photo (the preview, as the server sent it),
/// its eyes in that photo and what is written under it.
struct GrowingUpFrame: Identifiable, Sendable {
    let asset: AssetReactItem
    let imageData: Data
    let eyes: GrowingUpEyes
    /// "2 years old", when the person has a birthday.
    let age: String?
    /// The year the photo was taken.
    let year: String

    var id: String { asset.id }
}

/// Draws the timelapse: each face aligned on the film's eye line
/// (`GrowingUpPlan.alignment`), the cross-fades, the age and year, the credit;
/// and writes the film, 1080 × 1920 at 30 frames a second.
enum GrowingUpRenderer {

    static let videoSize = CGSize(width: 1080, height: 1920)
    static let fps: Int32 = 30

    /// The backdrop is drawn this many times smaller, then enlarged: the
    /// enlargement is its blur.
    static let backdropReduction: CGFloat = 40

    /// `image` moved so its eyes sit on the film's eye line, over a blurred,
    /// darkened copy of itself filling the film (`backdropCrop`): a photo
    /// turned level leaves no black corner.
    static func aligned(_ image: CGImage, eyes: GrowingUpEyes, canvas: CGSize) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let photo = UIImage(cgImage: image)
        let photoRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let small = CGSize(
            width: max(1, (canvas.width / backdropReduction).rounded()),
            height: max(1, (canvas.height / backdropReduction).rounded())
        )
        let backdrop = UIGraphicsImageRenderer(size: small, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: small))
            context.cgContext.interpolationQuality = .medium
            let crop = GrowingUpPlan.backdropCrop(eyes: eyes, imageSize: photoRect.size, canvas: canvas)
            let scale = small.width / crop.width
            photo.draw(in: CGRect(
                x: -crop.minX * scale, y: -crop.minY * scale,
                width: photoRect.width * scale, height: photoRect.height * scale
            ))
        }
        let rendered = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            context.cgContext.interpolationQuality = .high
            backdrop.draw(in: CGRect(origin: .zero, size: canvas))
            UIColor.black.withAlphaComponent(0.35).setFill()
            // `fill(_:)` alone copies (UIRectFill): the backdrop would be replaced, not darkened.
            context.fill(CGRect(origin: .zero, size: canvas), blendMode: .normal)
            context.cgContext.concatenate(GrowingUpPlan.alignment(eyes: eyes, canvas: canvas))
            photo.draw(in: photoRect)
        }
        return rendered.cgImage
    }

    /// Decodes the photo of `frame` and aligns it on `canvas`.
    static func aligned(_ frame: GrowingUpFrame, canvas: CGSize) -> CGImage? {
        guard let image = UIImage(data: frame.imageData)?.cgImage else { return nil }
        return aligned(image, eyes: frame.eyes, canvas: canvas)
    }

    /// The age and the year under the face, and the credit over the last one.
    /// Drawn in UIKit coordinates, in the current context.
    static func drawCaption(age: String?, year: String, credit: Bool, in size: CGSize) {
        let unit = size.width / 1080
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 12 * unit
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        var y = size.height * 0.78
        if let age {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 78 * unit, weight: .heavy),
                .foregroundColor: UIColor.white, .shadow: shadow, .paragraphStyle: paragraph
            ]
            let height = (age as NSString).size(withAttributes: attributes).height
            (age as NSString).draw(in: CGRect(x: 0, y: y, width: size.width, height: height), withAttributes: attributes)
            y += height
        }
        let yearAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: (age == nil ? 78 : 44) * unit, weight: age == nil ? .heavy : .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(age == nil ? 1 : 0.85),
            .shadow: shadow, .paragraphStyle: paragraph
        ]
        let yearHeight = (year as NSString).size(withAttributes: yearAttributes).height
        (year as NSString).draw(in: CGRect(x: 0, y: y, width: size.width, height: yearHeight), withAttributes: yearAttributes)

        guard credit else { return }
        let text = String(localized: "Made with Swimmich") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 30 * unit, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let pill = CGRect(
            x: (size.width - textSize.width) / 2 - 24 * unit, y: size.height - textSize.height - 84 * unit,
            width: textSize.width + 48 * unit, height: textSize.height + 20 * unit
        )
        UIColor.black.withAlphaComponent(0.6).setFill()
        UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
        text.draw(at: CGPoint(x: pill.minX + 24 * unit, y: pill.minY + 10 * unit), withAttributes: attributes)
    }

    /// The caption of the frame on screen: the next face's once the fade is
    /// half way.
    static func caption(_ frames: [GrowingUpFrame], index: Int, blend: Double) -> GrowingUpFrame? {
        guard frames.indices.contains(index) else { return nil }
        return blend > 0.5 && frames.indices.contains(index + 1) ? frames[index + 1] : frames[index]
    }

    // MARK: - Export

    /// Writes the film to a temporary file and returns it. Each face is
    /// aligned once, when it comes on screen; two are held at a time.
    static func render(
        frames: [GrowingUpFrame],
        speed: GrowingUpSpeed,
        showsCredit: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let size = videoSize
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("growing-up-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps
            ] as [String: Any]
        ]
        // `AVAssetWriterInput` raises an Objective-C exception — an abort Swift
        // cannot catch — on settings it refuses: checked first.
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw APIError.decoding("Unsupported video settings")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? APIError.decoding("Failed to start video writer") }
        writer.startSession(atSourceTime: .zero)

        let duration = GrowingUpPlan.duration(frameCount: frames.count, speed: speed)
        let total = max(1, Int((duration * Double(fps)).rounded(.up)))
        var cache: [Int: CGImage] = [:]
        do {
            for frameNumber in 0..<total {
                try Task.checkCancellation()
                let time = Double(frameNumber) / Double(fps)
                let (index, blend) = GrowingUpPlan.frame(at: time, frameCount: frames.count, speed: speed)
                for key in cache.keys where key < index { cache[key] = nil }
                for needed in [index, index + 1] where frames.indices.contains(needed) && cache[needed] == nil {
                    cache[needed] = aligned(frames[needed], canvas: size)
                }
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? APIError.decoding("No pixel buffer pool") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw APIError.decoding("No pixel buffer") }
                let caption = caption(frames, index: index, blend: blend)
                let isEnd = time >= duration - GrowingUpPlan.endHold
                draw(into: buffer, size: size) { context in
                    if let a = cache[index] { context.draw(a, in: CGRect(origin: .zero, size: size)) }
                    if blend > 0, let b = cache[index + 1] {
                        context.setAlpha(blend)
                        context.draw(b, in: CGRect(origin: .zero, size: size))
                        context.setAlpha(1)
                    }
                    // UIKit's top-left coordinates for the text.
                    context.saveGState()
                    context.translateBy(x: 0, y: size.height)
                    context.scaleBy(x: 1, y: -1)
                    UIGraphicsPushContext(context)
                    if let caption {
                        drawCaption(age: caption.age, year: caption.year, credit: showsCredit && isEnd, in: size)
                    }
                    UIGraphicsPopContext()
                    context.restoreGState()
                }
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frameNumber), timescale: fps))
                if frameNumber % 15 == 0 { progress(Double(frameNumber) / Double(total)) }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? APIError.decoding("Video writing failed") }
            progress(1)
            return url
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Runs `body` on a bitmap context over `buffer` (Core Graphics' bottom-left origin).
    private static func draw(into buffer: CVPixelBuffer, size: CGSize, _ body: (CGContext) -> Void) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        body(context)
    }
}
