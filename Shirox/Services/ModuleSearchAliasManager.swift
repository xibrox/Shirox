import Foundation

final class ModuleSearchAliasManager: ObservableObject {
    static let shared = ModuleSearchAliasManager()
    
    private let userDefaults = UserDefaults.standard
    private let keyPrefix = "moduleSearchAlias_"
    
    private init() {}
    
    private func key(mediaId: Int?, animeTitle: String, moduleId: String) -> String {
        // Use a stable base64 encoding for the URL so it's a valid key
        let moduleKey = moduleId.data(using: .utf8)?.base64EncodedString() ?? moduleId
        
        if let mediaId = mediaId {
            return "\(keyPrefix)\(mediaId)_\(moduleKey)"
        } else {
            // Use a stable, sanitized version of the title
            let safeTitle = animeTitle.lowercased()
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " ", with: "_")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" }
            
            return "\(keyPrefix)title_\(safeTitle)_\(moduleKey)"
        }
    }
    
    func getAlias(mediaId: Int?, animeTitle: String, moduleId: String) -> String? {
        let k = key(mediaId: mediaId, animeTitle: animeTitle, moduleId: moduleId)
        return userDefaults.string(forKey: k)
    }
    
    func setAlias(mediaId: Int?, animeTitle: String, moduleId: String, alias: String) {
        let k = key(mediaId: mediaId, animeTitle: animeTitle, moduleId: moduleId)
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            userDefaults.removeObject(forKey: k)
        } else {
            userDefaults.set(trimmed, forKey: k)
        }
        objectWillChange.send()
    }
}
