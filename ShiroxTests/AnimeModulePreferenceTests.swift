import XCTest
@testable import Shirox

final class AnimeModulePreferenceTests: XCTestCase {
    // `ModuleDefinition` is Codable with a custom `init(from:)` (ModuleDefinition.swift:41).
    // Required decode keys: sourceName, version, scriptUrl, type. `id` is computed as
    // `scriptUrl`, so set scriptUrl to the id. `isManga` is `type == "mangas" || "manga"`.
    private func mod(_ id: String, manga: Bool) -> ModuleDefinition {
        let type = manga ? "mangas" : "anime"
        let json = #"{"sourceName":"\#(id)","version":"1","scriptUrl":"\#(id)","type":"\#(type)"}"#
        return try! JSONDecoder().decode(ModuleDefinition.self, from: Data(json.utf8))
    }

    func testKeepsActiveWhenActiveIsAnime() {
        let active = mod("a", manga: false)
        let picked = AnimeModulePreference.pick(active: active, modules: [active, mod("m", manga: true)])
        XCTAssertEqual(picked?.id, "a")
    }

    func testSwitchesToFirstAnimeWhenActiveIsManga() {
        let active = mod("m", manga: true)
        let anime = mod("a", manga: false)
        let picked = AnimeModulePreference.pick(active: active, modules: [active, anime])
        XCTAssertEqual(picked?.id, "a")
    }

    func testNilWhenNoAnimeModule() {
        let active = mod("m", manga: true)
        XCTAssertNil(AnimeModulePreference.pick(active: active, modules: [active]))
    }
}
