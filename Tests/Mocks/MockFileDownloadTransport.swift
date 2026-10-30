import Foundation
@testable import ImmichSwiftUI

/// Transport double for the offline cache. `URLProtocol` cannot stand in here:
/// it delivers its payload in one shot and never invokes the download delegate,
/// so a protocol stub can neither write a real file nor report progress.
///
/// `MockFileDownloadTransport` writes the payload to a temp file (like
/// `URLSession.download` does) and replays a scripted progress sequence.
final class MockFileDownloadTransport: FileDownloadTransport, @unchecked Sendable {
    /// Payload written for the next download.
    var payload: Data = Data("payload".utf8)
    /// HTTP status handed back to the store.
    var statusCode: Int? = 200
    var contentType: String? = "image/jpeg"
    /// When set, the download throws instead of producing a file.
    var error: Error?
    /// Progress pairs replayed before the download returns.
    var progressSteps: [(Int64, Int64)] = []
    /// Awaited after the call is counted and before any file is written, so a
    /// test can hold a transfer in flight (and cancel or release it).
    var gate: (@Sendable () async throws -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _gate }
        set { lock.lock(); _gate = newValue; lock.unlock() }
    }
    private var _gate: (@Sendable () async throws -> Void)?

    private let lock = NSLock()
    private(set) var downloadCount = 0
    private(set) var lastRequest: URLRequest?
    /// Temp file most recently written for the store (set when it is written).
    private(set) var lastFileURL: URL?

    func download(
        _ request: URLRequest,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> DownloadedFile {
        lock.lock()
        downloadCount += 1
        lastRequest = request
        let payload = self.payload
        let status = statusCode
        let contentType = self.contentType
        let steps = progressSteps
        let error = self.error
        lock.unlock()

        if let gate = self.gate { try await gate() }

        if let error { throw error }

        for step in steps {
            onProgress(step.0, step.1)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mock-download-\(UUID().uuidString)")
        try payload.write(to: url)
        lock.lock(); lastFileURL = url; lock.unlock()
        return DownloadedFile(url: url, statusCode: status, contentType: contentType)
    }
}

/// Records the progress the store reported, in order.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [(Int64, Int64)] = []

    var values: [(Int64, Int64)] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }

    var fractions: [Double] {
        values.compactMap { received, expected in
            expected > 0 ? Double(received) / Double(expected) : nil
        }
    }

    func record(received: Int64, expected: Int64) {
        lock.lock(); _values.append((received, expected)); lock.unlock()
    }
}
