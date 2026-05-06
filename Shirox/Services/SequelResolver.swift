import Foundation

struct SequelResolver {
    static func searchResults(
        title: String,
        module: ModuleDefinition,
        runner: ModuleJSRunner
    ) async throws -> [SearchItem] {
        try await runner.search(keyword: title)
    }
}
