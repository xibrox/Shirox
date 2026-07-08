import Foundation
import Combine

#if os(tvOS)
import FakeWebKit
#else
import WebKit
#endif

@MainActor
final class CacheManager: ObservableObject {
    static let shared = CacheManager()
    
    private init() {}
    
    // MARK: - Size Calculations
    
    /// Kingfisher owns all image caching (its own disk storage, capped at 500 MB).
    /// `URLCache.shared` no longer holds images — it's the general HTTP/API response
    /// cache — so counting it here double-counted and pushed the figure past the cap.
    var imageCacheSize: Int {
        get async { await CachedAsyncImage.diskCacheBytes }
    }
    
    var websiteDataSize: Int {
        let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let webKitFolders = ["Caches", "WebKit", "Cookies"]
        var total = 0
        for folder in webKitFolders {
            let url = libraryDir.appendingPathComponent(folder)
            total += (try? sizeOfDirectory(at: url)) ?? 0
        }
        return total
    }
    
    var tempFilesSize: Int {
        let tempDir = FileManager.default.temporaryDirectory
        return (try? sizeOfDirectory(at: tempDir)) ?? 0
    }
    
    var continueWatchingSize: Int {
        let keys = ["continueWatchingItems", "watchedEpisodeKeys"]
        var total = 0
        for key in keys {
            if let data = UserDefaults.standard.data(forKey: key) {
                total += data.count
            }
        }
        return total
    }
    
    var watchHistorySize: Int {
        if let data = UserDefaults.standard.data(forKey: "watchHistory") {
            return data.count
        }
        return 0
    }

    var searchAliasSize: Int {
        let prefixes = ["moduleSearchAlias_", "moduleLastSearchResult_", "moduleLastStreamTitle_"]
        return UserDefaults.standard.dictionaryRepresentation()
            .filter { key, _ in prefixes.contains(where: { key.hasPrefix($0) }) }
            .values.compactMap { $0 as? String }
            .reduce(0) { $0 + $1.utf8.count }
    }

    var idMappingSize: Int {
        (UserDefaults.standard.data(forKey: "id_mappings_cache")?.count ?? 0)
    }

    var episodeSortSize: Int {
        guard let dict = UserDefaults.standard.dictionary(forKey: "individualSortPreferences") else { return 0 }
        return dict.count * 16
    }

    var libraryCacheSize: Int {
        LibraryCacheStore.shared.diskByteSize()
    }

    var profileCacheSize: Int {
        ProfileCacheStore.shared.diskByteSize()
    }

    var totalDiskUsage: Int {
        get async {
            (await imageCacheSize) + websiteDataSize + tempFilesSize + continueWatchingSize
                + watchHistorySize + searchAliasSize + idMappingSize + episodeSortSize
                + libraryCacheSize + profileCacheSize
        }
    }

    // MARK: - Individual Reset Methods

    func clearImageCache() {
        CachedAsyncImage.resetCache()
    }

    func clearWebsiteData() async {
        #if !os(tvOS)
        // TODO: Update FakeWebkit to support these
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: dataTypes, modifiedSince: .distantPast)
        #endif
    }

    func clearTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in contents {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func clearContinueWatching() {
        ContinueWatchingManager.shared.resetAllData()
    }

    func clearWatchHistory() {
        WatchHistoryService.shared.history = []
        UserDefaults.standard.removeObject(forKey: "watchHistory")
    }

    func clearSearchAliases() {
        ModuleSearchAliasManager.shared.clearAll()
    }

    func clearIDMappingCache() {
        IDMappingService.shared.clearCache()
    }

    func clearEpisodeSortPreferences() {
        EpisodeSortManager.shared.clearAllIndividualPreferences()
    }

    func clearLibraryCache() {
        LibraryCacheStore.shared.clearAll()
    }

    func clearProfileCache() {
        ProfileCacheStore.shared.clearAll()
    }

    func clearEverything() async {
        clearImageCache()
        await clearWebsiteData()
        clearTempFiles()
        clearContinueWatching()
        clearWatchHistory()
        clearSearchAliases()
        clearIDMappingCache()
        clearEpisodeSortPreferences()
        clearLibraryCache()
        clearProfileCache()
        cleanupOrphanedDownloads()
    }
    
    // MARK: - Helpers

    private func sizeOfDirectory(at url: URL) throws -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        
        var total = 0
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(keys))
            if let isDirectory = resourceValues.isDirectory, !isDirectory {
                total += resourceValues.fileSize ?? 0
            }
        }
        return total
    }

    private func cleanupOrphanedDownloads() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadDir = docs.appendingPathComponent("Downloads", isDirectory: true)
        // Downloads list now lives in an atomic file (see DownloadManager.persist); fall back to
        // the legacy UserDefaults key so this stays correct if the migration hasn't run yet.
        let manifestURL = docs.appendingPathComponent("downloads_manifest.json")
        let manifestData = (try? Data(contentsOf: manifestURL))
            ?? UserDefaults.standard.data(forKey: "shirox_downloads_v3")

        guard let contents = try? FileManager.default.contentsOfDirectory(at: downloadDir, includingPropertiesForKeys: nil),
              let savedData = manifestData,
              let items = try? JSONDecoder().decode([DownloadItem].self, from: savedData) else {
            return
        }
        
        // Every download artifact is named after its item's UUID (HLS folder "<id>", MP4
        // "<id>.mp4", subtitle "<id>.<ext>"). Gate on that UUID so this only ever reclaims
        // real orphans: the gate skips the `Snapshots/` folder (keyed by mediaKey) and keeps
        // an item's subtitle sidecar, both of which the old fileName/dir checks wrongly deleted.
        let validIds = Set(items.map { $0.id })

        for file in contents {
            let name = file.lastPathComponent
            let ownerString = String(name.prefix(while: { $0 != "." }))
            guard let owner = UUID(uuidString: ownerString) else { continue }
            guard !validIds.contains(owner) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
