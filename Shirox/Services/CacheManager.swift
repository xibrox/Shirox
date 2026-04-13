import Foundation
import WebKit

@MainActor
final class CacheManager: ObservableObject {
    static let shared = CacheManager()
    
    private init() {}
    
    // MARK: - Size Calculations
    
    var imageCacheSize: Int { URLCache.shared.currentDiskUsage }
    
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
    
    var totalDiskUsage: Int {
        imageCacheSize + websiteDataSize + tempFilesSize + continueWatchingSize + watchHistorySize
    }

    // MARK: - Individual Reset Methods

    func clearImageCache() {
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: NSNotification.Name("ClearImageCache"), object: nil)
    }

    func clearWebsiteData() async {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: dataTypes, modifiedSince: .distantPast)
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

    func clearEverything() async {
        clearImageCache()
        await clearWebsiteData()
        clearTempFiles()
        clearContinueWatching()
        clearWatchHistory()
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
        
        guard let contents = try? FileManager.default.contentsOfDirectory(at: downloadDir, includingPropertiesForKeys: nil),
              let savedData = UserDefaults.standard.data(forKey: "shirox_downloads_v3"),
              let items = try? JSONDecoder().decode([DownloadItem].self, from: savedData) else {
            return
        }
        
        let validFileNames = Set(items.compactMap { $0.fileName })
        let validIds = Set(items.map { $0.id.uuidString })
        
        for file in contents {
            let name = file.lastPathComponent
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if !validIds.contains(name) {
                        try? FileManager.default.removeItem(at: file)
                    }
                } else {
                    if !validFileNames.contains(name) {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
        }
    }
}
