import AVFoundation
import ImmichSharedKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Entry point of the share extension
/// (`NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).ShareViewController`).
///
/// It is the composition root: an extension has no `@Environment` and no
/// `DependencyContainer`, so the session, the upload client and the items are
/// all built here, once, before the first frame. Nothing is ever left silent —
/// every path either shows the sheet or ends the request.
final class ShareViewController: UIViewController {
    private var model: ShareExtensionViewModel?
    /// Kept so `cancel()` / `finish()` can end its session: one client (one
    /// session, one TLS handshake) per share.
    private var uploadClient: SharedUploadClient?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { await presentSheet() }
    }

    // MARK: - Composition

    private func presentSheet() async {
        // The app mirrors its session into the shared keychain group on every
        // path that establishes one; a nil here means the user is signed out.
        guard let session = WidgetSessionStore().load(), !session.token.isEmpty else {
            // An extension cannot call `UIApplication.open` (and
            // `extensionContext.open` does not exist for share-services), so the
            // signed-out case explains and offers a clean exit instead of
            // pretending it can hand the user back to the app.
            host(ShareNoSessionView { [weak self] in self?.cancel() })
            return
        }

        let items = await stageAttachments()
        guard !items.isEmpty else {
            // Nothing image/movie in this share (a URL, a text snippet): the
            // request is over, hand it straight back.
            finish()
            return
        }

        let client = SharedUploadClient(
            baseURL: session.baseURL,
            token: session.token,
            deviceId: session.deviceId ?? Self.fallbackDeviceId(),
            customHeaders: session.customHeaders ?? []
        )
        self.uploadClient = client
        let model = ShareExtensionViewModel(
            uploader: client,
            stage: FileManager.default.temporaryDirectory,
            serverLabel: Self.serverLabel(for: session)
        )
        model.setItems(items)
        self.model = model
        host(ShareConfirmationView(
            viewModel: model,
            onCancel: { [weak self] in self?.cancel() },
            onFinish: { [weak self] in self?.finish() }
        ))
    }

    private func host(_ root: some View) {
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    // MARK: - Staging

    /// Copies every image/movie attachment into the extension's own container.
    ///
    /// This has to happen *now*: `loadFileRepresentation` hands back a URL that
    /// is only valid while its completion handler runs, and the host app's
    /// container is unreadable afterwards. A share that is never staged is a
    /// share that cannot be sent.
    private func stageAttachments() async -> [ShareItem] {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        var items: [ShareItem] = []
        for provider in providers {
            guard let type = Self.shareableType(of: provider) else { continue }
            guard let staged = await Self.stage(provider, typeIdentifier: type.identifier) else { continue }
            let isVideo = type.conforms(to: .movie)
            let attributes = try? FileManager.default.attributesOfItem(atPath: staged.url.path)
            items.append(ShareItem(
                id: UUID(),
                filename: staged.fileName,
                fileURL: staged.url,
                isVideo: isVideo,
                byteCount: (attributes?[.size] as? Int) ?? 0,
                createdAt: (attributes?[.creationDate] as? Date) ?? Date(),
                duration: isVideo ? await Self.duration(of: staged.url) : nil,
                isSelected: true,
                status: .enqueued
            ))
        }
        return items
    }

    private static func shareableType(of provider: NSItemProvider) -> UTType? {
        for type in [UTType.image, UTType.movie] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            return type
        }
        return nil
    }

    private static func stage(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async -> (url: URL, fileName: String)? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<(url: URL, fileName: String)?, Never>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let fileName = suggested ?? url.lastPathComponent
                // One directory per item: the original file name survives, and
                // the copy lands under `temporaryDirectory`, which is the only
                // place this process is guaranteed to write.
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let destination = directory.appendingPathComponent(fileName)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: (destination, fileName))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// `duration` is a whole number of seconds in the Immich upload form; a
    /// movie's own track length is the only value that makes the web UI's
    /// thumbnail agree with the file.
    private static func duration(of url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds,
              seconds.isFinite, seconds > 0 else { return nil }
        return Int(seconds.rounded())
    }

    // MARK: - Session

    /// "Millian · photos.local" — the sheet says which server it is about to
    /// talk to, because nothing else on screen does.
    private static func serverLabel(for session: WidgetSession) -> String {
        let host = URL(string: session.baseURL)?.host ?? session.baseURL
        guard let userName = session.userName, !userName.isEmpty else { return host }
        return "\(userName) · \(host)"
    }

    /// Only for a session written before `deviceId` existed: the app rewrites
    /// the item on its next launch, and until then a stable id of our own keeps
    /// the uploads attributable instead of claiming an empty device.
    private static func fallbackDeviceId() -> String {
        let key = "immichShareDeviceId"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: key)
        return generated
    }

    // MARK: - Ending the request

    /// The two only ways out of a share extension. Cancelling abandons the
    /// uploads in flight — nothing is resumed later, and no label promises
    /// otherwise.
    private func cancel() {
        model?.discardStagedFiles()
        uploadClient?.invalidate()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    private func finish() {
        model?.discardStagedFiles()
        uploadClient?.invalidate()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
