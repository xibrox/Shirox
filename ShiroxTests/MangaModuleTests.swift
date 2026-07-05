import XCTest
@testable import Shirox

final class MangaModuleTests: XCTestCase {

    // MARK: - Manifest decoding

    func testDecodesLunaMangaManifest() throws {
        let json = """
        {
          "sourceName": "MangaKatana",
          "iconURL": "https://mangakatana.com/static/img/fav.png",
          "version": "1.0",
          "language": "English",
          "scriptURL": "https://example.com/mangakatana.js",
          "author": { "name": "50/50", "iconURL": "https://example.com/a.png" },
          "type": "mangas"
        }
        """.data(using: .utf8)!
        let module = try JSONDecoder().decode(ModuleDefinition.self, from: json)
        XCTAssertEqual(module.sourceName, "MangaKatana")
        XCTAssertEqual(module.scriptUrl, "https://example.com/mangakatana.js")
        XCTAssertEqual(module.iconUrl, "https://mangakatana.com/static/img/fav.png")
        XCTAssertNil(module.baseUrl)
        XCTAssertEqual(module.author?.name, "50/50")
        XCTAssertEqual(module.author?.icon, "https://example.com/a.png")
        XCTAssertTrue(module.isManga)
        XCTAssertEqual(module.id, "https://example.com/mangakatana.js")
    }

    func testDecodesSoraAnimeManifestUnchanged() throws {
        let json = """
        {
          "sourceName": "AnimeSource",
          "iconUrl": "https://example.com/icon.png",
          "author": { "name": "dev", "icon": "https://example.com/dev.png" },
          "version": "2.1",
          "baseUrl": "https://anime.example.com",
          "scriptUrl": "https://example.com/anime.js",
          "type": "anime",
          "language": "English",
          "asyncJS": true,
          "streamType": "HLS",
          "quality": "1080p"
        }
        """.data(using: .utf8)!
        let module = try JSONDecoder().decode(ModuleDefinition.self, from: json)
        XCTAssertEqual(module.baseUrl, "https://anime.example.com")
        XCTAssertEqual(module.scriptUrl, "https://example.com/anime.js")
        XCTAssertEqual(module.iconUrl, "https://example.com/icon.png")
        XCTAssertEqual(module.author?.icon, "https://example.com/dev.png")
        XCTAssertFalse(module.isManga)
        XCTAssertEqual(module.asyncJS, true)
    }

    func testManifestRoundTripsThroughPersistenceEncoding() throws {
        // ModuleManager persists modules with JSONEncoder; a decoded Luna
        // manifest must survive encode -> decode with cached fields intact.
        let json = """
        {"sourceName":"MangaPark","version":"1.0","scriptURL":"https://example.com/mp.js","type":"mangas"}
        """.data(using: .utf8)!
        var module = try JSONDecoder().decode(ModuleDefinition.self, from: json)
        module.jsonUrl = "https://example.com/mp.json"
        module.scriptContent = "function searchResults() {}"
        let data = try JSONEncoder().encode(module)
        let restored = try JSONDecoder().decode(ModuleDefinition.self, from: data)
        XCTAssertEqual(restored, module)
        XCTAssertEqual(restored.scriptContent, "function searchResults() {}")
        XCTAssertTrue(restored.isManga)
    }

    func testMangaTypeSingularAlsoCounts() throws {
        let json = """
        {"sourceName":"X","version":"1.0","scriptURL":"https://example.com/x.js","type":"manga"}
        """.data(using: .utf8)!
        let module = try JSONDecoder().decode(ModuleDefinition.self, from: json)
        XCTAssertTrue(module.isManga)
    }

    // MARK: - Search result parsing

    func testParsesLunaSearchItems() {
        let raw: [[String: Any]] = [
            ["id": "https://mangakatana.com/manga/kagurabachi", "imageURL": "https://cdn.example.com/kb.jpg", "title": "Kagurabachi"],
            ["id": "https://mangakatana.com/manga/x", "title": "No Image"],           // imageURL missing -> empty image
            ["imageURL": "https://cdn.example.com/y.jpg", "title": "No Href"],        // id missing -> dropped
            ["id": "https://mangakatana.com/manga/z", "imageURL": "https://cdn.example.com/z.jpg"], // title missing -> dropped
        ]
        let items = JSEngine.parseMangaSearchItems(raw)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "Kagurabachi")
        XCTAssertEqual(items[0].href, "https://mangakatana.com/manga/kagurabachi")
        XCTAssertEqual(items[0].image, "https://cdn.example.com/kb.jpg")
        XCTAssertEqual(items[1].image, "")
    }

    // MARK: - Details parsing

    func testParsesMangaDetails() {
        let parsed = JSEngine.parseMangaDetails(["description": "A story.", "tags": ["Action", "Fantasy"]])
        XCTAssertEqual(parsed.description, "A story.")
        XCTAssertEqual(parsed.tags, ["Action", "Fantasy"])

        let empty = JSEngine.parseMangaDetails([:])
        XCTAssertEqual(empty.description, "")
        XCTAssertEqual(empty.tags, [])
    }

    func testDecodesHTMLEntitiesInDescriptions() {
        XCTAssertEqual(
            MangaDetailViewModel.decodeHTMLEntities("doesn&#039;t change &quot;his&quot; life &amp; more&#8230;"),
            "doesn't change \"his\" life & more…"
        )
        // &amp; decodes last, so a double-encoded entity resolves in one pass
        XCTAssertEqual(MangaDetailViewModel.decodeHTMLEntities("&amp;#039;"), "&#039;")
        XCTAssertEqual(MangaDetailViewModel.decodeHTMLEntities("plain text"), "plain text")
    }

    // MARK: - Chapter parsing (shapes from all 4 Luna modules)

    func testParsesMangaKatanaShapeChapters() {
        // label = 0-based index, real name in `title`, empty scanlation_group
        let object: [String: Any] = ["en": [
            ["0", [["id": "https://mangakatana.com/manga/kb/c1", "title": "Chapter 1: Sword", "chapter": 0, "scanlation_group": ""]]],
            ["1", [["id": "https://mangakatana.com/manga/kb/c2", "title": "Chapter 2: Fire", "chapter": 1, "scanlation_group": ""]]],
        ]]
        let chapters = JSEngine.parseMangaChapters(object)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].href, "https://mangakatana.com/manga/kb/c1")
        XCTAssertEqual(chapters[0].number, 0)
        XCTAssertEqual(chapters[0].displayName, "Chapter 1: Sword")   // title wins
        XCTAssertNil(chapters[0].group)                               // empty string -> nil
        XCTAssertEqual(chapters[0].language, "en")
    }

    func testParsesMangaFreakShapeChapters() {
        // no `title`; the chapter name is (ab)used as scanlation_group
        let object: [String: Any] = ["en": [
            ["1", [["id": "https://ww2.mangafreak.me/Read1_Kaiju_1", "chapter": 1, "scanlation_group": "Kaiju No.8 Chapter 1"]]],
        ]]
        let chapters = JSEngine.parseMangaChapters(object)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].displayName, "Kaiju No.8 Chapter 1") // group fallback
        XCTAssertEqual(chapters[0].number, 1)
    }

    func testParsesDecimalChapterNumbers() {
        // mangabuddy/mangapark use decimal chapter numbers
        let object: [String: Any] = ["en": [
            ["12.5", [["id": "https://mangapark.net/title/x/12-5", "title": "Ch.12.5", "chapter": 12.5, "scanlation_group": "Ch.12.5"]]],
        ]]
        let chapters = JSEngine.parseMangaChapters(object)
        XCTAssertEqual(chapters[0].number, 12.5)
        XCTAssertEqual(chapters[0].label, "12.5")
    }

    func testChapterLanguageFallbackWhenNoEnglish() {
        let object: [String: Any] = ["fr": [
            ["1", [["id": "https://example.com/fr/1", "chapter": 1, "scanlation_group": "Chapitre 1"]]],
        ]]
        let chapters = JSEngine.parseMangaChapters(object)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].language, "fr")
    }

    func testChapterParsingSkipsMalformedEntries() {
        let object: [String: Any] = ["en": [
            ["5"],                                                     // missing versions array
            ["6", [[String: Any]()]],                                  // version missing id
            ["7", [["id": "", "chapter": 7]]],                         // empty id
            ["8", [["id": "https://example.com/8", "chapter": 8, "scanlation_group": "ok"]]],
        ]]
        let chapters = JSEngine.parseMangaChapters(object)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].href, "https://example.com/8")
    }

    func testChapterParsingRejectsNonDictionary() {
        XCTAssertTrue(JSEngine.parseMangaChapters(["not", "a", "dict"]).isEmpty)
        XCTAssertTrue(JSEngine.parseMangaChapters(["en": "not an array"]).isEmpty)
    }

    func testChapterNumberFallsBackToLabel() {
        // no usable `chapter` field -> parse the label
        let object: [String: Any] = ["en": [
            ["3", [["id": "https://example.com/3", "scanlation_group": "Chapter 3"]]],
        ]]
        XCTAssertEqual(JSEngine.parseMangaChapters(object)[0].number, 3)
    }

    func testDescendingModuleIsNormalizedToAscending() {
        // Some modules list chapters newest -> oldest (e.g. 650 … 2, 1). The
        // reader assumes index 0 is the oldest chapter, so parsing must flip
        // descending input to ascending order.
        let object: [String: Any] = ["en": [
            ["3", [["id": "https://example.com/3", "chapter": 3, "scanlation_group": "Chapter 3"]]],
            ["2", [["id": "https://example.com/2", "chapter": 2, "scanlation_group": "Chapter 2"]]],
            ["1", [["id": "https://example.com/1", "chapter": 1, "scanlation_group": "Chapter 1"]]],
        ]]
        let chapters = JSEngine.parseMangaChapters(object)
        XCTAssertEqual(chapters.map(\.number), [1, 2, 3])
        XCTAssertEqual(chapters.first?.href, "https://example.com/1")
        XCTAssertEqual(chapters.last?.href, "https://example.com/3")
    }

    func testEqualNumberChaptersKeepModuleOrder() {
        // Unnumbered specials all resolve to 0; a stable sort must keep the
        // module's own order for ties rather than shuffling them.
        let object: [String: Any] = ["en": [
            ["Oneshot", [["id": "https://example.com/a", "scanlation_group": "Oneshot A"]]],
            ["Extra", [["id": "https://example.com/b", "scanlation_group": "Extra B"]]],
        ]]
        let chapters = JSEngine.parseMangaChapters(object)
        XCTAssertEqual(chapters.map(\.href), ["https://example.com/a", "https://example.com/b"])
    }

    func testUnnumberedSpecialsSortAfterNumberedChapters() {
        // A descending module often lists the newest special first. Because its
        // number can't be parsed it must land at the END of the ascending list
        // (newest release last) — never before chapter 1.
        let object: [String: Any] = ["en": [
            ["Oneshot", [["id": "https://example.com/special", "scanlation_group": "Bonus Oneshot"]]],
            ["3", [["id": "https://example.com/3", "chapter": 3]]],
            ["2", [["id": "https://example.com/2", "chapter": 2]]],
            ["1", [["id": "https://example.com/1", "chapter": 1]]],
        ]]
        let chapters = JSEngine.parseMangaChapters(object)
        XCTAssertEqual(chapters.map(\.href), [
            "https://example.com/1", "https://example.com/2",
            "https://example.com/3", "https://example.com/special",
        ])
    }

    func testParsedZeroChapterStaysBeforeChapterOne() {
        // MangaKatana is 0-based: chapter 0 is a REAL first chapter and must
        // sort ahead of chapter 1 — it must not be lumped with the unnumbered
        // specials that get pushed to the end.
        let object: [String: Any] = ["en": [
            ["1", [["id": "https://example.com/c2", "chapter": 1]]],
            ["0", [["id": "https://example.com/c1", "chapter": 0]]],
        ]]
        let chapters = JSEngine.parseMangaChapters(object)
        XCTAssertEqual(chapters.map(\.href), ["https://example.com/c1", "https://example.com/c2"])
    }
}
