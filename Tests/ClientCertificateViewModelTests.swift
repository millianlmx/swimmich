import XCTest
import Security
@testable import ImmichSwiftUI

/// Scriptable `ClientCertificateManaging`.
private final class FakeCertificateManager: ClientCertificateManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var installed: Bool
    private var importCalls: [(data: Data, password: String, url: URL)] = []
    private var removeCalls = 0
    var importError: Error?
    var removeError: Error?

    init(installed: Bool = false) {
        self.installed = installed
    }

    var imports: [(data: Data, password: String, url: URL)] { lock.lock(); defer { lock.unlock() }; return importCalls }
    var removals: Int { lock.lock(); defer { lock.unlock() }; return removeCalls }

    func hasCertificate(for serverURL: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    func importCertificate(_ data: Data, password: String, for serverURL: URL) async throws {
        lock.lock(); defer { lock.unlock() }
        importCalls.append((data, password, serverURL))
        if let importError { throw importError }
        installed = true
    }

    func removeCertificate(for serverURL: URL) async throws {
        lock.lock(); defer { lock.unlock() }
        removeCalls += 1
        if let removeError { throw removeError }
        installed = false
    }
}

@MainActor
final class ClientCertificateViewModelTests: XCTestCase {
    private let server = URL(string: "https://photos.example.com")!
    private let file = Data("not-really-a-p12-but-opaque-to-the-vm".utf8)

    private func makeVM(
        manager: FakeCertificateManager,
        serverURL: URL? = URL(string: "https://photos.example.com"),
        onChange: @escaping @MainActor () async -> Void = {},
        loadFile: @escaping @Sendable (URL) throws -> Data = { _ in Data() }
    ) -> ClientCertificateViewModel {
        ClientCertificateViewModel(serverURL: serverURL, manager: manager, onChange: onChange, loadFile: loadFile)
    }

    func test_AC_21_1_importSucceeds() async {
        let manager = FakeCertificateManager()
        let changes = TestCounter()
        let vm = makeVM(manager: manager, onChange: { changes.increment() })
        XCTAssertFalse(vm.hasCertificate)

        vm.filePicked(data: file)
        XCTAssertNotNil(vm.pendingFileData, "the password section opens")
        vm.password = "alpha"
        await vm.submitPassword()

        XCTAssertEqual(vm.message, .imported)
        XCTAssertTrue(vm.hasCertificate)
        XCTAssertEqual(vm.serverLabel, "photos.example.com:443")
        XCTAssertEqual(manager.imports.count, 1)
        XCTAssertEqual(manager.imports.first?.password, "alpha")
        XCTAssertEqual(manager.imports.first?.url, server)
        XCTAssertEqual(changes.value, 1, "the server step re-checks once")
        XCTAssertEqual(vm.password, "")
        XCTAssertNil(vm.pendingFileData)
    }

    func test_AC_37_wrongPasswordRefused() async {
        let manager = FakeCertificateManager()
        manager.importError = ClientIdentityImportError.wrongPassword
        let changes = TestCounter()
        let vm = makeVM(manager: manager, onChange: { changes.increment() })

        vm.filePicked(data: file)
        vm.password = "nope"
        await vm.submitPassword()

        XCTAssertEqual(vm.message, .wrongPassword)
        XCTAssertEqual(vm.message?.kind, "wrongPassword")
        XCTAssertFalse(vm.hasCertificate, "nothing was saved")
        XCTAssertEqual(changes.value, 0)
        XCTAssertEqual(vm.password, "")
        XCTAssertNil(vm.pendingFileData)
    }

    func test_AC_37_1_unusableFileMessageDiffers() async {
        let manager = FakeCertificateManager()
        manager.importError = ClientIdentityImportError.unusableFile
        let vm = makeVM(manager: manager)

        vm.filePicked(data: file)
        vm.password = "alpha"
        await vm.submitPassword()

        XCTAssertEqual(vm.message, .unusableFile)
        XCTAssertNotEqual(ClientCertificateViewModel.Message.unusableFile.text, ClientCertificateViewModel.Message.wrongPassword.text)
        XCTAssertFalse(vm.hasCertificate)
    }

    func test_AC_37_2_wrongPasswordKeepsInstalled() async {
        let manager = FakeCertificateManager(installed: true)
        manager.importError = ClientIdentityImportError.wrongPassword
        let vm = makeVM(manager: manager)
        XCTAssertTrue(vm.hasCertificate)

        vm.filePicked(data: file)
        vm.password = "bad"
        await vm.submitPassword()

        XCTAssertEqual(vm.message, .wrongPassword)
        XCTAssertTrue(vm.hasCertificate, "a refused import never changes what is installed")
        XCTAssertEqual(manager.removals, 0)
    }

    func test_AC_37_keychainFailureIsReportedAsNotSaved() async {
        let manager = FakeCertificateManager()
        manager.importError = ClientIdentityStoreError(status: errSecIO)
        let vm = makeVM(manager: manager)

        vm.filePicked(data: file)
        vm.password = "alpha"
        await vm.submitPassword()

        XCTAssertEqual(vm.message, .saveFailed)
        XCTAssertFalse(vm.hasCertificate)
    }

    func test_AC_22_1_removeDisabledWithoutCertificate() {
        let vm = makeVM(manager: FakeCertificateManager(installed: false))

        XCTAssertFalse(vm.canRemove)
        vm.requestRemoval()
        XCTAssertFalse(vm.confirmsRemoval, "there is nothing to remove")
    }

    func test_AC_22_2_removeAfterConfirmation() async {
        let manager = FakeCertificateManager(installed: true)
        let changes = TestCounter()
        let vm = makeVM(manager: manager, onChange: { changes.increment() })
        XCTAssertTrue(vm.canRemove)

        vm.requestRemoval()
        XCTAssertTrue(vm.confirmsRemoval)
        XCTAssertEqual(manager.removals, 0, "asking is not removing")
        await vm.confirmRemoval()

        XCTAssertEqual(manager.removals, 1)
        XCTAssertFalse(vm.hasCertificate)
        XCTAssertEqual(vm.message, .removed)
        XCTAssertEqual(changes.value, 1)
    }

    func test_AC_22_2_failedRemovalKeepsTheCertificate() async {
        let manager = FakeCertificateManager(installed: true)
        manager.removeError = ClientIdentityStoreError(status: errSecIO)
        let vm = makeVM(manager: manager)

        vm.requestRemoval()
        await vm.confirmRemoval()

        XCTAssertEqual(vm.message, .saveFailed)
        XCTAssertTrue(vm.hasCertificate)
    }

    func test_AC_37_3_passwordClearedAndNeverPersisted() async {
        let secret = "s3cret-password-L10-\(UUID().uuidString)"
        let manager = FakeCertificateManager()
        manager.importError = ClientIdentityImportError.wrongPassword
        let vm = makeVM(manager: manager)

        vm.filePicked(data: file)
        vm.password = secret
        await vm.submitPassword()
        XCTAssertEqual(vm.password, "", "a failed attempt empties the field")

        manager.importError = nil
        vm.filePicked(data: file)
        vm.password = secret
        await vm.submitPassword()
        XCTAssertEqual(vm.password, "", "so does a successful one")

        let defaults = UserDefaults.standard.dictionaryRepresentation().description
        XCTAssertFalse(defaults.contains(secret))
        XCTAssertFalse(defaults.contains(file.base64EncodedString()))
    }

    func test_cancelPasswordDropsTheFile() {
        let vm = makeVM(manager: FakeCertificateManager())
        vm.filePicked(data: file)
        vm.password = "typed"

        vm.cancelPassword()

        XCTAssertNil(vm.pendingFileData)
        XCTAssertEqual(vm.password, "")
    }

    func test_pickingAFileGoesThroughTheLoaderAndReportsUnreadableFiles() {
        let manager = FakeCertificateManager()
        let url = URL(fileURLWithPath: "/tmp/client.p12")
        let vm = makeVM(manager: manager, loadFile: { _ in Data("bytes".utf8) })
        vm.filePicked(result: .success(url))
        XCTAssertEqual(vm.pendingFileData, Data("bytes".utf8))

        struct Unreadable: Error {}
        let failing = makeVM(manager: manager, loadFile: { _ in throw Unreadable() })
        failing.filePicked(result: .success(url))
        XCTAssertEqual(failing.message, .unreadableFile)
        XCTAssertNil(failing.pendingFileData)
    }

    func test_dismissingThePickerIsNotAnError() {
        let vm = makeVM(manager: FakeCertificateManager())
        vm.filePicked(result: .failure(CocoaError(.userCancelled)))
        XCTAssertNil(vm.message)
    }

    func test_importWithoutAServerIsNotOffered() async {
        let vm = makeVM(manager: FakeCertificateManager(), serverURL: nil)

        XCTAssertFalse(vm.canImport)
        XCTAssertNil(vm.serverLabel)
        await vm.startImport()
        XCTAssertFalse(vm.showsFilePicker)
    }

    func test_startImportOpensThePickerWithoutTheTestFeed() async throws {
        try XCTSkipIf(ClientCertificateTestFeed.url != nil, "the UI-test feed replaces the picker")
        let vm = makeVM(manager: FakeCertificateManager())

        await vm.startImport()

        XCTAssertTrue(vm.showsFilePicker)
    }
}
