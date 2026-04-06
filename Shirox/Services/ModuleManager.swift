import Foundation

@MainActor
final class ModuleManager: ObservableObject {
    static let shared = ModuleManager()

    @Published var modules: [ModuleDefinition] = []
    @Published var activeModule: ModuleDefinition?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let storageKey = "savedModules"
    private let activeKey = "activeModuleId"

    private init() {
        loadFromStorage()
    }

    // MARK: - Add Module

    func addModule(from jsonURL: URL) async {
        isLoading = true
        errorMessage = nil
        do {
            let (data, _) = try await URLSession.shared.data(from: jsonURL)
            var module = try JSONDecoder().decode(ModuleDefinition.self, from: data)
            module.jsonUrl = jsonURL.absoluteString

            // Cache script and icon
            await cacheAssets(for: &module)

            // Avoid duplicates
            if modules.contains(where: { $0.id == module.id }) {
                modules.removeAll { $0.id == module.id }
            }
            modules.append(module)
            saveToStorage()

            // Auto-select if it's the first module
            if activeModule == nil {
                try await selectModule(module)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Remove Module

    func removeModule(_ module: ModuleDefinition) {
        modules.removeAll { $0.id == module.id }
        if activeModule?.id == module.id {
            activeModule = nil
        }
        saveToStorage()
    }

    // MARK: - Select Module

    func selectModule(_ module: ModuleDefinition) async throws {
        try await JSEngine.shared.loadModule(module)
        activeModule = module
        UserDefaults.standard.set(module.id, forKey: activeKey)
    }

    // MARK: - Deselect Module (revert to AniList built-in)

    func deselectModule() {
        activeModule = nil
        UserDefaults.standard.removeObject(forKey: activeKey)
    }

    // MARK: - Restore Active Module on Launch

    func restoreActiveModule() async {
        guard let savedId = UserDefaults.standard.string(forKey: activeKey),
              let module = modules.first(where: { $0.id == savedId }) else { return }
        try? await selectModule(module)
    }

    // MARK: - Auto-Update

    func checkForUpdates() async {
        var didUpdate = false
        for i in modules.indices {
            guard let jsonUrlStr = modules[i].jsonUrl,
                  let jsonURL = URL(string: jsonUrlStr),
                  let (data, _) = try? await URLSession.shared.data(from: jsonURL),
                  var fresh = try? JSONDecoder().decode(ModuleDefinition.self, from: data),
                  fresh.version != modules[i].version else { continue }
            fresh.jsonUrl = jsonUrlStr
            
            // Cache fresh assets
            await cacheAssets(for: &fresh)
            
            let wasActive = activeModule?.id == modules[i].id
            modules[i] = fresh
            if wasActive { try? await selectModule(fresh) }
            didUpdate = true
        }
        if didUpdate { saveToStorage() }
    }

    // MARK: - Asset Caching

    private func cacheAssets(for module: inout ModuleDefinition) async {
        // 1. Script
        if let scriptURL = URL(string: module.scriptUrl),
           let (data, _) = try? await URLSession.shared.data(from: scriptURL),
           let script = String(data: data, encoding: .utf8) {
            module.scriptContent = script
        }
        
        // 2. Icon
        if let iconUrlStr = module.iconUrl,
           let iconURL = URL(string: iconUrlStr),
           let (data, _) = try? await URLSession.shared.data(from: iconURL) {
            module.iconData = data.base64EncodedString()
        }
    }

    // MARK: - Persistence

    private func saveToStorage() {
        if let data = try? JSONEncoder().encode(modules) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([ModuleDefinition].self, from: data) else { return }
        modules = saved
    }
}
