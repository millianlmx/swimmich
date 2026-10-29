import Foundation
import Photos
@testable import ImmichSwiftUI

final class MockPhotoLibraryService: PhotoLibraryService, @unchecked Sendable {
    nonisolated(unsafe) var savedImageData: Data?
    nonisolated(unsafe) var savedVideoURL: URL?
    nonisolated(unsafe) var savedIdentifier = "local://mock"
    nonisolated(unsafe) var saveError: Error?

    func authorizationStatus() -> PHAuthorizationStatus { .authorized }
    func requestAuthorization(_ handler: @escaping (PHAuthorizationStatus) -> Void) { handler(.authorized) }
    func fetchAssets() -> [PHAsset] { [] }
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
