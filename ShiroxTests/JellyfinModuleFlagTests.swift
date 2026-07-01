import XCTest
@testable import Shirox

final class JellyfinModuleFlagTests: XCTestCase {
    private func decode(_ json: String) throws -> ModuleDefinition {
        try JSONDecoder().decode(ModuleDefinition.self, from: Data(json.utf8))
    }

    func testSupportsJellyfinTrueMakesIsJellyfinTrue() throws {
        let json = """
        {"sourceName":"Jellyfin","iconUrl":null,"author":null,"version":"1.0",
         "baseUrl":"","searchBaseUrl":null,"scriptUrl":"https://example.com/jellyfin.js",
         "type":"jellyfin","asyncJS":null,"streamType":null,"quality":null,"language":null,
         "softsub":null,"supportsLocalPlayback":null,"supportsJellyfin":true}
        """
        XCTAssertTrue(try decode(json).isJellyfin)
    }

    func testMissingFlagIsNotJellyfin() throws {
        let json = """
        {"sourceName":"Other","iconUrl":null,"author":null,"version":"1.0",
         "baseUrl":"","searchBaseUrl":null,"scriptUrl":"https://example.com/x.js",
         "type":"stream","asyncJS":null,"streamType":null,"quality":null,"language":null,
         "softsub":null,"supportsLocalPlayback":null}
        """
        XCTAssertFalse(try decode(json).isJellyfin)
    }
}
