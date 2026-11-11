import XCTest
@testable import ImmichSwiftUI

// L-09: the app-side registry of custom headers, the editor behind it, and the
// promise that a header value stays out of every log and every preference.

final class CustomHeadersRegistryTests: XCTestCase {
    private let a = ServerKey.of("https://a.example.org")
    private let b = ServerKey.of("https://b.example.org")

    private func makeRegistry(
        _ store: InMemoryCustomHeadersStore, center: NotificationCenter = NotificationCenter()
    ) -> CustomHeadersRegistry {
        CustomHeadersRegistry(store: store, notificationCenter: center)
    }

    func test_theKeychainIsReadOnceNotPerRequest() {
        let store = InMemoryCustomHeadersStore([a: [StaticCustomHeaders.xAccess]])
        let registry = makeRegistry(store)
        for _ in 0..<50 { _ = registry.headers(for: URL(string: "https://a.example.org/api/x")) }
        XCTAssertEqual(store.loadCount, 1)
    }

    func test_theListIsFoundByURLWhateverThePathOrTheSpelling() {
        let registry = makeRegistry(InMemoryCustomHeadersStore([a: [StaticCustomHeaders.xAccess]]))
        XCTAssertEqual(registry.headers(for: URL(string: "https://A.Example.org:443/api/assets/1/thumbnail?size=preview")), [StaticCustomHeaders.xAccess])
        XCTAssertTrue(registry.headers(for: URL(string: "https://a.example.org:8443/")).isEmpty)
        XCTAssertTrue(registry.headers(for: nil).isEmpty)
        XCTAssertTrue(registry.headers(for: URL(string: "ftp://a.example.org")).isEmpty)
    }

    func test_AC_120_otherServerGetsNothing() {
        let registry = makeRegistry(InMemoryCustomHeadersStore([a: [StaticCustomHeaders.xAccess]]))
        XCTAssertTrue(registry.headers(for: b).isEmpty)
        XCTAssertTrue(registry.headers(for: URL(string: "https://b.example.org/api")).isEmpty)
    }

    func test_saveWritesTheKeychainThenMemoryThenNotifies() throws {
        let store = InMemoryCustomHeadersStore()
        let center = NotificationCenter()
        let registry = makeRegistry(store, center: center)
        var received: [String] = []
        let token = center.addObserver(forName: .immichCustomHeadersChanged, object: nil, queue: nil) {
            received.append($0.userInfo?["serverKey"] as? String ?? "")
        }
        defer { center.removeObserver(token) }

        try registry.save([StaticCustomHeaders.xAccess], for: a)

        XCTAssertEqual(store.stored[a], [StaticCustomHeaders.xAccess])
        XCTAssertEqual(registry.headers(for: a), [StaticCustomHeaders.xAccess])
        XCTAssertEqual(received, [a.rawValue])
    }

    func test_aNotificationObserverMayReadTheRegistry() throws {
        let center = NotificationCenter()
        let registry = makeRegistry(InMemoryCustomHeadersStore(), center: center)
        var seen: [CustomHTTPHeader] = []
        let token = center.addObserver(forName: .immichCustomHeadersChanged, object: nil, queue: nil) { _ in
            seen = registry.headers(for: self.a)
        }
        defer { center.removeObserver(token) }
        try registry.save([StaticCustomHeaders.xAccess], for: a)
        XCTAssertEqual(seen, [StaticCustomHeaders.xAccess])
    }

    func test_aFailedWriteLeavesMemoryAndObserversAlone() {
        let store = InMemoryCustomHeadersStore([a: [StaticCustomHeaders.xAccess]])
        let center = NotificationCenter()
        let registry = makeRegistry(store, center: center)
        var notified = false
        let token = center.addObserver(forName: .immichCustomHeadersChanged, object: nil, queue: nil) { _ in notified = true }
        defer { center.removeObserver(token) }
        store.failSaves = true

        XCTAssertThrowsError(try registry.save([], for: a))

        XCTAssertEqual(registry.headers(for: a), [StaticCustomHeaders.xAccess])
        XCTAssertFalse(notified)
    }

    func test_savingAnEmptyListRemovesTheServer() throws {
        let store = InMemoryCustomHeadersStore([a: [StaticCustomHeaders.xAccess]])
        let registry = makeRegistry(store)
        try registry.save([], for: a)
        XCTAssertTrue(registry.headers(for: a).isEmpty)
        XCTAssertNil(store.stored[a])
    }

    func test_aFailedFirstReadBehavesAsEmptyThenRetries() {
        let store = InMemoryCustomHeadersStore([a: [StaticCustomHeaders.xAccess]], failLoads: 1)
        let registry = makeRegistry(store)
        XCTAssertTrue(registry.headers(for: a).isEmpty, "locked keychain: behaves as empty")
        XCTAssertEqual(registry.headers(for: a), [StaticCustomHeaders.xAccess], "the next access retries")
        XCTAssertEqual(store.loadCount, 2)
    }

    func test_aSaveAfterAFailedReadDoesNotForgetTheOtherServers() throws {
        let store = InMemoryCustomHeadersStore([b: [StaticCustomHeaders.basic]], failLoads: 1)
        let registry = makeRegistry(store)
        _ = registry.headers(for: a) // first read fails
        try registry.save([StaticCustomHeaders.xAccess], for: a)
        XCTAssertEqual(registry.headers(for: b), [StaticCustomHeaders.basic])
        XCTAssertEqual(registry.headers(for: a), [StaticCustomHeaders.xAccess])
    }
}

@MainActor
final class CustomHeadersViewModelTests: XCTestCase {
    private let key = ServerKey.of("https://a.example.org")

    private struct Fixture {
        let vm: CustomHeadersViewModel
        let store: InMemoryCustomHeadersStore
        let registry: CustomHeadersRegistry
        let saved: SavedBox
    }

    private final class SavedBox { var keys: [ServerKey] = [] }

    private func make(_ initial: [CustomHTTPHeader] = []) -> Fixture {
        let store = InMemoryCustomHeadersStore(initial.isEmpty ? [:] : [key: initial])
        let registry = CustomHeadersRegistry(store: store, notificationCenter: NotificationCenter())
        let box = SavedBox()
        let vm = CustomHeadersViewModel(serverKey: key, registry: registry, onSaved: { box.keys.append($0) })
        return Fixture(vm: vm, store: store, registry: registry, saved: box)
    }

    func test_opensWithTheStoredRowsOrNone() {
        XCTAssertTrue(make().vm.rows.isEmpty)
        let fixture = make([StaticCustomHeaders.xAccess, StaticCustomHeaders.basic])
        XCTAssertEqual(fixture.vm.rows.map(\.name), ["X-Access", "Authorization"])
        XCTAssertEqual(fixture.vm.rows.map(\.value), ["secret", "Basic dXNlcjpwYXNz"])
    }

    func test_AC_121_invalidRowsBlockSave() {
        let fixture = make()
        let vm = fixture.vm
        vm.addRow(); vm.addRow(); vm.addRow(); vm.addRow()
        vm.rows[0].name = "X Access"; vm.rows[0].value = "v"
        vm.rows[1].name = "x-immich-user-token"; vm.rows[1].value = "v"
        vm.rows[2].name = "X-Access"; vm.rows[2].value = "v"
        vm.rows[3].name = "x-access"; vm.rows[3].value = "w"

        XCTAssertEqual(vm.issues[vm.rows[0].id], .invalidName)
        XCTAssertEqual(vm.issues[vm.rows[1].id], .reservedName)
        XCTAssertNil(vm.issues[vm.rows[2].id])
        XCTAssertEqual(vm.issues[vm.rows[3].id], .duplicateName)
        XCTAssertFalse(vm.canSave)
        XCTAssertFalse(vm.save())
        XCTAssertTrue(fixture.store.stored.isEmpty)
        XCTAssertTrue(fixture.saved.keys.isEmpty)
    }

    func test_AC_121_trimmedHeaderIsSaved() {
        let fixture = make()
        fixture.vm.addRow()
        fixture.vm.rows[0].name = " X-Access "
        fixture.vm.rows[0].value = " secret "

        XCTAssertTrue(fixture.vm.canSave)
        XCTAssertTrue(fixture.vm.save())
        XCTAssertEqual(fixture.store.stored[key], [CustomHTTPHeader(name: "X-Access", value: "secret")])
        XCTAssertEqual(fixture.saved.keys, [key])
    }

    func test_AC_121_blankRowsAreIgnored() {
        let fixture = make()
        fixture.vm.addRow(); fixture.vm.addRow(); fixture.vm.addRow()
        fixture.vm.rows[0].name = "X-A"            // no value
        fixture.vm.rows[1].value = "v"             // no name
        fixture.vm.rows[2].name = "X-B"; fixture.vm.rows[2].value = "1"

        XCTAssertTrue(fixture.vm.issues.isEmpty)
        XCTAssertEqual(fixture.vm.pendingHeaders, [CustomHTTPHeader(name: "X-B", value: "1")])
        XCTAssertTrue(fixture.vm.save())
        XCTAssertEqual(fixture.store.stored[key], [CustomHTTPHeader(name: "X-B", value: "1")])
    }

    func test_AC_121_messagesAreDistinctAndLocalized() {
        let vm = make().vm
        let issues: [CustomHeaderIssue] = [.invalidName, .reservedName, .duplicateName, .invalidValue]
        let messages = issues.map { vm.message(for: $0) }
        XCTAssertEqual(Set(messages).count, 4)
        for message in messages {
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("secret"))
        }
        // Same texts the catalog translates: not the raw key of a missing entry.
        XCTAssertEqual(messages[1], String(localized: "The app sets this header itself."))
    }

    func test_nothingToSaveWhileTheDraftEqualsTheStoredList() {
        let fixture = make([StaticCustomHeaders.xAccess])
        XCTAssertFalse(fixture.vm.canSave)
        XCTAssertFalse(fixture.vm.save())
        fixture.vm.rows[0].value = "other"
        XCTAssertTrue(fixture.vm.canSave)
    }

    func test_AC_20_removingTheLastRowSavesAnEmptyList() {
        let fixture = make([StaticCustomHeaders.xAccess])
        fixture.vm.removeRow(fixture.vm.rows[0].id)

        XCTAssertTrue(fixture.vm.canSave)
        XCTAssertTrue(fixture.vm.save())
        XCTAssertNil(fixture.store.stored[key])
        XCTAssertTrue(fixture.registry.headers(for: key).isEmpty)
        XCTAssertEqual(fixture.saved.keys, [key])
    }

    func test_aKeychainFailureIsReportedWithoutNamingAnything() {
        let fixture = make()
        fixture.vm.addRow()
        fixture.vm.rows[0].name = "X-Access"
        fixture.vm.rows[0].value = "s3cr3t-valeur"
        fixture.store.failSaves = true

        XCTAssertFalse(fixture.vm.save())
        XCTAssertEqual(fixture.vm.saveErrorMessage, String(localized: "The headers could not be saved."))
        XCTAssertFalse(fixture.vm.saveErrorMessage?.contains("s3cr3t") ?? true)
        XCTAssertTrue(fixture.saved.keys.isEmpty)

        fixture.store.failSaves = false
        XCTAssertTrue(fixture.vm.save())
        XCTAssertNil(fixture.vm.saveErrorMessage)
    }
}

/// AC-122: the value of a header lives in the keychain and nowhere else.
@MainActor
final class CustomHeadersSecrecyTests: XCTestCase {
    private let secret = "s3cr3t-valeur"
    private let service = "app.immich.swiftui.headers.tests"

    override func tearDown() {
        CapturingURLProtocol.reset()
    }

    func test_AC_122() async throws {
        let keychain = KeychainCustomHeadersStore(service: service)
        let hosted = ServerKey.of("https://photos.example.org")
        let refused = ServerKey.of("http://127.0.0.1:9")
        defer { keychain.remove(for: hosted); keychain.remove(for: refused) }

        let registry = CustomHeadersRegistry(store: keychain, notificationCenter: NotificationCenter())
        let header = CustomHTTPHeader(name: "X-Access", value: secret)
        try registry.save([header], for: hosted)
        try registry.save([header], for: refused)

        let log = AppLogStore()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingURLProtocol.self]
        let client = ImmichAPIClient(session: URLSession(configuration: config), log: log, customHeaders: registry)
        client.configure(baseURL: URL(string: "https://photos.example.org")!, token: "tok")

        CapturingURLProtocol.nextData = Data(#"{"res":"pong"}"#.utf8)
        for status in [200, 403, 500] {
            CapturingURLProtocol.nextStatus = status
            _ = try? await client.ping()
        }
        // The header really went out, so the absence below proves something.
        XCTAssertEqual(CapturingURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Access"), secret)

        let unreachable = ImmichAPIClient(
            session: URLSession(configuration: .ephemeral), log: log, customHeaders: registry
        )
        unreachable.configure(baseURL: URL(string: "http://127.0.0.1:9")!, token: "tok")
        _ = try? await unreachable.ping()

        XCTAssertGreaterThanOrEqual(log.count(), 4)
        for entry in log.snapshot() {
            for text in [entry.message, entry.details, entry.stack, entry.path].compactMap({ $0 }) {
                XCTAssertFalse(text.contains(secret))
            }
        }
        let logViewModel = AppLogViewModel(store: log)
        logViewModel.refresh()
        XCTAssertFalse(logViewModel.exportText().contains(secret))
        XCTAssertFalse(String(describing: UserDefaults.standard.dictionaryRepresentation()).contains(secret))

        let failing = InMemoryCustomHeadersStore()
        failing.failSaves = true
        let editor = CustomHeadersViewModel(
            serverKey: hosted,
            registry: CustomHeadersRegistry(store: failing, notificationCenter: NotificationCenter()),
            onSaved: { _ in }
        )
        editor.addRow()
        editor.rows[0].name = "X-Access"
        editor.rows[0].value = secret
        XCTAssertFalse(editor.save())
        XCTAssertFalse(editor.saveErrorMessage?.contains(secret) ?? true)

        let persisted = try keychain.loadAll()
        XCTAssertEqual(persisted[hosted], [header])
    }
}
