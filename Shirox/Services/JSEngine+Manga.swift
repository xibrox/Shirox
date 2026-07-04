import Foundation

// MARK: - Manga bridge (Luna-style modules)
//
// Luna manga modules expose searchResults / extractDetails / extractChapters /
// extractImages and return RAW JS values — unlike Sora modules, which return
// JSON strings. callAsyncJS stringifies results with toString(), which garbles
// objects, so every manga call routes through __shiroxCallJSON, which
// JSON.stringifies on the JS side first.

extension JSEngine {

    static let mangaBridgeJS = """
    function __shiroxCallJSON(fnName, args) {
        return Promise.resolve(globalThis[fnName].apply(null, args)).then(function(r) {
            return JSON.stringify(r);
        });
    }
    """

    /// Injects the JSON-stringifying call helper. Called from setupContext()
    /// so every fresh module context has it.
    func setupMangaBridge() {
        context.evaluateScript(Self.mangaBridgeJS)
    }

    // MARK: - Calls

    func mangaSearch(keyword: String) async throws -> [SearchItem] {
        let json = try await callAsyncJS("__shiroxCallJSON", args: ["searchResults", [keyword]])
        guard let data = json.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JSEngineError.parseError("Could not parse manga search results")
        }
        return Self.parseMangaSearchItems(array)
    }

    func mangaDetails(url: String) async throws -> (description: String, tags: [String]) {
        let json = try await callAsyncJS("__shiroxCallJSON", args: ["extractDetails", [url]])
        guard let data = json.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSEngineError.parseError("Could not parse manga details")
        }
        return Self.parseMangaDetails(dict)
    }

    func mangaChapters(url: String) async throws -> [MangaChapter] {
        let json = try await callAsyncJS("__shiroxCallJSON", args: ["extractChapters", [url]])
        guard let data = json.data(using: .utf8) else {
            throw JSEngineError.parseError("Could not parse manga chapters")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return Self.parseMangaChapters(object)
    }

    func mangaImages(url: String) async throws -> [String] {
        let json = try await callAsyncJS("__shiroxCallJSON", args: ["extractImages", [url]])
        guard let data = json.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [String] else {
            throw JSEngineError.parseError("Could not parse manga pages")
        }
        return array.filter { !$0.isEmpty }
    }

    // MARK: - Pure parsers (nonisolated so tests can call them directly)

    nonisolated static func parseMangaSearchItems(_ array: [[String: Any]]) -> [SearchItem] {
        array.compactMap { item in
            guard let title = item["title"] as? String,
                  let href = (item["id"] as? String) ?? (item["href"] as? String),
                  !href.isEmpty else { return nil }
            let image = (item["imageURL"] as? String) ?? (item["image"] as? String) ?? ""
            return SearchItem(title: title, image: image, href: href)
        }
    }

    nonisolated static func parseMangaDetails(_ dict: [String: Any]) -> (description: String, tags: [String]) {
        ((dict["description"] as? String) ?? "", (dict["tags"] as? [String]) ?? [])
    }

    /// `{ "<lang>": [ [label, [{id, title?, chapter, scanlation_group}, …]], … ] }`
    /// Prefers "en", falls back to the first language key (sorted, for
    /// determinism). Takes the first version of each chapter. Preserves module
    /// order (Luna convention: oldest → newest).
    nonisolated static func parseMangaChapters(_ object: Any) -> [MangaChapter] {
        guard let dict = object as? [String: Any] else { return [] }
        let langKey = dict["en"] != nil ? "en" : dict.keys.sorted().first
        guard let langKey, let entries = dict[langKey] as? [[Any]] else { return [] }
        var chapters: [MangaChapter] = []
        for entry in entries {
            guard entry.count >= 2,
                  let versions = entry[1] as? [[String: Any]],
                  let first = versions.first,
                  let href = first["id"] as? String, !href.isEmpty else { continue }
            let label = (entry[0] as? String) ?? String(describing: entry[0])
            let number: Double
            if let d = first["chapter"] as? Double {
                number = d
            } else if let i = first["chapter"] as? Int {
                number = Double(i)
            } else {
                number = Double(label) ?? 0
            }
            let title = (first["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let group = (first["scanlation_group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            chapters.append(MangaChapter(
                href: href, number: number, label: label,
                title: title, group: group, language: langKey))
        }
        return chapters
    }
}
