import Foundation
import UIKit
import Vision

/// Looks at photos on their server thumbnails — their quality
/// (`RoadTripPhotoScore`), a feature print to tell two shots of the same
/// moment apart, and where their subject is. Shared by the photo dump and the
/// reel, which pick from what it finds.
@MainActor
enum PhotoLooker {

    /// Feature-print distance under which two photos show the same moment.
    static let duplicateDistance = 0.4
    /// Photos taken this close together are a burst: the same moment.
    static let burstInterval: TimeInterval = 3

    /// Downloads the thumbnails of `sample` in batches of 8 (the address read
    /// per batch — L-26) and looks at each off the main actor, reporting the
    /// share done after each batch. A photo whose thumbnail does not load is
    /// left out.
    static func look(
        at sample: [AssetReactItem],
        baseURL: () -> URL,
        token: String?,
        session: @escaping @Sendable () -> URLSession,
        progress: (Double) -> Void
    ) async -> [(DumpCandidate, FeaturePrintObservation?)] {
        var found: [(DumpCandidate, FeaturePrintObservation?)] = []
        let chunkSize = 8
        var offset = 0
        while offset < sample.count {
            if Task.isCancelled { break }
            let base = baseURL()
            let chunk = Array(sample[offset..<min(offset + chunkSize, sample.count)])
            let results = await withTaskGroup(of: (DumpCandidate, FeaturePrintObservation?)?.self) { group in
                for asset in chunk {
                    group.addTask {
                        let url = ImmichAssetURL.thumbnail(
                            assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: base, size: .thumbnail
                        )
                        guard let (data, _) = try? await AssetFileTransfer.fetchData(from: url, token: token, session: session()),
                              let image = UIImage(data: data), let pixels = image.cgImage,
                              image.size.height > 0 else { return nil }
                        return await look(at: pixels, asset: asset, aspect: image.size.width / image.size.height)
                    }
                }
                var out: [(DumpCandidate, FeaturePrintObservation?)] = []
                for await result in group {
                    if let result { out.append(result) }
                }
                return out
            }
            // In the order of the sample: a search's best matches stay first.
            let rank = Dictionary(uniqueKeysWithValues: chunk.enumerated().map { ($1.id, $0) })
            found.append(contentsOf: results.sorted { (rank[$0.0.id] ?? 0) < (rank[$1.0.id] ?? 0) })
            offset += chunkSize
            progress(Double(min(offset, sample.count)) / Double(sample.count))
        }
        return found
    }

    private nonisolated static func look(
        at image: CGImage, asset: AssetReactItem, aspect: Double
    ) async -> (DumpCandidate, FeaturePrintObservation?) {
        let score = await RoadTripPhotoScore.score(image)
        let print = try? await GenerateImageFeaturePrintRequest().perform(on: image)
        var focus = CGPoint(x: 0.5, y: 0.5)
        if let saliency = try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: image),
           let first = saliency.salientObjects.first {
            // Vision's rectangles have their origin at the bottom-left.
            let union = saliency.salientObjects.dropFirst().reduce(first.boundingBox.cgRect) { $0.union($1.boundingBox.cgRect) }
            focus = CGPoint(x: union.midX, y: 1 - union.midY)
        }
        let candidate = DumpCandidate(asset: asset, score: score, focus: focus, aspect: aspect)
        return (candidate, print)
    }

    /// Two photos of the same moment: taken within a burst, or alike to Vision.
    static func isDuplicate(
        _ a: DumpCandidate, _ b: DumpCandidate,
        prints: [String: FeaturePrintObservation], dates: [String: Date]
    ) -> Bool {
        guard a.id != b.id else { return true }
        if let ta = dates[a.id], let tb = dates[b.id], abs(ta.timeIntervalSince(tb)) < burstInterval {
            return true
        }
        guard let pa = prints[a.id], let pb = prints[b.id],
              let distance = try? pa.distance(to: pb) else { return false }
        return distance < duplicateDistance
    }
}
