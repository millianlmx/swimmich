import Foundation
import Security
@testable import ImmichSwiftUI

/// In-memory `ClientIdentityStoring`, keyed by `ServerKey`: the logic under test
/// never needs the keychain.
final class InMemoryClientIdentityStore: ClientIdentityStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [ServerKey: SecIdentity] = [:]
    private var failing = false

    /// Makes the next `save` throw, as a keychain failure would.
    var failsOnSave: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); failing = newValue; lock.unlock() }
    }

    func identity(for key: ServerKey) -> SecIdentity? {
        lock.lock(); defer { lock.unlock() }
        return identities[key]
    }

    func hasIdentity(for key: ServerKey) -> Bool { identity(for: key) != nil }

    func save(_ identity: SecIdentity, for key: ServerKey) throws {
        lock.lock(); defer { lock.unlock() }
        if failing { throw ClientIdentityStoreError(status: errSecIO) }
        identities[key] = identity
    }

    func remove(for key: ServerKey) throws {
        lock.lock(); defer { lock.unlock() }
        identities[key] = nil
    }

    func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        identities = [:]
    }
}

/// Thread-safe counter for closures the code under test calls from anywhere.
final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

/// Counts `renewSessions()` calls and appends its name to a shared journal, so a
/// test can check the order of a certificate change.
final class FakeSessionRenewer: SessionRenewing, @unchecked Sendable {
    private let name: String
    private let journal: TestJournal

    init(name: String, journal: TestJournal) {
        self.name = name
        self.journal = journal
    }

    func renewSessions() { journal.append("renew:\(name)") }
}

final class TestJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var entries: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
}

enum ClientCertificateTestSupport {
    static func identityA() throws -> SecIdentity {
        try PKCS12Importer.identity(from: ClientCertificateFixtures.a, password: ClientCertificateFixtures.passwordA)
    }

    static func identityB() throws -> SecIdentity {
        try PKCS12Importer.identity(from: ClientCertificateFixtures.b, password: ClientCertificateFixtures.passwordB)
    }

    /// The common name of an identity's certificate (`client-a`, `client-b`).
    static func subject(of identity: SecIdentity) -> String? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }

    static func key(_ url: String) -> ServerKey {
        ServerKey(url: URL(string: url)!)!
    }

    /// A client-certificate challenge from `host:port`.
    static func clientCertificateChallenge(
        host: String, port: Int, protocolName: String = NSURLProtectionSpaceHTTPS
    ) -> URLAuthenticationChallenge {
        challenge(method: NSURLAuthenticationMethodClientCertificate, host: host, port: port, protocolName: protocolName)
    }

    static func challenge(
        method: String, host: String, port: Int, protocolName: String = NSURLProtectionSpaceHTTPS
    ) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: host, port: port, protocol: protocolName, realm: nil, authenticationMethod: method
            ),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: StubAuthenticationSender()
        )
    }
}

final class StubAuthenticationSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

/// A clock a test moves by hand, for `TLSChallengeLog`.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(by seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}
