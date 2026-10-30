import XCTest
import Security
@testable import ImmichSwiftUI

/// The sessions built by `ServerSessions` (images, transfers, road trip): TLS trust
/// rule, redirect behaviour, configuration and reset. No test touches
/// `DependencyContainer.shared` or `UserDefaults.standard`.
final class ServerSessionsTests: XCTestCase {
    private static let host = "nas.trust.test"

    /// Self-signed, RSA 2048, SHA-256, SAN `DNS:nas.trust.test`, EKU serverAuth, CA:TRUE, valid 365 days
    /// from 2026-10-30 15:13:29 UTC. Generated with:
    /// openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes -keyout /dev/null -subj "/CN=nas.trust.test" -addext "subjectAltName=DNS:nas.trust.test" -addext "extendedKeyUsage=serverAuth" -outform DER -out c.der
    private static let certificateBase64 = """
        MIIDRTCCAi2gAwIBAgIUIIBQcH5ETw+CqPIhuqi60tff5ekwDQYJKoZIhvcNAQELBQAwGTEXMBUGA1UEAwwObmFzLnRydXN0LnRl
        c3QwHhcNMjYxMDMwMTUxMzI5WhcNMjcxMDMwMTUxMzI5WjAZMRcwFQYDVQQDDA5uYXMudHJ1c3QudGVzdDCCASIwDQYJKoZIhvcN
        AQEBBQADggEPADCCAQoCggEBAJRURyK9LX+c0sdvVnHgTbl66EDwqTjLWxg3FkYZAtFynUMwmAqVE50ENx1wXH0NwKXjApzG0e7E
        puAj5W0dI1P7AmWlY9jr7ZAqIedW3XY1EZvm2ZTWGuQQJ8Pl1ofzZK2rjLq0p6DL6O+BnrjuyrEOLYyjNrz+D9QW/Jptqf4o+9ZI
        UhswQk32uoI/S3K//B6HJWD0a3O12GVGtcSHNM4PszbTL6/4JoDugHFROgjj76hjkAQlNtX+TDEtVNwTIlrSyiev3f1Brigyb49z
        PPJbDv3A5zDZSBRbbqgsef1ujylqhq6zPmGAZwZsQXNdRG4kOEdXgzfmmbxVOQT09ScCAwEAAaOBhDCBgTAdBgNVHQ4EFgQUgpFd
        xnueI1opOSBG1Wc2nSYup8YwHwYDVR0jBBgwFoAUgpFdxnueI1opOSBG1Wc2nSYup8YwDwYDVR0TAQH/BAUwAwEB/zAZBgNVHREE
        EjAQgg5uYXMudHJ1c3QudGVzdDATBgNVHSUEDDAKBggrBgEFBQcDATANBgkqhkiG9w0BAQsFAAOCAQEARj5CkY8NskzC7fNq10P+
        4jFIKq45dFRbvmld5QryvzwQYeIVYXtXtIrpgMSc/Hc29EL4LzFV8hCdB29ZAjZWdbMIMTRvxgebPG1VsUNI9YoeIhKYGlVAVJ65
        vnViYZBiZpKsnNL16/NpjHTLdnlsVOJsmmlCxXo4wGlck/NnTxPVONGfEx8K+ezGHwP5f+qOI4qbp3IaDEECM9Lg3St3Xb4PsrEe
        tYwonIVkpiZDAhwRWzxopABHktJKL0j7pZ8lSIBdPajUKX11XE9cHFoJ9FDz7a4XBwVM9iqmOZbSN6Ytf0iZSA9qIP6v/K1V4Zwz
        Qnaytu4qU+abyCXmzFy6Vg==
        """
    /// notBefore + 1 day: the trust evaluation runs at this date, whatever the clock says.
    private static let verifyDate = Date(timeIntervalSince1970: 1_793_459_609)

    private var suites: [String] = []
    private var sessions: [ServerSessions] = []

    override func tearDown() {
        for s in sessions {
            s.images.invalidateAndCancel()
            s.transfers.invalidateAndCancel()
            s.roadTrip.invalidateAndCancel()
        }
        sessions = []
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTrustStore(trusting hosts: [String]) -> TrustedServerStoreImpl {
        let suite = "server-sessions-\(UUID().uuidString)"
        suites.append(suite)
        let store = TrustedServerStoreImpl(defaults: UserDefaults(suiteName: suite)!)
        for host in hosts { store.add(host) }
        return store
    }

    /// Production defaults: no configuration override.
    private func makeSessions(trusting hosts: [String]) -> (ServerSessions, TrustedServerStoreImpl) {
        let store = makeTrustStore(trusting: hosts)
        let made = ServerSessions(trustStore: store, imageCache: URLCache(memoryCapacity: 0, diskCapacity: 0))
        sessions.append(made)
        return (made, store)
    }

    private func serverTrustChallenge(host: String = ServerSessionsTests.host) throws -> URLAuthenticationChallenge {
        let der = try XCTUnwrap(Data(base64Encoded: Self.certificateBase64, options: .ignoreUnknownCharacters))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        // A fresh SecTrust per challenge: the delegate mutates its anchors.
        var created: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &created), errSecSuccess)
        let trust = try XCTUnwrap(created)
        SecTrustSetVerifyDate(trust, Self.verifyDate as CFDate)
        SecTrustSetNetworkFetchAllowed(trust, false)
        return URLAuthenticationChallenge(
            protectionSpace: StubServerTrustSpace(host: host, trust: trust),
            proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil,
            sender: StubChallengeSender()
        )
    }

    private func answer(
        of session: URLSession, for challenge: URLAuthenticationChallenge
    ) throws -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let delegate = try XCTUnwrap(session.delegate as? ServerSessionDelegate)
        let answered = expectation(description: "challenge answered")
        let box = Box<(URLSession.AuthChallengeDisposition, URLCredential?)>()
        delegate.urlSession(session, didReceive: challenge) { disposition, credential in
            box.value = (disposition, credential)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
        return try XCTUnwrap(box.value)
    }

    private func assertTrusted(_ session: URLSession, host: String = ServerSessionsTests.host, file: StaticString = #filePath, line: UInt = #line) throws {
        let (disposition, credential) = try answer(of: session, for: serverTrustChallenge(host: host))
        XCTAssertEqual(disposition, .useCredential, file: file, line: line)
        XCTAssertNotNil(credential, file: file, line: line)
    }

    private func assertRefused(_ session: URLSession, host: String = ServerSessionsTests.host, file: StaticString = #filePath, line: UInt = #line) throws {
        let (disposition, credential) = try answer(of: session, for: serverTrustChallenge(host: host))
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge, file: file, line: line)
        XCTAssertNil(credential, file: file, line: line)
    }

    /// Redirect proposed to `target` for a task whose original request carries a Bearer token.
    private func redirectedRequest(on session: URLSession, to target: String) throws -> URLRequest? {
        let delegate = try XCTUnwrap(session.delegate as? ServerSessionDelegate)
        let originalURL = URL(string: "https://nas.trust.test/api/assets/1/thumbnail")!
        var original = URLRequest(url: originalURL)
        original.setValue("Bearer test-token-123", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: original)
        defer { task.cancel() }
        let targetURL = URL(string: target)!
        let response = HTTPURLResponse(url: originalURL, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
        let answered = expectation(description: "redirect answered")
        let box = Box<URLRequest?>()
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: targetURL)) { request in
            box.value = .some(request)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 2)
        return try XCTUnwrap(box.value)
    }

    // MARK: - TLS trust (AC-1 to AC-4, AC-14)

    func test_AC1_imageSession_trustsASelfSignedHostInTheStore() throws {
        let (made, _) = makeSessions(trusting: [Self.host])
        try assertTrusted(made.images)
    }

    func test_AC2_imageSession_refusesASelfSignedHostOutsideTheStore() throws {
        let (made, _) = makeSessions(trusting: [])
        try assertRefused(made.images)
    }

    func test_AC3_downloadTransport_trustsASelfSignedHostInTheStore() throws {
        let (made, _) = makeSessions(trusting: [Self.host])
        try assertTrusted(made.makeDownloadTransport().session)
    }

    func test_AC4_downloadTransport_refusesASelfSignedHostOutsideTheStore() throws {
        let (made, _) = makeSessions(trusting: [])
        try assertRefused(made.makeDownloadTransport().session)
    }

    func test_AC14_roadTripSession_appliesTheTrustStore() throws {
        let (trusting, _) = makeSessions(trusting: [Self.host])
        try assertTrusted(trusting.roadTrip)
        let (empty, _) = makeSessions(trusting: [])
        try assertRefused(empty.roadTrip)
    }

    func test_AC7_hostApprovedAfterSessionsWereBuilt_isTrustedWithoutNewSession() throws {
        let (made, store) = makeSessions(trusting: [])
        try assertRefused(made.images)
        store.add(Self.host)
        try assertTrusted(made.images)
    }

    // MARK: - Redirects (AC-5, AC-6)

    func test_AC5_everySession_keepsAuthorizationOnSameHostRedirect() throws {
        let (made, _) = makeSessions(trusting: [])
        for session in [made.images, made.transfers, made.roadTrip] {
            let redirected = try redirectedRequest(on: session, to: "https://nas.trust.test/api/assets/1/original")
            XCTAssertEqual(redirected?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123")
        }
    }

    func test_AC6_everySession_dropsAuthorizationOnCrossHostRedirect() throws {
        let (made, _) = makeSessions(trusting: [])
        for session in [made.images, made.transfers, made.roadTrip] {
            let redirected = try redirectedRequest(on: session, to: "https://elsewhere.example/x")
            XCTAssertNotNil(redirected)
            XCTAssertNil(redirected?.value(forHTTPHeaderField: "Authorization"))
        }
    }

    // MARK: - Configuration (AC-11)

    func test_AC11_sessionsKeepTheirOwnConfiguration() {
        let imageCache = URLCache(memoryCapacity: 0, diskCapacity: 0)
        let store = makeTrustStore(trusting: [])
        let made = ServerSessions(trustStore: store, imageCache: imageCache)
        sessions.append(made)
        let reference = URLSessionConfiguration.default

        let images = made.images.configuration
        XCTAssertTrue(images.urlCache === imageCache)
        XCTAssertEqual(images.requestCachePolicy, .returnCacheDataElseLoad)
        XCTAssertEqual(images.timeoutIntervalForRequest, 20)

        for session in [made.transfers, made.roadTrip] {
            let configuration = session.configuration
            XCTAssertFalse(configuration.urlCache === imageCache)
            XCTAssertEqual(configuration.requestCachePolicy, .useProtocolCachePolicy)
            XCTAssertEqual(configuration.timeoutIntervalForRequest, reference.timeoutIntervalForRequest)
            XCTAssertEqual(configuration.timeoutIntervalForResource, reference.timeoutIntervalForResource)
        }
        XCTAssertTrue(made.transfers !== made.roadTrip)
    }

    // MARK: - Reset (AC-13)

    func test_AC13_resetConnections_resetsAllThreeSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-sessions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func makeCache(_ name: String) -> URLCache {
            URLCache(memoryCapacity: 1 << 20, diskCapacity: 4 << 20, directory: root.appendingPathComponent(name, isDirectory: true))
        }
        let cacheImages = makeCache("images"), cacheTransfers = makeCache("transfers"), cacheRoadTrip = makeCache("roadtrip")
        let transfersConfiguration = URLSessionConfiguration.default
        transfersConfiguration.urlCache = cacheTransfers
        let roadTripConfiguration = URLSessionConfiguration.default
        roadTripConfiguration.urlCache = cacheRoadTrip
        let made = ServerSessions(
            trustStore: makeTrustStore(trusting: []), imageCache: cacheImages,
            transfersConfiguration: transfersConfiguration, roadTripConfiguration: roadTripConfiguration
        )
        sessions.append(made)

        let request = URLRequest(url: URL(string: "https://nas.trust.test/api/assets/1/thumbnail")!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        for cache in [cacheImages, cacheTransfers, cacheRoadTrip] {
            cache.storeCachedResponse(CachedURLResponse(response: response, data: Data(repeating: 7, count: 64)), for: request)
            XCTAssertNotNil(cache.cachedResponse(for: request))
        }

        await made.resetConnections()

        XCTAssertNil(cacheImages.cachedResponse(for: request), "images session reset")
        XCTAssertNil(cacheTransfers.cachedResponse(for: request), "transfers session reset")
        XCTAssertNil(cacheRoadTrip.cachedResponse(for: request), "road-trip session reset")
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T?
}

private final class StubChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class StubServerTrustSpace: URLProtectionSpace {
    private let stubTrust: SecTrust

    init(host: String, trust: SecTrust) {
        stubTrust = trust
        super.init(host: host, port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }

    required init?(coder: NSCoder) { nil }

    override var serverTrust: SecTrust? { stubTrust }
}
