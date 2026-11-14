import Foundation
import Observation

/// The "Advanced" section's two new instruments (B-31): the log's minimum
/// level and the image cache's size and emptying.
///
/// The log level is a projection of `AppLogStore`, which owns and persists it.
/// The cache size is **measured**, never assumed: the disk occupation is read
/// when the hub opens and again after each emptying, and "emptied" is only
/// announced when that reading falls under `clearedThreshold`. `URLCache`
/// reports no error and keeps an index residue, so a zero is never written by
/// this model — an emptying whose reading stays high, or cannot be made, fails.
@MainActor
@Observable
final class AdvancedSettingsViewModel {
    enum ImageCacheClearResult: Equatable {
        case cleared
        case failed(message: String)
    }

    /// Under 1 MB the cache counts as empty: the disk keeps index files that no
    /// emptying removes, and the screen shows whole megabytes.
    static let clearedThreshold: Int64 = 1_000_000

    private let log: AppLogStore
    private let imageCache: any ImageCacheManaging
    private let rereadAttempts: Int
    private let rereadInterval: Duration

    /// Mirror of the store's level, so the view redraws when the picker writes.
    private var observedLogLevel: AppLogLevel

    /// `nil` until a measurement has succeeded.
    private(set) var imageCacheBytes: Int64?
    private(set) var isClearingImageCache = false
    private(set) var imageCacheResult: ImageCacheClearResult?

    init(
        log: AppLogStore,
        imageCache: any ImageCacheManaging,
        rereadAttempts: Int = 3,
        rereadInterval: Duration = .milliseconds(300)
    ) {
        self.log = log
        self.imageCache = imageCache
        self.rereadAttempts = max(1, rereadAttempts)
        self.rereadInterval = rereadInterval
        observedLogLevel = log.currentMinimumLevel()
    }

    // MARK: - Log level

    var logLevel: AppLogLevel {
        get { observedLogLevel }
        set {
            log.setMinimumLevel(newValue)
            observedLogLevel = newValue
        }
    }

    static func logLevelLabel(_ level: AppLogLevel) -> LocalizedStringResource {
        switch level {
        case .info: "All"
        case .warning: "Warnings"
        case .severe: "Errors"
        }
    }

    // MARK: - Image cache

    /// Whole megabytes, rounded down: "0 MB" is what an emptied cache reads.
    static func formattedSize(_ bytes: Int64) -> String {
        let floored = bytes / 1_000_000 * 1_000_000
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: floored)
    }

    var formattedImageCacheSize: String {
        imageCacheBytes.map(Self.formattedSize) ?? String(localized: "Unavailable")
    }

    var imageCacheFailureMessage: String? {
        if case .failed(let message) = imageCacheResult { return message }
        return nil
    }

    /// Measures the disk occupation. A failed measurement keeps the last one.
    func loadImageCacheSize() async {
        if let bytes = try? await imageCache.diskUsageBytes() {
            imageCacheBytes = bytes
        }
    }

    func clearImageCache() async {
        guard !isClearingImageCache else { return }
        isClearingImageCache = true
        defer { isClearingImageCache = false }

        await imageCache.clear()

        // The disk's own bookkeeping can lag the emptying by a moment: read
        // again, up to `rereadAttempts` times, before deciding.
        var lastReading: Int64?
        for attempt in 0..<rereadAttempts {
            if attempt > 0 { try? await Task.sleep(for: rereadInterval) }
            if let bytes = try? await imageCache.diskUsageBytes() {
                lastReading = bytes
                imageCacheBytes = bytes
                if bytes < Self.clearedThreshold { break }
            }
        }

        if let lastReading, lastReading < Self.clearedThreshold {
            imageCacheResult = .cleared
        } else {
            imageCacheResult = .failed(message: String(localized: "Some cached images could not be removed."))
        }
    }

    func dismissImageCacheResult() {
        imageCacheResult = nil
    }
}
