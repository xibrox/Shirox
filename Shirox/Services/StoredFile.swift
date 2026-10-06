import Foundation

/// Bytes kept in a file of their own in Application Support rather than in UserDefaults.
///
/// UserDefaults keeps every value in one plist and rewrites all of it whenever any one changes. With
/// megabytes of module scripts and ID mappings in it, every small setting written anywhere —
/// Continue Watching's, every ten seconds of playback — was a write of megabytes.
struct StoredFile {
    let url: URL
    private let legacyKey: String?
    private let defaults: UserDefaults

    /// - Parameters:
    ///   - legacyKey: where UserDefaults held this before, moved over the first time it's loaded.
    ///   - directory: Application Support, unless a test says otherwise.
    init(name: String, legacyKey: String? = nil,
         directory: URL = AppDirectories.applicationSupport,
         defaults: UserDefaults = .standard) {
        url = directory.appendingPathComponent(name)
        self.legacyKey = legacyKey
        self.defaults = defaults
    }

    /// What's stored: the file's bytes, or the first time, what UserDefaults held — moved into the
    /// file. A dictionary or array there comes back as JSON.
    func load() -> Data? {
        if let data = try? Data(contentsOf: url) { return data }
        guard let legacyKey, let value = defaults.object(forKey: legacyKey) else { return nil }
        let data: Data?
        if let bytes = value as? Data {
            data = bytes
        } else if JSONSerialization.isValidJSONObject(value) {
            data = try? JSONSerialization.data(withJSONObject: value)
        } else {
            data = nil
        }
        guard let data else { return nil }
        if write(data) { defaults.removeObject(forKey: legacyKey) }
        return data
    }

    /// What can't be written — a full disk — is kept in UserDefaults as it was before, not lost.
    func save(_ data: Data) {
        if write(data) {
            if let legacyKey, defaults.object(forKey: legacyKey) != nil { defaults.removeObject(forKey: legacyKey) }
        } else if let legacyKey {
            // An older file would be read before it.
            try? FileManager.default.removeItem(at: url)
            defaults.set(data, forKey: legacyKey)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        if let legacyKey { defaults.removeObject(forKey: legacyKey) }
    }

    /// The file's size in bytes, 0 if there's none — for the storage view.
    var size: Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func write(_ data: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Logger.shared.log("[Storage] Couldn't write \(url.lastPathComponent): \(error.localizedDescription)", type: "Error")
            return false
        }
    }
}
