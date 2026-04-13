import Foundation
import WebKit

@MainActor
final class CacheManager: ObservableObject {
    static let shared = CacheManager()
    
    private init() {}
    
    /// Returns total disk usage of the app's cache and data in bytes.
    var totalDiskUsage: Int {
        let urlCache = URLCache.shared.currentDiskUsage
        // We could calculate more here if needed, but urlCache is the main visible one
        return urlCache
    }
    
    /// Clears all temporary, WebKit, and shared network caches.
    func clearAllCache() async {
        print("[Cache] Starting comprehensive cleanup...")
        
        // 1. URLCache (Shared)
        URLCache.shared.removeAllCachedResponses()
        
        // 2. WebKit Data (The likely 300MB source)
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: dataTypes, modifiedSince: .distantPast)
        
        // 3. Temporary Directory
        let tempDir = FileManager.default.temporaryDirectory
        if let contents = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for file in contents {
                try? FileManager.default.removeItem(at: file)
            }
        }
        
        // 4. Cleanup orphaned download folders
        cleanupOrphanedDownloads()
        
        print("[Cache] Cleanup complete.")
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
            
            // If it's a folder (Local HLS), check if its ID is valid
            // If it's a file (MP4), check if its filename is valid
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    if !validIds.contains(name) {
                        print("[Cache] Removing orphaned download folder: \(name)")
                        try? FileManager.default.removeItem(at: file)
                    }
                } else {
                    if !validFileNames.contains(name) {
                        print("[Cache] Removing orphaned download file: \(name)")
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
        }
    }
}
