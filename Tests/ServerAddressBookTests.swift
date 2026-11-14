import XCTest
@testable import ImmichSwiftUI

/// L-26: a server keeps ONE identity (its connection address); its local and
/// external addresses resolve to it for headers, certificate and image cache.
final class ServerAddressBookTests: XCTestCase {
    private let account = URL(string: "https://photos.example.org")!
    private let local = URL(string: "http://192.168.1.10:2283")!

    private func makeBook(external: URL? = nil) -> ServerAddressBook {
        let book = ServerAddressBook()
        book.update(accountURL: account, addresses: [external ?? account, local], activeURL: local)
        return book
    }

    func test_AC_241_headersFollowAccount() {
        let key = ServerKey.of("https://photos.example.org")
        let store = InMemoryCustomHeadersStore([key: [StaticCustomHeaders.xAccess]])
        let registry = CustomHeadersRegistry(store: store, notificationCenter: NotificationCenter(), addressBook: makeBook())

        XCTAssertEqual(
            registry.headers(for: URL(string: "http://192.168.1.10:2283/api/x")), [StaticCustomHeaders.xAccess],
            "the local address sends the headers saved for the connection address"
        )
        XCTAssertEqual(registry.headers(for: URL(string: "https://photos.example.org/api/x")), [StaticCustomHeaders.xAccess])
        XCTAssertTrue(registry.headers(for: URL(string: "http://192.168.1.99:2283/api/x")).isEmpty, "a foreign host gets nothing")
    }

    func test_AC_241_externalAddressSendsTheAccountHeaders() {
        let key = ServerKey.of("https://photos.example.org")
        let external = URL(string: "https://vpn.example.net")!
        let registry = CustomHeadersRegistry(
            store: InMemoryCustomHeadersStore([key: [StaticCustomHeaders.xAccess]]),
            notificationCenter: NotificationCenter(), addressBook: makeBook(external: external)
        )
        XCTAssertEqual(registry.headers(for: URL(string: "https://vpn.example.net/api/x")), [StaticCustomHeaders.xAccess])
    }

    func test_AC_241_canonicalKeyOnlyForDeclaredAddresses() {
        let book = makeBook()
        XCTAssertEqual(book.canonicalKey(for: ServerKey.of("http://192.168.1.10:2283")), ServerKey.of("https://photos.example.org"))
        XCTAssertEqual(book.canonicalKey(for: ServerKey.of("http://192.168.1.10:8080")), ServerKey.of("http://192.168.1.10:8080"))
        book.clear()
        XCTAssertEqual(book.canonicalKey(for: ServerKey.of("http://192.168.1.10:2283")), ServerKey.of("http://192.168.1.10:2283"))
    }

    func test_AC_240_canonicalURLKeepsPathAndQuery() {
        let book = makeBook()
        let url = URL(string: "http://192.168.1.10:2283/api/assets/a/thumbnail?size=thumbnail")!
        XCTAssertEqual(
            book.canonicalURL(for: url).absoluteString,
            "https://photos.example.org/api/assets/a/thumbnail?size=thumbnail"
        )
        XCTAssertEqual(book.canonicalURL(for: URL(string: "https://photos.example.org/api/x")!).absoluteString, "https://photos.example.org/api/x")
    }

    func test_AC_240_canonicalURLDoesNotConfuseAnotherOrigin() {
        let book = makeBook()
        for other in [
            "http://192.168.1.10:2284/api/x",   // another port
            "https://192.168.1.10:2283/api/x",  // another scheme
            "http://192.168.1.11:2283/api/x",   // another host
        ] {
            XCTAssertEqual(book.canonicalURL(for: URL(string: other)!).absoluteString, other)
        }
        XCTAssertEqual(
            book.canonicalURL(for: URL(string: "HTTP://192.168.1.10:2283/api/x")!).absoluteString,
            "https://photos.example.org/api/x", "scheme case is ignored"
        )
    }

    func test_AC_240_proxyUnderASubPathKeepsItsPrefix() {
        let book = ServerAddressBook()
        let account = URL(string: "https://proxy.example.org/immich")!
        let local = URL(string: "http://192.168.1.10:2283")!
        book.update(accountURL: account, addresses: [account, local], activeURL: local)
        XCTAssertEqual(
            book.canonicalURL(for: URL(string: "http://192.168.1.10:2283/api/x?y=1%202")!).absoluteString,
            "https://proxy.example.org/immich/api/x?y=1%202"
        )
        XCTAssertEqual(
            book.canonicalURL(for: URL(string: "https://proxy.example.org/other/api/x")!).absoluteString,
            "https://proxy.example.org/other/api/x", "outside the declared path prefix"
        )
    }

    func test_AC_241_responderPresentsTheAccountIdentityForTheLocalHost() throws {
        let store = InMemoryClientIdentityStore()
        try store.save(try ClientCertificateTestSupport.identityA(), for: ClientCertificateTestSupport.key("https://photos.example.org"))
        let book = makeBook()
        let responder = ClientCertificateResponder(
            store: store, log: TLSChallengeLog(), canonicalKey: { book.canonicalKey(for: $0) }
        )

        let local = try XCTUnwrap(responder.answer(
            ClientCertificateTestSupport.clientCertificateChallenge(host: "192.168.1.10", port: 2283, protocolName: NSURLProtectionSpaceHTTP)
        ))
        XCTAssertEqual(local.0, .useCredential)
        XCTAssertNotNil(local.1?.identity)

        let foreign = try XCTUnwrap(responder.answer(
            ClientCertificateTestSupport.clientCertificateChallenge(host: "192.168.1.99", port: 2283, protocolName: NSURLProtectionSpaceHTTP)
        ))
        XCTAssertEqual(foreign.0, .performDefaultHandling)
        XCTAssertNil(foreign.1)
    }
}
