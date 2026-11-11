import XCTest
@testable import ImmichSwiftUI

/// `SecPKCS12Import` through `PKCS12Importer`: which failure means what.
final class PKCS12ImporterTests: XCTestCase {
    private func assertThrows(
        _ expected: ClientIdentityImportError, data: Data, password: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try PKCS12Importer.identity(from: data, password: password), file: file, line: line) {
            XCTAssertEqual($0 as? ClientIdentityImportError, expected, file: file, line: line)
        }
    }

    func test_AC_21_rightPasswordYieldsTheIdentity() throws {
        let identity = try PKCS12Importer.identity(
            from: ClientCertificateFixtures.a, password: ClientCertificateFixtures.passwordA
        )
        XCTAssertEqual(ClientCertificateTestSupport.subject(of: identity), "client-a")
    }

    func test_AC_37_wrongPassword() {
        assertThrows(.wrongPassword, data: ClientCertificateFixtures.a, password: "not-alpha")
        assertThrows(.wrongPassword, data: ClientCertificateFixtures.a, password: "")
    }

    func test_AC_37_1_notPKCS12() {
        assertThrows(.unusableFile, data: ClientCertificateFixtures.notPKCS12, password: "alpha")
        assertThrows(.unusableFile, data: Data(), password: "alpha")
    }

    func test_AC_37_1_noPrivateKey() {
        assertThrows(.unusableFile, data: ClientCertificateFixtures.noKey, password: ClientCertificateFixtures.passwordA)
    }

    /// A PKCS#12 written with the OpenSSL 3 defaults and the right password:
    /// Security reads it, or refuses it with the "wrong password" status
    /// (`errSecPkcs12VerifyFailure`) — never "unusable file" or any other error,
    /// since the message of `.wrongPassword` carries the `-legacy` advice.
    func test_AC_37_openSSL3DefaultFormatNeverReportedUnusable() {
        do {
            let identity = try PKCS12Importer.identity(
                from: ClientCertificateFixtures.modernA, password: ClientCertificateFixtures.passwordA
            )
            NSLog("L-10 OpenSSL 3 default PKCS#12: imported (%@)", ClientCertificateTestSupport.subject(of: identity) ?? "?")
        } catch {
            XCTAssertEqual(error as? ClientIdentityImportError, .wrongPassword)
            NSLog("L-10 OpenSSL 3 default PKCS#12: refused with the wrong-password status")
        }
    }
}
