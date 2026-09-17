import XCTest
@testable import ImmichSwiftUI

final class AuthenticatedImageRedirectDelegateTests: XCTestCase {

    func testRedirectPreservesAuthorizationOnSameHost() {
        let delegate = AuthenticatedImageRedirectDelegate()
        let originalURL = URL(string: "http://example.com/api/assets/123/thumbnail?size=fullsize")!
        var originalRequest = URLRequest(url: originalURL)
        originalRequest.setValue("Bearer test-token-123", forHTTPHeaderField: "Authorization")

        let session = URLSession.shared
        let task = session.dataTask(with: originalRequest)

        let redirectURL = URL(string: "http://example.com/api/assets/123/original")!
        let redirectRequest = URLRequest(url: redirectURL)
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectURL.absoluteString]
        )!

        let expectation = expectation(description: "Completion handler called")
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirectRequest) { newReq in
            XCTAssertNotNil(newReq)
            XCTAssertEqual(newReq?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-123")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testRedirectDropsAuthorizationOnDifferentHost() {
        let delegate = AuthenticatedImageRedirectDelegate()
        let originalURL = URL(string: "http://example.com/api/assets/123/thumbnail")!
        var originalRequest = URLRequest(url: originalURL)
        originalRequest.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")

        let session = URLSession.shared
        let task = session.dataTask(with: originalRequest)

        let untrustedURL = URL(string: "http://malicious.example.org/tracker")!
        let redirectRequest = URLRequest(url: untrustedURL)
        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": untrustedURL.absoluteString]
        )!

        let expectation = expectation(description: "Completion handler called")
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirectRequest) { newReq in
            XCTAssertNotNil(newReq)
            XCTAssertNil(newReq?.value(forHTTPHeaderField: "Authorization"))
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testThumbnailURLSupportsPreviewAndThumbnailSizes() {
        let base = URL(string: "https://photos.example.com")!
        let previewURL = ImmichAssetURL.thumbnail(
            assetId: "test-id",
            thumbhash: "thumb-123",
            baseURL: base,
            size: .preview
        )
        XCTAssertTrue(previewURL.absoluteString.contains("size=preview"))
        XCTAssertTrue(previewURL.absoluteString.contains("/api/assets/test-id/thumbnail"))

        let thumbURL = ImmichAssetURL.thumbnail(
            assetId: "test-id",
            thumbhash: "thumb-123",
            baseURL: base,
            size: .thumbnail
        )
        XCTAssertTrue(thumbURL.absoluteString.contains("size=thumbnail"))
    }
}
