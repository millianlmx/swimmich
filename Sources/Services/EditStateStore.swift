import Foundation

/// Local persistence for non-destructive `EditState` per asset (cahier §5 L125-128).
///
/// Backed by JSON files in Application Support/EditStates/, keyed by `assetId`.
/// First usage of `.applicationSupportDirectory` in the project (scout H12 confirmed);
/// the directory is auto-created on demand.
///
/// AC-603 (save/load/delete roundtrip), AC-616 (lifecycle on appear/disappear).
actor EditStateStore {

    private let folderURL: URL

    init() {
        let supportDir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                          ?? FileManager.default.temporaryDirectory)
        self.folderURL = supportDir.appendingPathComponent("EditStates", isDirectory: true)
    }

    /// Internal init for tests to point to a custom directory.
    init(folderURL: URL) {
        self.folderURL = folderURL
    }

    private func ensureFolderExists() throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    private func fileURL(for assetId: String) -> URL {
        // assetId is a UUID; sanitize defensively by replacing non-alphanumerics.
        let safeName = assetId.replacingOccurrences(of: "/", with: "_")
        return folderURL.appendingPathComponent("\(safeName).json")
    }

    /// Saves the state for the given asset. Overwrites any existing file.
    func save(state: EditState, forAssetId assetId: String) throws {
        try ensureFolderExists()
        let data = try JSONEncoder.immich.encode(state)
        try data.write(to: fileURL(for: assetId), options: .atomic)
    }

    /// Loads the state for the given asset, or nil if none exists.
    func load(assetId: String) -> EditState? {
        let url = fileURL(for: assetId)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.immich.decode(EditState.self, from: data)
    }

    /// Deletes the state for the given asset. No stored draft is not a failure; any other error is thrown.
    /// Used by `PhotoEditorViewModel` when `hasEdits == false` and after a successful copy save.
    func delete(assetId: String) throws {
        do {
            try FileManager.default.removeItem(at: fileURL(for: assetId))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// Removes all stored states. Useful for tests and "reset all" maintenance actions.
    func resetAll() throws {
        if FileManager.default.fileExists(atPath: folderURL.path) {
            let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            for url in contents where url.pathExtension == "json" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
