import XCTest
@testable import ImmichSwiftUI

// L-09: the pure rules of custom HTTP headers — which server a header list
// belongs to (`ServerKey`), what the editor accepts (`CustomHeaderValidation`),
// how a request is dressed (`ServerRequestAuthorization`), and what the video
// engine hands AVFoundation.

final class ServerKeyTests: XCTestCase {

    private func key(_ address: String) -> ServerKey? {
        URL(string: address).flatMap(ServerKey.init(url:))
    }

    func test_hostIsLowercasedAndPortIsEffective() {
        XCTAssertEqual(key("https://Photos.Example.org/")?.rawValue, "photos.example.org:443")
        XCTAssertEqual(key("http://photos.example.org")?.rawValue, "photos.example.org:80")
        XCTAssertEqual(key("https://photos.example.org:8443")?.rawValue, "photos.example.org:8443")
    }

    func test_loopbackNamesAreTwoServers() {
        XCTAssertEqual(key("http://127.0.0.1:8421")?.rawValue, "127.0.0.1:8421")
        XCTAssertEqual(key("http://localhost:8421")?.rawValue, "localhost:8421")
        XCTAssertNotEqual(key("http://127.0.0.1:8421"), key("http://localhost:8421"))
    }

    func test_ipv6HostIsBracketed() {
        XCTAssertEqual(key("http://[::1]:8421")?.rawValue, "[::1]:8421")
    }

    func test_unusableAddressesHaveNoKey() {
        XCTAssertNil(key("ftp://x"))
        XCTAssertNil(key("photos"))
        XCTAssertNil(key("https://"))
    }

    // AC-123: every spelling of one address is one server; another port is another.
    func test_AC_123_equivalentAddressesShareAKey() {
        let spellings = [
            "https://photos.example.org",
            "https://photos.example.org/",
            "https://Photos.Example.ORG",
            "https://photos.example.org:443",
            "https://photos.example.org:443/api",
            "HTTPS://photos.example.org",
        ]
        let keys = Set(spellings.compactMap(key))
        XCTAssertEqual(keys.count, 1)
        XCTAssertNotEqual(key("https://photos.example.org:8443"), key("https://photos.example.org"))
    }

    func test_displayNameHidesDefaultPorts() {
        XCTAssertEqual(key("https://photos.example.org")?.displayName, "photos.example.org")
        XCTAssertEqual(key("http://photos.example.org")?.displayName, "photos.example.org")
        XCTAssertEqual(key("https://photos.example.org:8443")?.displayName, "photos.example.org:8443")
        XCTAssertEqual(key("http://127.0.0.1:8421")?.displayName, "127.0.0.1:8421")
    }
}

final class CustomHeaderValidationTests: XCTestCase {

    private typealias Row = (name: String, value: String)

    private func validate(_ rows: [Row]) -> (headers: [CustomHTTPHeader], issues: [Int: CustomHeaderIssue]) {
        CustomHeaderValidation.validate(rows)
    }

    func test_AC_121_namesAndValuesAreTrimmedAndTheCaseIsKept() {
        let result = validate([(" X-Access ", " secret ")])
        XCTAssertEqual(result.headers, [CustomHTTPHeader(name: "X-Access", value: "secret")])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func test_AC_121_nameWithASpaceIsInvalid() {
        XCTAssertEqual(validate([("X Access", "v")]).issues, [0: .invalidName])
    }

    func test_AC_121_nameOutsideTheTokenAlphabetIsInvalid() {
        XCTAssertEqual(validate([("X-Accès", "v")]).issues, [0: .invalidName])
        XCTAssertEqual(validate([("X:Access", "v")]).issues, [0: .invalidName])
    }

    func test_AC_121_everyReservedNameIsRefusedWithoutCase() {
        for name in ["x-immich-user-token", "Cookie", "ACCEPT", "Host", "Content-Type", "content-length",
                     "x-immich-checksum", "Connection", "Proxy-Authorization", "WWW-Authenticate"] {
            XCTAssertEqual(validate([(name, "v")]).issues, [0: .reservedName], name)
        }
    }

    func test_AC_121_authorizationIsAccepted() {
        let result = validate([("Authorization", "Basic dXNlcjpwYXNz")])
        XCTAssertEqual(result.headers, [CustomHTTPHeader(name: "Authorization", value: "Basic dXNlcjpwYXNz")])
        XCTAssertTrue(result.issues.isEmpty)
    }

    func test_AC_121_userAgentStaysAllowed() {
        XCTAssertTrue(validate([("User-Agent", "x"), ("Accept-Language", "y"), ("Accept-Encoding", "z")]).issues.isEmpty)
    }

    func test_AC_121_secondOccurrenceIsADuplicateWithoutCase() {
        let result = validate([("X-Access", "a"), ("x-access", "b")])
        XCTAssertEqual(result.issues, [1: .duplicateName])
        XCTAssertEqual(result.headers, [CustomHTTPHeader(name: "X-Access", value: "a")])
    }

    func test_AC_121_controlCharacterValueIsRefused() {
        XCTAssertEqual(validate([("X-Access", "a\r\nX-Evil: 1")]).issues, [0: .invalidValue])
        XCTAssertEqual(validate([("X-Access", "a\u{7F}")]).issues, [0: .invalidValue])
        XCTAssertEqual(validate([("X-Access", "a\u{0}b")]).issues, [0: .invalidValue])
        // A horizontal tab inside the value is allowed by RFC 9110.
        XCTAssertTrue(validate([("X-Access", "a\tb")]).issues.isEmpty)
    }

    func test_AC_121_blankRowsAreIgnoredWithoutAMessage() {
        let result = validate([("", "v"), ("X-A", "  "), ("   ", "  ")])
        XCTAssertTrue(result.headers.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func test_issuesAreKeyedByTheInputIndex() {
        let result = validate([("", ""), ("X-A", "1"), ("bad name", "2"), ("X-B", "3")])
        XCTAssertEqual(result.issues, [2: .invalidName])
        XCTAssertEqual(result.headers.map(\.name), ["X-A", "X-B"])
    }

    func test_aRowInErrorNeverEntersTheHeaders() {
        let result = validate([("Cookie", "v")])
        XCTAssertTrue(result.headers.isEmpty)
    }
}

final class ServerRequestAuthorizationTests: XCTestCase {

    private func dictionary(_ token: String?, _ custom: [CustomHTTPHeader]) -> [String: String] {
        ServerRequestAuthorization.dictionary(token: token, custom: custom)
    }

    // AC-124 / B-10: without custom headers, today's headers exactly.
    func test_AC_124_noCustomHeadersMeansBearerOnly() {
        let fields = ServerRequestAuthorization.fields(token: "t", custom: [])
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.name, "Authorization")
        XCTAssertEqual(fields.first?.value, "Bearer t")
        XCTAssertTrue(ServerRequestAuthorization.fields(token: nil, custom: []).isEmpty)
        XCTAssertTrue(ServerRequestAuthorization.fields(token: "", custom: []).isEmpty)
    }

    func test_customHeadersComeWithTheBearer() {
        XCTAssertEqual(
            dictionary("t", [StaticCustomHeaders.xAccess]),
            ["X-Access": "secret", "Authorization": "Bearer t"]
        )
        XCTAssertEqual(dictionary(nil, [StaticCustomHeaders.xAccess]), ["X-Access": "secret"])
    }

    // AC-125: a custom Authorization (proxy Basic auth) moves the token.
    func test_AC_125_customAuthorizationMovesTokenToUserTokenHeader() {
        let fields = dictionary("t", [StaticCustomHeaders.basic])
        XCTAssertEqual(fields, ["Authorization": "Basic dXNlcjpwYXNz", "x-immich-user-token": "t"])
        XCTAssertFalse(fields.values.contains { $0.hasPrefix("Bearer") })
    }

    func test_customAuthorizationMatchesWithoutCase() {
        let fields = dictionary("t", [CustomHTTPHeader(name: "authorization", value: "Basic x")])
        XCTAssertEqual(fields, ["authorization": "Basic x", "x-immich-user-token": "t"])
    }

    func test_theTokenNeverAppearsTwice() {
        for custom in [[], [StaticCustomHeaders.basic], [StaticCustomHeaders.xAccess]] {
            let values = ServerRequestAuthorization.fields(token: "tok", custom: custom).map(\.value)
            XCTAssertEqual(values.filter { $0.contains("tok") }.count, 1)
        }
    }

    func test_aStoredInvalidOrReservedElementIsSkipped() {
        let custom = [
            CustomHTTPHeader(name: "bad name", value: "v"),
            CustomHTTPHeader(name: "Cookie", value: "v"),
            CustomHTTPHeader(name: "x-immich-user-token", value: "forged"),
            StaticCustomHeaders.xAccess,
        ]
        XCTAssertEqual(dictionary("t", custom), ["X-Access": "secret", "Authorization": "Bearer t"])
    }

    func test_applySetsEveryFieldOnTheRequest() {
        var request = URLRequest(url: URL(string: "https://photos.example.org/api")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        ServerRequestAuthorization.apply(token: "t", custom: [StaticCustomHeaders.xAccess], to: &request)
        XCTAssertEqual(request.allHTTPHeaderFields, [
            "Accept": "application/json", "X-Access": "secret", "Authorization": "Bearer t",
        ])
    }
}

final class AVVideoPlaybackEngineTests: XCTestCase {
    private let key = "AVURLAssetHTTPHeaderFieldsKey"
    private let videoURL = URL(string: "https://photos.example.org/api/assets/v1/video/playback")!

    private func fields(_ options: [String: Any]) -> [String: String]? {
        options[key] as? [String: String]
    }

    func test_AC_118_assetOptionsCarryHeaders() {
        let headers = StaticCustomHeaders([StaticCustomHeaders.xAccess], for: "https://photos.example.org")
        let options = AVVideoPlaybackEngine.assetOptions(url: videoURL, token: "t", customHeaders: headers)
        XCTAssertEqual(fields(options), ["X-Access": "secret", "Authorization": "Bearer t"])
    }

    func test_AC_118_anotherServersListIsNotSent() {
        let headers = StaticCustomHeaders([StaticCustomHeaders.xAccess], for: "https://other.example.org")
        let options = AVVideoPlaybackEngine.assetOptions(url: videoURL, token: "t", customHeaders: headers)
        XCTAssertEqual(fields(options), ["Authorization": "Bearer t"])
    }

    func test_AC_118_noTokenAndNoHeadersMeansNoOptions() {
        let options = AVVideoPlaybackEngine.assetOptions(url: videoURL, token: nil, customHeaders: NoCustomHeaders())
        XCTAssertTrue(options.isEmpty)
    }

    func test_AC_125_assetOptionsUseUserTokenHeader() {
        let headers = StaticCustomHeaders([StaticCustomHeaders.basic], for: "https://photos.example.org")
        let options = AVVideoPlaybackEngine.assetOptions(url: videoURL, token: "t", customHeaders: headers)
        XCTAssertEqual(fields(options), ["Authorization": "Basic dXNlcjpwYXNz", "x-immich-user-token": "t"])
    }
}
