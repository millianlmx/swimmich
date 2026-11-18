import AVFoundation
import UIKit

/// A photo of the reel: its preview as the server sent it, where its subject
/// is and the year it was taken.
struct ReelShot: Identifiable, Sendable {
    let asset: AssetReactItem
    let imageData: Data
    let focus: CGPoint
    let year: Int?
    /// "Lisbon, Portugal", when the server knows where it was taken.
    var place: String?

    var id: String { asset.id }
}

/// Draws the reel's frames — the title card, each photo pushed in on its
/// beat, the year, the credit — and writes the film, 1080 × 1920 at 30 frames
/// a second.
enum ReelRenderer {

    static let videoSize = CGSize(width: 1080, height: 1920)
    static let fps: Int32 = 30

    /// One frame, in UIKit coordinates, in the current context. `image` is
    /// the photo on screen (the cover for the title card).
    static func drawFrame(
        segment: ReelPlan.Segment,
        progress: Double,
        image: UIImage?,
        shot: ReelShot?,
        title: String,
        subtitle: String?,
        credit: Bool,
        showsPlace: Bool,
        zooms: Bool,
        in size: CGSize
    ) {
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        defer { context?.restoreGState() }
        // The photo is drawn larger than the frame: nothing past its edges.
        context?.clip(to: CGRect(origin: .zero, size: size))
        UIColor.black.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        if let image, let shot {
            let visible = ReelPlan.visibleRect(
                imageSize: image.size, canvas: size, focus: shot.focus,
                progress: zooms && segment != .title ? progress : 0
            )
            image.draw(in: ReelPlan.drawRect(imageSize: image.size, visible: visible, canvas: size))
        }
        let unit = size.width / 1080
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 12 * unit
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        switch segment {
        case .title:
            UIColor.black.withAlphaComponent(0.45).setFill()
            UIRectFillUsingBlendMode(CGRect(origin: .zero, size: size), .normal)
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 110 * unit, weight: .heavy),
                .foregroundColor: UIColor.white, .shadow: shadow, .paragraphStyle: paragraph
            ]
            let box = CGRect(x: 60 * unit, y: 0, width: size.width - 120 * unit, height: size.height)
            let titleHeight = (title as NSString).boundingRect(
                with: box.size, options: [.usesLineFragmentOrigin], attributes: titleAttributes, context: nil
            ).height
            var y = (size.height - titleHeight) / 2 - 40 * unit
            (title as NSString).draw(in: CGRect(x: box.minX, y: y, width: box.width, height: titleHeight), withAttributes: titleAttributes)
            y += titleHeight + 16 * unit
            if let subtitle {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 48 * unit, weight: .semibold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.9), .shadow: shadow, .paragraphStyle: paragraph
                ]
                (subtitle as NSString).draw(in: CGRect(x: box.minX, y: y, width: box.width, height: 70 * unit), withAttributes: attributes)
            }
        case .photo:
            // The place above the year, both clear of the credit's pill.
            var y = size.height - 220 * unit
            if let year = shot?.year {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 44 * unit, weight: .bold),
                    .foregroundColor: UIColor.white, .shadow: shadow
                ]
                (String(year) as NSString).draw(at: CGPoint(x: 64 * unit, y: y), withAttributes: attributes)
            }
            if showsPlace, let place = shot?.place {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 36 * unit, weight: .semibold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.9), .shadow: shadow
                ]
                y -= 48 * unit
                let width = size.width - 128 * unit
                (place as NSString).draw(
                    with: CGRect(x: 64 * unit, y: y, width: width, height: 48 * unit),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil
                )
            }
        }
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

    // MARK: - Export

    /// Writes the reel to a temporary file and returns it. Each photo is
    /// decoded when it comes on screen; one is held at a time.
    static func render(
        shots: [ReelShot],
        cover: ReelShot,
        title: String,
        subtitle: String?,
        showsCredit: Bool,
        showsPlaces: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let size = videoSize
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reel-\(UUID().uuidString).mp4")
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

        let duration = ReelPlan.duration(photoCount: shots.count)
        let total = max(1, Int((duration * Double(fps)).rounded(.up)))
        var decoded: (id: String, image: UIImage)?
        do {
            for frameNumber in 0..<total {
                try Task.checkCancellation()
                let time = Double(frameNumber) / Double(fps)
                let (segment, local) = ReelPlan.segment(at: time, photoCount: shots.count)
                let shot: ReelShot
                switch segment {
                case .title: shot = cover
                case .photo(let index): shot = shots[index]
                }
                if decoded?.id != shot.id {
                    decoded = UIImage(data: shot.imageData).map { (shot.id, $0) }
                }
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? APIError.decoding("No pixel buffer pool") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw APIError.decoding("No pixel buffer") }
                let image = decoded?.image
                let credit = showsCredit && time >= duration - ReelPlan.endHold
                draw(into: buffer, size: size) {
                    drawFrame(
                        segment: segment, progress: local, image: image, shot: shot,
                        title: title, subtitle: subtitle, credit: credit, showsPlace: showsPlaces,
                        zooms: true, in: size
                    )
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

    /// Runs `body` in UIKit coordinates on a bitmap context over `buffer`.
    private static func draw(into buffer: CVPixelBuffer, size: CGSize, _ body: () -> Void) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        body()
        UIGraphicsPopContext()
    }
}
