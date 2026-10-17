import Foundation
import Photos
@testable import ImmichSwiftUI

final class MockPhotoLibraryService: PhotoLibraryService, @unchecked Sendable {
    nonisolated(unsafe) var savedImageData: Data?
    nonisolated(unsafe) var savedVideoURL: URL?
    nonisolated(unsafe) var savedIdentifier = "local://mock"
    nonisolated(unsafe) var saveError: Error?

    /// The status the system reports. Defaults to the pre-existing behavior of
    /// this mock (full access) so tests that don't care keep passing.
    nonisolated(unsafe) var status: PHAuthorizationStatus = .authorized
    /// What the system answers once the (simulated) prompt is answered.
    nonisolated(unsafe) var statusAfterRequest: PHAuthorizationStatus = .authorized
    /// How many times the prompt was raised.
    nonisolated(unsafe) private(set) var requestCount = 0

    func authorizationStatus() -> PHAuthorizationStatus { status }
    func requestAuthorization(_ handler: @escaping (PHAuthorizationStatus) -> Void) {
        requestCount += 1
        status = statusAfterRequest
        handler(status)
    }
    func fetchAssets() -> [PHAsset] { [] }
    func loadData(for asset: PHAsset) async throws -> Data { Data() }
    func checksum(for asset: PHAsset) async throws -> String { "" }
    func isoTimestamps(for asset: PHAsset) -> (createdAt: String, modifiedAt: String) {
        ("2024-07-01T00:00:00.000Z", "2024-07-01T00:00:00.000Z")
    }
    func saveImage(data: Data) async throws -> String {
        if let saveError { throw saveError }
        savedImageData = data
        return savedIdentifier
    }
    func saveVideo(at fileURL: URL) async throws -> String {
        if let saveError { throw saveError }
        savedVideoURL = fileURL
        return savedIdentifier
    }
}
