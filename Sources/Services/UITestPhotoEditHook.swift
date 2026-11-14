#if DEBUG
import CoreImage
import CoreImage.CIFilterBuiltins
import Observation
import Photos
import SwiftUI

/// Test only. `-uiTestEditAssetNamed <file name>` makes the app edit that
/// photo in place, through PhotoKit, the way Photos does: the asset keeps its
/// identifier, gains adjustment data and a rendered (colour-inverted) version,
/// and its modification date moves. It is how a scenario holds a photo that is
/// really edited — `simctl addmedia` can only add originals.
///
/// Without the argument nothing runs and nothing is drawn. The outcome is
/// published as a 1×1 accessibility element (`uiTestEditApplied`, or
/// `uiTestEditFailed` carrying the error as its label) that `RootView` overlays.
@MainActor
@Observable
final class UITestPhotoEditHook {
    enum State: Equatable {
        case idle
        case applied
        case failed(String)
    }

    static let shared = UITestPhotoEditHook()

    private(set) var state: State = .idle

    private struct HookError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Starts the edit when the launch argument names an asset.
    static func runIfRequested() {
        guard let name = UserDefaults.standard.string(forKey: "uiTestEditAssetNamed"), !name.isEmpty else { return }
        Task { @MainActor in
            do {
                try await shared.apply(assetNamed: name)
                shared.state = .applied
            } catch {
                shared.state = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(assetNamed name: String) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            throw HookError(message: "Photos access refused (\(status.rawValue))")
        }
        guard let asset = Self.findAsset(named: name) else {
            throw HookError(message: "No photo named \(name)")
        }
        // Already edited by an earlier launch: nothing to do.
        if asset.hasAdjustments { return }

        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, _ in
                if let input {
                    continuation.resume(returning: input)
                } else {
                    continuation.resume(throwing: HookError(message: "No editing input for \(name)"))
                }
            }
        }
        guard let url = input.fullSizeImageURL, let image = CIImage(contentsOf: url) else {
            throw HookError(message: "Cannot read \(name)")
        }
        let invert = CIFilter.colorInvert()
        invert.inputImage = image
        guard let rendered = invert.outputImage else { throw HookError(message: "Invert failed") }

        let output = PHContentEditingOutput(contentEditingInput: input)
        try CIContext().writeJPEGRepresentation(
            of: rendered,
            to: output.renderedContentURL,
            colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            options: [:]
        )
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: "app.swimmich.uitest.invert",
            formatVersion: "1",
            data: Data("invert".utf8)
        )
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    /// The image to edit. `simctl addmedia` renames what it imports
    /// (`L22-edit-on.png` lands in Photos as `IMG_0007.PNG`), so a name match
    /// is tried first and, failing that, the newest image whose original file
    /// has the same extension as `name` — a scenario imports one such file.
    private static func findAsset(named name: String) -> PHAsset? {
        let wantedExtension = (name as NSString).pathExtension.lowercased()
        let fetched = PHAsset.fetchAssets(with: .image, options: nil)
        var exact: PHAsset?
        var newestOfType: PHAsset?
        fetched.enumerateObjects { asset, _, stop in
            guard let photo = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else { return }
            if photo.originalFilename == name {
                exact = asset
                stop.pointee = true
                return
            }
            guard (photo.originalFilename as NSString).pathExtension.lowercased() == wantedExtension else { return }
            let date = asset.creationDate ?? .distantPast
            if date >= (newestOfType?.creationDate ?? .distantPast) { newestOfType = asset }
        }
        return exact ?? newestOfType
    }
}

/// The 1×1 element a scenario waits for. Invisible and never hit-testable.
struct UITestPhotoEditProbe: View {
    var body: some View {
        switch UITestPhotoEditHook.shared.state {
        case .idle:
            EmptyView()
        case .applied:
            Color.white.opacity(0.01)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("uiTestEditApplied")
        case .failed(let message):
            Color.white.opacity(0.01)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("uiTestEditFailed")
                .accessibilityLabel(message)
        }
    }
}
#endif
