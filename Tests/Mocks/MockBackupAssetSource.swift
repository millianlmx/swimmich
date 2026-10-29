import Foundation
@testable import ImmichSwiftUI

/// Deterministic library source: canned candidates/albums + per-id payloads.
final class MockBackupAssetSource: BackupAssetSource, @unchecked Sendable {
    nonisolated(unsafe) var candidates: [BackupCandidate] = []
    nonisolated(unsafe) var albums: [BackupAlbum] = []
    nonisolated(unsafe) var dataProvider: (String) -> Data = { _ in Data() }
    nonisolated(unsafe) var loadError: Error?
    /// Candidate ids whose `exportOriginal` throws (per-asset failure), so a
    /// run can mix successes and failures deterministically.
    nonisolated(unsafe) var failIDs: Set<String> = []
    /// Candidate ids whose `exportOriginal` throws `.cloudDownloadPending`
    /// (iCloud original not local yet) — deferred, not a failure.
    nonisolated(unsafe) var deferIDs: Set<String> = []
    /// Invoked exactly once on the first `exportOriginal` — cancellation-path
    /// tests must be idempotent (the engine loops through all candidates
    /// before honoring the flag).
    nonisolated(unsafe) var onFirstLoad: (() -> Void)?
    /// Suspension point inside `exportOriginal`, after `exportedIDs`/`onFirstLoad`,
    /// keyed by candidate id — lets a test hold an export the way an iCloud
    /// download does.
    nonisolated(unsafe) var exportGate: ((String) async throws -> Void)?
    nonisolated(unsafe) var lastAlbumIDs: Set<String>?
    nonisolated(unsafe) var lastExcludedAlbumIDs: Set<String>?
    /// Ids a restricted run asked for, in order — a retry must look its assets
    /// up by identifier instead of enumerating the library.
    nonisolated(unsafe) var requestedIDs: [String] = []
    /// Per-id iCloud states the export reports before it writes, so the
    /// engine's per-asset progress maps are observable without a real iCloud.
    nonisolated(unsafe) var iCloudFractions: [String: Double] = [:]
    nonisolated(unsafe) var iCloudRetries: [String: Int] = [:]
    /// Candidate ids the excluded albums contain, so the mock can honor the
    /// exclusion contract the real source implements.
    nonisolated(unsafe) var excludedAssetIDs: Set<String> = []
    /// Candidate ids that also have a paired video, and the ones whose paired
    /// export should fail / defer instead.
    nonisolated(unsafe) var livePhotoIDs: Set<String> = []
    nonisolated(unsafe) var pairedFailIDs: Set<String> = []
    nonisolated(unsafe) var pairedDeferIDs: Set<String> = []
    /// Called with the exported file's URL right after it is written — before
    /// the caller hashes it.
    nonisolated(unsafe) var onExported: ((URL) -> Void)?
    /// Candidate ids whose export is a file of this many bytes, without the
    /// bytes ever existing in memory (sparse file of zeros).
    nonisolated(unsafe) var sizedIDs: [String: UInt64] = [:]

    private let fetchLock = NSLock()

    func fetchAlbums() -> [BackupAlbum] { albums }

    func fetchCandidates(in albumIDs: Set<String>, excluding excludedAlbumIDs: Set<String>) -> [BackupCandidate] {
        fetchLock.lock()
        lastAlbumIDs = albumIDs
        lastExcludedAlbumIDs = excludedAlbumIDs
        fetchLock.unlock()
        // The exclusion contract lives in the source, so the mock honors it the
        // same way: assets the excluded albums contain are not candidates.
        guard !excludedAlbumIDs.isEmpty, !excludedAssetIDs.isEmpty else { return candidates }
        return candidates.filter { !excludedAssetIDs.contains($0.id) }
    }

    /// Order follows the request, so a restricted run touches exactly the ids
    /// it named (and a test can hand it the same id twice).
    func fetchCandidates(ids: [String]) -> [BackupCandidate] {
        fetchLock.lock()
        requestedIDs.append(contentsOf: ids)
        fetchLock.unlock()
        return ids.compactMap { id in candidates.first { $0.id == id } }
    }

    func exportOriginal(
        for candidate: BackupCandidate,
        into directory: URL,
        onState: @escaping @Sendable (BackupExportState) -> Void
    ) async throws -> URL {
        fetchLock.lock()
        exportedIDs.append(candidate.id)
        fetchLock.unlock()
        if let fraction = iCloudFractions[candidate.id] {
            onState(.downloadingFromICloud(fraction: fraction))
        }
        if let attempt = iCloudRetries[candidate.id] {
            onState(.retryingICloud(attempt: attempt))
        }
        onFirstLoad?()
        onFirstLoad = nil
        if let exportGate { try await exportGate(candidate.id) }
        if let loadError { throw loadError }
        if failIDs.contains(candidate.id) {
            throw APIError.decoding("export failed for \(candidate.id)")
        }
        if deferIDs.contains(candidate.id) {
            throw BackupExportError.cloudDownloadPending
        }
        // The engine's directory maps to the test's own; any other (the Check's)
        // is written as asked, like `writeResource`.
        let target: URL = directory == BackupExportDirectory.backup ? Self.testBackupDirectory : directory
        let url: URL
        if let size = sizedIDs[candidate.id] {
            url = try writeSized(size, named: candidate.fileName, into: target)
        } else {
            url = try write(dataProvider(candidate.id), named: candidate.fileName, into: target)
        }
        onExported?(url)
        return url
    }

    func exportPairedVideo(
        for candidate: BackupCandidate,
        onState: @escaping @Sendable (BackupExportState) -> Void
    ) async throws -> BackupPairedVideo? {
        guard livePhotoIDs.contains(candidate.id) else { return nil }
        if pairedFailIDs.contains(candidate.id) {
            throw APIError.decoding("paired export failed for \(candidate.id)")
        }
        if pairedDeferIDs.contains(candidate.id) {
            throw BackupExportError.cloudDownloadPending
        }
        let name = "\(candidate.id).MOV"
        let url = try write(Data("paired-\(candidate.id)".utf8), named: name)
        return BackupPairedVideo(url: url, fileName: name, duration: 3)
    }

    private func write(_ data: Data, named name: String, into directory: URL? = nil) throws -> URL {
        let dir = directory ?? Self.testBackupDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    /// Where the mock writes what the engine exports, in place of
    /// `BackupExportDirectory.backup`, so a test never touches the real one.
    static var testBackupDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("immich-test-backup", isDirectory: true)
    }

    /// A file of exactly `size` bytes that is never materialized: truncating an
    /// empty file to `size` makes it sparse.
    private func writeSized(_ size: UInt64, named name: String, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: size)
        return url
    }

    nonisolated(unsafe) var purgeCount = 0
    /// Ids the engine actually asked to export, in order — the network-policy
    /// tests assert a deferred asset is *never* exported.
    nonisolated(unsafe) var exportedIDs: [String] = []
    /// `deviceAssetID → deviceAlbumIDs`, the inverse index the real source
    /// derives from Photos. Returned as-is, filtered to the ids asked for.
    nonisolated(unsafe) var albumMembershipByDeviceAlbum: [String: [String]] = [:]
    func purgeStaleExports() { purgeCount += 1 }

    func albumMembership(deviceAlbumIDs: Set<String>) -> [String: [String]] {
        guard !deviceAlbumIDs.isEmpty else { return [:] }
        return albumMembershipByDeviceAlbum.compactMapValues { albumIDs in
            let kept = albumIDs.filter { deviceAlbumIDs.contains($0) }
            return kept.isEmpty ? nil : kept
        }
    }
}

/// Deterministic environment — tests toggle the gates by hand.
final class MockBackupEnvironment: BackupEnvironment, @unchecked Sendable {
    nonisolated(unsafe) var isChargingValue = true
    nonisolated(unsafe) var hasWiFiValue = true
    nonisolated(unsafe) var isOnlineValue = true

    var isCharging: Bool { isChargingValue }
    var hasWiFiConnection: Bool { hasWiFiValue }
    var isOnline: Bool { isOnlineValue }
}

/// Records submissions; production analog is BGTaskScheduler.
final class MockBackupScheduler: BackgroundBackupScheduling, @unchecked Sendable {
    nonisolated(unsafe) var submitCount = 0
    func submit() { submitCount += 1 }
}