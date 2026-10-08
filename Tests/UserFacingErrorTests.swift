import XCTest
@testable import ImmichSwiftUI

/// Contract for the single error-copy mapping (`UserFacingError`, SP-1…SP-4).
final class UserFacingErrorTests: XCTestCase {

    private struct OpaqueError: Error {}

    // AC-10: a cancelled request is "no event": no family, no message, no banner.
    func test_AC10_cancelledRequestIsIndistinguishableFromNoEvent() {
        let cancelled: [Error] = [
            CancellationError(),
            URLError(.cancelled),
            APIError.network(URLError(.cancelled)),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ]
        for error in cancelled {
            XCTAssertNil(UserFacingError.from(error), "\(error) must map to no event")
            XCTAssertNil(error.userFacingMessage, "\(error) must show no message")
            XCTAssertTrue(UserFacingError.isCancellation(error), "\(error) must be a cancellation")
        }
    }

    // AC-5: the four families map to four distinct, localized copies.
    func test_AC5_errorFamiliesProduceFourDistinctLocalizedCopies() {
        XCTAssertEqual(UserFacingError.from(URLError(.notConnectedToInternet))?.family, .offline)
        XCTAssertEqual(UserFacingError.from(APIError.serverError(500, "boom"))?.family, .serverError)
        XCTAssertEqual(UserFacingError.from(APIError.http(503))?.family, .serverError)
        XCTAssertEqual(UserFacingError.from(APIError.unauthorized)?.family, .sessionExpired)
        XCTAssertEqual(UserFacingError.from(APIError.decoding("boom"))?.family, .other)

        let offline = localizedString("No network connection. Check your connection and try again.")
        let server = localizedString("The server ran into a problem. Please try again.")
        let expired = localizedString("Your session has expired. Please sign in again.")
        let other = localizedString("Something went wrong. Please try again.")

        XCTAssertEqual(UserFacingError.offlineMessage, offline)
        XCTAssertEqual(UserFacingError.serverErrorMessage, server)
        XCTAssertEqual(UserFacingError.sessionExpiredMessage, expired)
        XCTAssertEqual(UserFacingError.genericMessage, other)

        let copies = [offline, server, expired, other]
        XCTAssertEqual(Set(copies).count, 4, "the four families must read differently")
    }

    // AC-3: no raw technical text reaches the UI, through either entry point.
    func test_AC3_noRawTechnicalTextReachesTheUi() {
        let errors: [Error] = [
            APIError.network(URLError(.timedOut)),
            APIError.serverError(500, "boom"),
            APIError.decoding("boom"),
            APIError.http(404),
            URLError(.cannotConnectToHost),
        ]
        let forbidden = [
            "Network error", "Decoding failed", "HTTP", "boom",
            "The operation couldn't be completed", "annulé", "cancelled",
        ]
        for error in errors {
            guard let message = error.userFacingMessage else {
                XCTFail("\(error) should map to a message")
                continue
            }
            for fragment in forbidden {
                XCTAssertFalse(message.contains(fragment), "\(error) leaks “\(fragment)”: \(message)")
            }
            XCTAssertEqual((error as? APIError)?.errorDescription ?? message, message,
                           "APIError.errorDescription must render the same copy")
        }
    }

    // AC-4: a server error body is never rendered.
    func test_AC4_serverBodyIsNeverRendered() {
        let message = APIError.serverError(500, "boom").userFacingMessage
        XCTAssertNotNil(message)
        XCTAssertFalse(message?.contains("boom") ?? true)
    }

    // AC-6: an error without a known family falls back to the generic copy.
    func test_AC6_unknownErrorFallsBackToGenericCopy() {
        struct LocalError: Error {}
        let mapped = UserFacingError.from(LocalError())
        XCTAssertEqual(mapped?.family, .other)
        XCTAssertEqual(mapped?.message, localizedString("Something went wrong. Please try again."))
    }
}
