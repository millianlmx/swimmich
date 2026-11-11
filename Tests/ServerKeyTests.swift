import XCTest
@testable import ImmichSwiftUI

/// "The same server" for a client certificate: lowercase host + effective port.
final class ClientCertificateServerKeyTests: XCTestCase {
    func test_AC_22_5_sameServerForms() throws {
        let forms = ["https://h", "https://H/", "https://h:443/x", "wss://h"]
        let keys = forms.compactMap { URL(string: $0).flatMap(ServerKey.init(url:)) }
        XCTAssertEqual(keys.count, forms.count)
        XCTAssertEqual(Set(keys).count, 1)
        XCTAssertEqual(try XCTUnwrap(keys.first).account, "h:443")
    }

    func test_AC_22_5_distinctServers() throws {
        let base = try XCTUnwrap(ServerKey(url: URL(string: "https://h")!))
        for other in ["https://h:8443", "http://h", "https://g"] {
            let key = try XCTUnwrap(URL(string: other).flatMap(ServerKey.init(url:)))
            XCTAssertNotEqual(key, base, other)
        }
    }

    func test_AC_22_5_otherSchemesAreNotAServer() {
        XCTAssertNil(ServerKey(url: URL(string: "file:///tmp/x")!))
        XCTAssertNil(ServerKey(url: URL(string: "ftp://h")!))
    }

    func test_AC_22_5_protectionSpaceDefaultsTheEffectivePort() throws {
        let https = URLProtectionSpace(
            host: "H", port: 0, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )
        let http = URLProtectionSpace(
            host: "h", port: 0, protocol: NSURLProtectionSpaceHTTP, realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )
        let explicit = URLProtectionSpace(
            host: "h", port: 8443, protocol: NSURLProtectionSpaceHTTPS, realm: nil,
            authenticationMethod: NSURLAuthenticationMethodClientCertificate
        )
        XCTAssertEqual(ServerKey(protectionSpace: https), ServerKey(url: URL(string: "https://h")!))
        XCTAssertEqual(ServerKey(protectionSpace: http), ServerKey(url: URL(string: "http://h")!))
        XCTAssertEqual(ServerKey(protectionSpace: explicit), ServerKey(url: URL(string: "https://h:8443")!))
    }
}
