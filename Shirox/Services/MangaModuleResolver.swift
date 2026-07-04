import Foundation

/// Resolves a provider-synced manga (title only, no module href) to a module
/// `SearchItem` so it can open in the reader. Mirrors the Continue Reading reopen
/// pattern: switch to a manga module, search it by title, pick the best hit.
@MainActor final class MangaModuleResolver {
    static let shared = MangaModuleResolver()
    private init() {}

    /// Pure: exact case-insensitive title hit, else the top result, else nil.
    nonisolated static func pickTitleMatch(title: String, results: [SearchItem]) -> SearchItem? {
        guard !results.isEmpty else { return nil }
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return results.first { $0.title.lowercased() == needle } ?? results[0]
    }

    /// Returns a module `SearchItem` for `title`, or nil when no manga module is
    /// installed / no result is found (caller should toast). Switches the active
    /// module as a side effect (same as Continue Reading).
    func resolve(title: String) async -> SearchItem? {
        let manager = ModuleManager.shared
        let module: ModuleDefinition?
        if manager.activeModule?.isManga == true {
            module = manager.activeModule
        } else {
            module = manager.modules.first { $0.isManga }
        }
        guard let module else { return nil }
        if manager.activeModule?.id != module.id {
            guard await manager.selectAndAwaitReady(module) else { return nil }
        }
        let results = (try? await JSEngine.shared.mangaSearch(keyword: title)) ?? []
        return Self.pickTitleMatch(title: title, results: results)
    }
}
