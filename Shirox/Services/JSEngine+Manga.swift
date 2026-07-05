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
    /// determinism). Takes the first version of each chapter, then normalizes to
    /// ascending order (oldest → newest) so index 0 is always chapter 1 —
    /// modules that list newest → oldest (e.g. 650 … 1) get flipped, which the
    /// reader relies on for correct next/prev navigation and stitching.
    nonisolated static func parseMangaChapters(_ object: Any) -> [MangaChapter] {
        guard let dict = object as? [String: Any] else { return [] }
        let langKey = dict["en"] != nil ? "en" : dict.keys.sorted().first
        guard let langKey, let entries = dict[langKey] as? [[Any]] else { return [] }
        // `hasNumber` distinguishes a genuinely parsed chapter number (incl. a
        // real 0, e.g. MangaKatana's 0-based first chapter) from the fallback
        // used for unnumbered specials — the two must sort differently.
        var chapters: [(chapter: MangaChapter, hasNumber: Bool)] = []
        for entry in entries {
            guard entry.count >= 2,
                  let versions = entry[1] as? [[String: Any]],
                  let first = versions.first,
                  let href = first["id"] as? String, !href.isEmpty else { continue }
            let label = (entry[0] as? String) ?? String(describing: entry[0])
            let number: Double
            let hasNumber: Bool
            if let d = first["chapter"] as? Double {
                number = d; hasNumber = true
            } else if let i = first["chapter"] as? Int {
                number = Double(i); hasNumber = true
            } else if let parsed = Double(label) {
                number = parsed; hasNumber = true
            } else {
                number = 0; hasNumber = false
            }
            let title = (first["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let group = (first["scanlation_group"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            chapters.append((MangaChapter(
                href: href, number: number, label: label,
                title: title, group: group, language: langKey), hasNumber))
        }
        // Normalize to ascending chapter number so index 0 is always chapter 1.
        // Numbered chapters come first (ascending); unnumbered specials keep the
        // module's own order and land at the END — in a descending module the
        // newest release is often an unnumbered special listed first, and the
        // user wants it last, never before chapter 1. Stable on the original
        // index so equal keys never shuffle.
        return chapters
            .enumerated()
            .sorted { lhs, rhs in
                let (l, r) = (lhs.element, rhs.element)
                if l.hasNumber != r.hasNumber { return l.hasNumber }
                if l.hasNumber, l.chapter.number != r.chapter.number {
                    return l.chapter.number < r.chapter.number
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element.chapter }
    }
}
