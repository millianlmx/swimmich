import Foundation

/// `URLSession`-backed `FileDownloadTransport`.
///
/// `URLSession.downloadTask(with:)` streams the body straight into a
/// system-managed temp file — the bytes never pass through this process as a
/// `Data`, which is what makes caching a multi-gigabyte video survivable.
///
/// The task is resumed through its own delegate, NOT through
/// `session.download(for:delegate:)`. Measured on this toolchain: the ASYNC
/// variant never delivers a single `URLSessionDownloadDelegate` callback — 0
/// `didWriteData`, 0 `didCompleteWithError`, for both a
/// `URLSessionTaskDelegate` and a `URLSessionDownloadDelegate`, on
/// `URLSession.shared` and on a custom session — so `onProgress` was never
/// called and every caller's bar sat at 0 % until the transfer ended. The same
/// request through `downloadTask(with:)` + `task.delegate` reports progress
/// normally. Hence this shape, and the continuation below to keep the `async`
/// signature the callers already use.
struct URLSessionFileDownloadTransport: FileDownloadTransport {
    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func download(
        _ request: URLRequest,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> DownloadedFile {
        let delegate = DownloadDelegate(onProgress: onProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(request, in: session, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Resumes one download: bridges `URLSessionDownloadDelegate` to a continuation
/// and to the progress closure. URLSession calls it on its own delegate queue,
/// hence the lock around the three pieces of state it hands back.
/// Internal (not `private`) so the transport tests can drive its callbacks.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    /// Set when the transfer is cancelled before `start` had a task to cancel.
    private var cancelledEarly = false
    private var continuation: CheckedContinuation<DownloadedFile, Error>?
    /// Where the streamed body was moved out of the system's temp file, and the
    /// failure of that move, if any.
    private var file: URL?
    private var moveError: Error?

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    /// Where `didFinishDownloadingTo` moved the body, or nil. Read by tests.
    var movedFileURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return file
    }

    // MARK: - Lifecycle

    func start(
        _ request: URLRequest,
        in session: URLSession,
        continuation: CheckedContinuation<DownloadedFile, Error>
    ) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        let task = session.downloadTask(with: request)
        lock.lock()
        self.task = task
        let alreadyCancelled = cancelledEarly
        lock.unlock()

        task.delegate = self
        task.resume()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelledEarly = true
        let task = self.task
        lock.unlock()
        // The error this produces is `URLError(.cancelled)`, which is what the
        // callers test for — a cancel is not a failure.
        task?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // `totalBytesExpectedToWrite` is -1 when the server sent no
        // `Content-Length`; the protocol spells that case as 0. Never a
        // negative denominator, hence never a bar that jumps to 100 %.
        onProgress(totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // NOT optional housekeeping: the file at `location` is deleted as soon
        // as this method returns, so it has to be moved before the continuation
        // is resumed. A flat temp file, not a folder: both callers move it (or
        // delete it) straight away, and a folder would be left behind empty.
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("immich-download-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            file = destination
            lock.unlock()
        } catch {
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let file = self.file
        let moveError = self.moveError
        lock.unlock()

        guard let continuation else { return }

        if let error {
            discard(file)
            continuation.resume(throwing: error)
            return
        }
        if let moveError {
            discard(file)
            continuation.resume(throwing: moveError)
            return
        }
        guard let file else {
            continuation.resume(throwing: URLError(.cannotCreateFile))
            return
        }
        let response = task.response as? HTTPURLResponse
        continuation.resume(returning: DownloadedFile(
            url: file,
            statusCode: response?.statusCode,
            contentType: response?.value(forHTTPHeaderField: "Content-Type")
        ))
    }

    /// Deletes the received file ONLY. It sits flat in `NSTemporaryDirectory()`,
    /// so removing its parent would wipe every other temp file of the app.
    private func discard(_ file: URL?) {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
