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

    // MARK: - Last picked search result href

    private func searchResultKey(mediaId: Int?, animeTitle: String, moduleId: String) -> String {
        "moduleLastSearchResult_" + key(mediaId: mediaId, animeTitle: animeTitle, moduleId: moduleId)
    }

    func getLastSearchResultHref(mediaId: Int?, animeTitle: String, moduleId: String) -> String? {
        userDefaults.string(forKey: searchResultKey(mediaId: mediaId, animeTitle: animeTitle, moduleId: moduleId))
    }

    func setLastSearchResultHref(mediaId: Int?, animeTitle: String, moduleId: String, href: String) {
        let key = searchResultKey(mediaId: mediaId, animeTitle: animeTitle, moduleId: moduleId)
        if href.isEmpty {
            userDefaults.removeObject(forKey: key)
        } else {
            userDefaults.set(href, forKey: key)
        }
    }

    // MARK: - Last picked stream title per module

    private func streamTitleKey(moduleId: String) -> String {
        let moduleKey = moduleId.data(using: .utf8)?.base64EncodedString() ?? moduleId
        return "moduleLastStreamTitle_\(moduleKey)"
    }

    func getLastStreamTitle(moduleId: String) -> String? {
        userDefaults.string(forKey: streamTitleKey(moduleId: moduleId))
    }

    func setLastStreamTitle(moduleId: String, title: String) {
        userDefaults.set(title, forKey: streamTitleKey(moduleId: moduleId))
    }
}
