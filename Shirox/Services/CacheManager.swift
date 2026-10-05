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
    
    /// What Reset Website Data removes: WebKit's own folders. It used to measure all of
    /// `Library/Caches`, which holds the image cache too, so the figure never went down after a
    /// reset and the image cache was counted twice in the total.
    var websiteDataSize: Int {
        let fm = FileManager.default
        let libraryDir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let caches = libraryDir.appendingPathComponent("Caches")
        var folders = [libraryDir.appendingPathComponent("WebKit"),
                       libraryDir.appendingPathComponent("Cookies"),
                       caches.appendingPathComponent("WebKit")]
        if let bundleID = Bundle.main.bundleIdentifier {
            folders.append(caches.appendingPathComponent(bundleID).appendingPathComponent("WebKit"))
        }
        return folders.reduce(0) { $0 + ((try? sizeOfDirectory(at: $1)) ?? 0) }
    }
    
    var tempFilesSize: Int {
        let tempDir = FileManager.default.temporaryDirectory
        return (try? sizeOfDirectory(at: tempDir)) ?? 0
    }
    
    var continueWatchingSize: Int {
        // Everything Reset Watch Progress clears: the cards, both kinds of watched mark, and the
        // resets held back from the tracker syncs. Only the first two were counted.
        let keys = ["continueWatchingItems", "watchedEpisodeKeys", "watchedEpisodeHrefKeys", "trackerResetFloors"]
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
        IDMappingService.shared.storageSize
    }

    var episodeSortSize: Int {
        guard let dict = UserDefaults.standard.dictionary(forKey: "individualSortPreferences") else { return 0 }
        return dict.count * 16
    }

    /// The HTTP response cache every request shares (`URLCache.shared`): API answers and pages.
    /// It was neither counted nor cleared anywhere.
    var networkCacheSize: Int {
        URLCache.shared.currentDiskUsage
    }

    /// Home's saved rows, Simkl's lists and catalog pages, and AniList-to-TVDB episode
    /// mappings: all fetched again when gone, and none counted or cleared before.
    var dataCacheSize: Int {
        dataCacheFiles.reduce(0) { total, url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return total }
            if isDirectory.boolValue { return total + ((try? sizeOfDirectory(at: url)) ?? 0) }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + size
        } + HomeCacheStore.shared.diskByteSize()
    }

    private var dataCacheFiles: [URL] {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ["simkl-feed", "simkl-catalog", "anira_all_mappings_v2.json", "anira_all_mappings_v1.json"]
            .map { caches.appendingPathComponent($0) }
    }

    var libraryCacheSize: Int {
        LibraryCacheStore.shared.diskByteSize()
    }

    var profileCacheSize: Int {
        ProfileCacheStore.shared.diskByteSize()
    }

    var totalDiskUsage: Int {
        get async {
            // What Clear Everything clears, so the figure beside it is what it frees.
            (await imageCacheSize) + websiteDataSize + tempFilesSize
                + searchAliasSize + idMappingSize + episodeSortSize
                + libraryCacheSize + profileCacheSize + networkCacheSize + dataCacheSize
        }
    }

    // MARK: - Individual Reset Methods

    func clearImageCache() async {
        await CachedAsyncImage.resetCacheAndWait()
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

    func clearNetworkCache() {
        URLCache.shared.removeAllCachedResponses()
    }

    func clearDataCaches() {
        HomeCacheStore.shared.clearAll()
        for url in dataCacheFiles { try? FileManager.default.removeItem(at: url) }
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

    /// Every cache the app can rebuild. Continue Watching and watch history aren't caches —
    /// they're the viewer's progress — and clearing a cache used to take them too. They have
    /// their own resets, behind a confirmation.
    func clearEverything() async {
        await clearImageCache()
        await clearWebsiteData()
        clearTempFiles()
        clearSearchAliases()
        clearIDMappingCache()
        clearEpisodeSortPreferences()
        clearLibraryCache()
        clearProfileCache()
        clearNetworkCache()
        clearDataCaches()
        cleanupOrphanedDownloads()
    }
    
    // MARK: - Helpers

    private func sizeOfDirectory(at url: URL) throws -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        
        var total = 0
        for case let fileURL as URL in enumerator {
            // One file vanishing mid-walk (a cache being written) used to throw out of the
            // whole walk, and the folder read as empty.
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            if let isDirectory = resourceValues.isDirectory, !isDirectory {
                total += resourceValues.fileSize ?? 0
            }
        }
        return total
    }

    private func cleanupOrphanedDownloads() {
        let docs = AppDirectories.documents
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
