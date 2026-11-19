import Foundation
import UIKit
import Vision

/// "Growing Up" orchestration: every photo of a person, cut into stretches of
/// time; in each, the photo where the person's face is largest (Immich's face
/// boxes say which face is theirs), its eyes found by Vision on the preview.
/// The faces, aligned eye to eye, make the timelapse the player shows and the
/// export writes (`GrowingUpRenderer`), with the person's age under each face
/// when they have a birthday.
@MainActor
@Observable
final class GrowingUpViewModel: Identifiable {

    enum ExportState: Equatable {
        case idle
        case rendering(Double)
        case saving
        case done
        case failed(String)
    }

    /// The canvas the player's frames are aligned on: the film's shape, small
    /// enough to hold sixty of them.
    static let playerCanvas = CGSize(width: 360, height: 640)
    /// Photos of the person read at most, from their first.
    static let maxAssets = 5000
    /// A face turned further than this is a profile: it does not align.
    static let maxYawDegrees = 30.0

    let person: PersonResponseDto
    let token: String?
    /// The address in use, read at every use (L-26).
    var baseURL: URL { baseURLProvider() }
    private let baseURLProvider: @Sendable () -> URL
    private let client: any ImmichClient
    private let photos: PhotoLibraryService
    private let session: @Sendable () -> URLSession

    private(set) var isPreparing = true
    private(set) var preparationProgress = 0.0
    private(set) var errorMessage: String?
    /// The faces, oldest first.
    private(set) var frames: [GrowingUpFrame] = []
    private var preparationStarted = false

    var speed: GrowingUpSpeed = .normal
    var showsCredit = true

    private(set) var exportState: ExportState = .idle
    /// The exported film, kept once it is in the photo library for the share sheet.
    private(set) var exportedVideoURL: URL?
    private var exportTask: Task<Void, Never>?

    init(
        person: PersonResponseDto,
        client: any ImmichClient,
        baseURL: @escaping @Sendable () -> URL,
        token: String?,
        photos: PhotoLibraryService,
        session: @escaping @Sendable () -> URLSession
    ) {
        self.person = person
        self.client = client
        self.baseURLProvider = baseURL
        self.token = token
        self.photos = photos
        self.session = session
    }

    var duration: Double { GrowingUpPlan.duration(frameCount: frames.count, speed: speed) }

    // MARK: - Preparation

    func prepare() async {
        guard !preparationStarted else { return }
        preparationStarted = true
        defer { isPreparing = false }
        let assets: [AssetReactItem]
        do {
            assets = try await fetchAssets()
        } catch {
            if Task.isCancelled { preparationStarted = false }
            errorMessage = error.userFacingMessage
            return
        }
        var dates: [String: Date] = [:]
        for asset in assets { dates[asset.id] = PhotoDumpViewModel.date(asset.fileCreatedAt) }
        let stretches = GrowingUpPlan.stretches(assets, dates: dates)
        guard stretches.count >= GrowingUpPlan.minFrames else {
            errorMessage = String(localized: "Not enough photos of this person over time for a timelapse.")
            return
        }

        // Four stretches at a time: each asks for up to three photos' faces,
        // then downloads previews until one has a face that aligns.
        var found: [GrowingUpFrame] = []
        var done = 0
        var next = 0
        await withTaskGroup(of: GrowingUpFrame?.self) { group in
            func addNext() {
                guard next < stretches.count else { return }
                let candidates = stretches[next]
                next += 1
                group.addTask { await self.frame(from: candidates, dates: dates) }
            }
            for _ in 0..<4 { addNext() }
            for await frame in group {
                if let frame { found.append(frame) }
                done += 1
                preparationProgress = Double(done) / Double(stretches.count)
                if Task.isCancelled { group.cancelAll() } else { addNext() }
            }
        }
        guard !Task.isCancelled else {
            preparationStarted = false
            return
        }
        found.sort { $0.asset.fileCreatedAt < $1.asset.fileCreatedAt }
        guard found.count >= GrowingUpPlan.minFrames else {
            errorMessage = String(localized: "Not enough clear, front-facing photos of this person for a timelapse.")
            return
        }
        frames = found
    }

    /// Every photo of the person, oldest first, a page at a time.
    private func fetchAssets() async throws -> [AssetReactItem] {
        var assets: [AssetReactItem] = []
        var seen = Set<String>()
        var page: Int? = 1
        while let current = page, assets.count < Self.maxAssets {
            try Task.checkCancellation()
            var dto = MetadataSearchDto()
            dto.personIds = [person.id]
            dto.type = "IMAGE"
            dto.order = "asc"
            dto.size = 1000
            dto.page = current
            let response = try await client.searchMetadata(dto: dto)
            for item in response.assets.items where seen.insert(item.id).inserted {
                assets.append(AssetReactItem(from: item))
            }
            page = response.assets.nextPage.flatMap(Int.init)
        }
        return assets
    }

    /// The first of `candidates` — largest face first — whose face Vision
    /// finds front-facing and sharp enough to align.
    private nonisolated func frame(from candidates: [AssetReactItem], dates: [String: Date]) async -> GrowingUpFrame? {
        let client = self.client
        let personID = person.id
        let birthDate = person.birthDate
        let session = self.session
        let token = self.token
        let base = await baseURL
        // This person's face in each candidate, as a share of the photo.
        let faced = await withTaskGroup(of: (AssetReactItem, AssetFaceResponseDto, Double)?.self) { group in
            for asset in candidates {
                group.addTask {
                    guard let faces = try? await client.getFaces(assetId: asset.id),
                          let face = faces.first(where: { $0.person?.id == personID }),
                          face.imageWidth > 0, face.imageHeight > 0 else { return nil }
                    let area = Double((face.boundingBoxX2 - face.boundingBoxX1) * (face.boundingBoxY2 - face.boundingBoxY1))
                    return (asset, face, area / Double(face.imageWidth * face.imageHeight))
                }
            }
            var out: [(AssetReactItem, AssetFaceResponseDto, Double)] = []
            for await result in group {
                if let result { out.append(result) }
            }
            return out.sorted { $0.2 > $1.2 }
        }
        // A level face is kept as soon as it is found; a leaning one waits for
        // a better one in its stretch (turned level, the photo spins).
        var found: [(GrowingUpFrame, GrowingUpEyes)] = []
        for (asset, face, _) in faced {
            if Task.isCancelled { return nil }
            let url = ImmichAssetURL.thumbnail(assetId: asset.id, thumbhash: asset.thumbhash ?? "", baseURL: base, size: .preview)
            guard let (data, _) = try? await AssetFileTransfer.fetchData(from: url, token: token, session: session()),
                  let image = UIImage(data: data)?.cgImage,
                  let eyes = await Self.eyes(in: image, face: face),
                  await !Self.isDocument(image) else { continue }
            let date = dates[asset.id] ?? Date()
            let day = GrowingUpPlan.localDay(of: asset, date: date)
            let frame = GrowingUpFrame(
                asset: asset,
                imageData: data,
                eyes: eyes,
                age: GrowingUpPlan.ageLabel(birthDate: birthDate, takenOn: day),
                year: day.map { String($0.year) } ?? ""
            )
            found.append((frame, eyes))
            if eyes.tiltDegrees <= GrowingUpPlan.levelTilt { break }
        }
        return GrowingUpPlan.preferredFace(found)
    }

    /// A photo of an ID card, a screen or a poster: the face is in it, but it
    /// is not a portrait. Vision's fast text recognition, on the preview.
    private nonisolated static func isDocument(_ image: CGImage) async -> Bool {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        guard let observations = try? await request.perform(on: image) else { return false }
        return GrowingUpPlan.looksLikeDocument(textBoxes: observations.map(\.boundingBox.cgRect))
    }

    /// The eyes of the face Immich boxed, found by Vision in a crop around
    /// the box; nil for a profile or a face too small to enlarge.
    private nonisolated static func eyes(in image: CGImage, face: AssetFaceResponseDto) async -> GrowingUpEyes? {
        let sx = Double(image.width) / Double(face.imageWidth)
        let sy = Double(image.height) / Double(face.imageHeight)
        let box = CGRect(
            x: Double(face.boundingBoxX1) * sx, y: Double(face.boundingBoxY1) * sy,
            width: Double(face.boundingBoxX2 - face.boundingBoxX1) * sx,
            height: Double(face.boundingBoxY2 - face.boundingBoxY1) * sy
        )
        let crop = box.insetBy(dx: -box.width * 0.6, dy: -box.height * 0.6)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !crop.isEmpty, let cropped = image.cropping(to: crop),
              let observations = try? await DetectFaceLandmarksRequest().perform(on: cropped) else { return nil }
        let cropSize = CGSize(width: cropped.width, height: cropped.height)
        let center = CGPoint(x: cropSize.width / 2, y: cropSize.height / 2)
        // The face nearest the middle of the crop: the one Immich boxed.
        let observation = observations.min { a, b in
            let ra = a.boundingBox.toImageCoordinates(cropSize, origin: .upperLeft)
            let rb = b.boundingBox.toImageCoordinates(cropSize, origin: .upperLeft)
            return hypot(ra.midX - center.x, ra.midY - center.y) < hypot(rb.midX - center.x, rb.midY - center.y)
        }
        guard let observation, let landmarks = observation.landmarks,
              abs(observation.yaw.converted(to: .degrees).value) <= maxYawDegrees else { return nil }
        func point(_ pupil: FaceObservation.Landmarks2D.Region, _ eye: FaceObservation.Landmarks2D.Region) -> CGPoint? {
            let points = pupil.pointsInImageCoordinates(cropSize, origin: .upperLeft)
            let source = points.isEmpty ? eye.pointsInImageCoordinates(cropSize, origin: .upperLeft) : points
            guard !source.isEmpty else { return nil }
            let sum = source.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            return CGPoint(x: sum.x / CGFloat(source.count) + crop.minX, y: sum.y / CGFloat(source.count) + crop.minY)
        }
        guard let a = point(landmarks.leftPupil, landmarks.leftEye),
              let b = point(landmarks.rightPupil, landmarks.rightEye) else { return nil }
        let eyes = GrowingUpEyes(a, b)
        return eyes.distance >= GrowingUpPlan.minEyeDistance ? eyes : nil
    }

    // MARK: - Player

    /// The face at `index` aligned on the player's canvas, made once.
    func playerImage(at index: Int) -> UIImage? {
        guard frames.indices.contains(index) else { return nil }
        let frame = frames[index]
        if let image = playerImageCache[frame.id] { return image }
        guard let aligned = GrowingUpRenderer.aligned(frame, canvas: Self.playerCanvas) else { return nil }
        let image = UIImage(cgImage: aligned)
        playerImageCache[frame.id] = image
        return image
    }

    /// Written while the player reads: not observed, or each new image would
    /// redraw the player that asked for it.
    @ObservationIgnored private var playerImageCache: [String: UIImage] = [:]

    // MARK: - Export

    func startExport() {
        guard exportTask == nil, !frames.isEmpty else { return }
        exportState = .rendering(0)
        let frames = frames
        let speed = speed
        let credit = showsCredit
        let photos = photos
        exportTask = Task {
            defer { exportTask = nil }
            do {
                // Off the main actor (a nonisolated function), and cancelled
                // with this task.
                let url = try await GrowingUpRenderer.render(frames: frames, speed: speed, showsCredit: credit) { value in
                    Task { @MainActor [weak self] in
                        if case .rendering = self?.exportState { self?.exportState = .rendering(value) }
                    }
                }
                exportState = .saving
                do {
                    _ = try await photos.saveVideo(at: url)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                discardExportedVideo()
                exportedVideoURL = url
                exportState = .done
            } catch is CancellationError {
                exportState = .idle
            } catch {
                exportState = error.userFacingMessage.map { .failed($0) } ?? .idle
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func dismissExportResult() {
        exportState = .idle
    }

    func discardExportedVideo() {
        if let exportedVideoURL { try? FileManager.default.removeItem(at: exportedVideoURL) }
        exportedVideoURL = nil
    }
}
