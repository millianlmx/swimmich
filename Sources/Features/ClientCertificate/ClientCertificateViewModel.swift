import Foundation

/// The client certificate screen of one server: import a PKCS#12 file (picked
/// in Files, then unlocked with its password), replace it, remove it (L-10).
///
/// One instance per screen, never shared. The password lives in `password`
/// only, and is emptied after every attempt: it is not logged, not persisted,
/// and not kept anywhere else. A refused import changes nothing — the
/// certificate that was installed stays installed.
@Observable @MainActor
final class ClientCertificateViewModel {
    enum Message: Equatable {
        case imported, removed, wrongPassword, unusableFile, saveFailed, unreadableFile

        /// The case name: a stable, non-localized identifier for UI tests.
        var kind: String {
            switch self {
            case .imported: "imported"
            case .removed: "removed"
            case .wrongPassword: "wrongPassword"
            case .unusableFile: "unusableFile"
            case .saveFailed: "saveFailed"
            case .unreadableFile: "unreadableFile"
            }
        }

        var isSuccess: Bool { self == .imported || self == .removed }

        var text: String {
            switch self {
            case .imported:
                String(localized: "Client certificate imported.")
            case .removed:
                String(localized: "Client certificate removed.")
            case .wrongPassword:
                String(localized: "The certificate password is incorrect. If you’re sure it’s right, export the file again with OpenSSL’s -legacy option.")
            case .unusableFile:
                String(localized: "This file is not a usable client certificate (a PKCS#12 file with a private key).")
            case .saveFailed:
                String(localized: "The certificate could not be saved.")
            case .unreadableFile:
                String(localized: "The file could not be read.")
            }
        }
    }

    private let serverURL: URL?
    private let manager: any ClientCertificateManaging
    private let onChange: @MainActor () async -> Void
    private let loadFile: @Sendable (URL) throws -> Data

    /// `host:port` of the server the certificate belongs to, shown verbatim.
    let serverLabel: String?
    private(set) var hasCertificate = false
    /// The picked file, present while it waits for its password.
    private(set) var pendingFileData: Data?
    var password = ""
    private(set) var isWorking = false
    var showsFilePicker = false
    var confirmsRemoval = false
    private(set) var message: Message?

    init(
        serverURL: URL?,
        manager: any ClientCertificateManaging,
        onChange: @escaping @MainActor () async -> Void = {},
        loadFile: @escaping @Sendable (URL) throws -> Data = ClientCertificateViewModel.readSecurityScoped
    ) {
        self.serverURL = serverURL
        self.manager = manager
        self.onChange = onChange
        self.loadFile = loadFile
        self.serverLabel = serverURL.flatMap(ServerKey.init(url:))?.account
        refresh()
    }

    /// A file picked in Files is outside the sandbox: reading it needs the
    /// security-scoped access the picker grants.
    nonisolated static func readSecurityScoped(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    /// Importing needs a server: the certificate belongs to one (host + port).
    var canImport: Bool { serverLabel != nil && !isWorking }
    var canRemove: Bool { hasCertificate && !isWorking }

    func refresh() {
        hasCertificate = serverURL.map { manager.hasCertificate(for: $0) } ?? false
    }

    // MARK: Import

    /// "Import Certificate…": opens the file picker — or, under the UI-test
    /// feed, downloads the file the test chose and goes straight to the
    /// password.
    func startImport() async {
        guard canImport else { return }
        guard let feed = ClientCertificateTestFeed.url else {
            showsFilePicker = true
            return
        }
        do {
            let (data, _) = try await URLSession(configuration: .ephemeral).data(from: feed)
            filePicked(data: data)
        } catch {
            message = .unreadableFile
        }
    }

    func filePicked(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                filePicked(data: try loadFile(url))
            } catch {
                message = .unreadableFile
            }
        case .failure(let error):
            // Dismissing the picker is not a failure worth a message.
            if (error as? CocoaError)?.code == .userCancelled { return }
            message = .unreadableFile
        }
    }

    func filePicked(data: Data) {
        pendingFileData = data
        password = ""
        message = nil
    }

    func submitPassword() async {
        guard let data = pendingFileData, let serverURL, !isWorking else { return }
        isWorking = true
        let secret = password
        var imported = false
        do {
            try await manager.importCertificate(data, password: secret, for: serverURL)
            imported = true
        } catch let error as ClientIdentityImportError {
            message = error == .wrongPassword ? .wrongPassword : .unusableFile
        } catch {
            message = .saveFailed
        }
        // Whatever the outcome: neither the password nor the file is kept.
        password = ""
        pendingFileData = nil
        isWorking = false
        guard imported else { return }
        message = .imported
        hasCertificate = true
        await onChange()
    }

    func cancelPassword() {
        pendingFileData = nil
        password = ""
    }

    // MARK: Removal

    func requestRemoval() {
        guard canRemove else { return }
        confirmsRemoval = true
    }

    func confirmRemoval() async {
        guard canRemove, let serverURL else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await manager.removeCertificate(for: serverURL)
        } catch {
            message = .saveFailed
            return
        }
        message = .removed
        hasCertificate = false
        await onChange()
    }
}
