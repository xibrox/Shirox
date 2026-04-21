import SwiftUI

final class EpisodeSortManager: ObservableObject {
    static let shared = EpisodeSortManager()
    
    @AppStorage("defaultReverseSort") var defaultReverseSort = false
    
    private let preferencesKey = "individualSortPreferences"
    
    private init() {}
    
    func isReversed(for id: String) -> Bool {
        let prefs = UserDefaults.standard.dictionary(forKey: preferencesKey) as? [String: Bool] ?? [:]
        return prefs[id] ?? defaultReverseSort
    }
    
    func setReversed(_ reversed: Bool, for id: String) {
        var prefs = UserDefaults.standard.dictionary(forKey: preferencesKey) as? [String: Bool] ?? [:]
        prefs[id] = reversed
        UserDefaults.standard.set(prefs, forKey: preferencesKey)
    }
    
    func clearAllIndividualPreferences() {
        UserDefaults.standard.removeObject(forKey: preferencesKey)
    }
}
