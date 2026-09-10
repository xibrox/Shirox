import XCTest
@testable import Shirox

/// These cover the export shape and the failure reporting. Restoring modules re-fetches
/// each manifest over the network, so the happy path is not unit-tested here — it is
/// exercised by the manual verification in Task 8.
@MainActor
final class BackupModulesSectionTests: XCTestCase {

    private var savedActive: Any?
    private var savedLastUsed: Any?

    override func setUp() {
        super.setUp()
        savedActive = UserDefaults.standard.object(forKey: "activeModuleId")
        savedLastUsed = UserDefaults.standard.object(forKey: "lastUsedModuleId")
    }

    override func tearDown() {
        if let savedActive { UserDefaults.standard.set(savedActive, forKey: "activeModuleId") }
        else { UserDefaults.standard.removeObject(forKey: "activeModuleId") }
        if let savedLastUsed { UserDefaults.standard.set(savedLastUsed, forKey: "lastUsedModuleId") }
        else { UserDefaults.standard.removeObject(forKey: "lastUsedModuleId") }
        super.tearDown()
    }

    func testSectionIdIsModules() {
        XCTAssertEqual(ModulesBackupSection.id, BackupSectionID.modules)
    }

    func testExportRecordsActiveAndLastUsedIds() throws {
        UserDefaults.standard.set("https://example.com/x.js", forKey: "activeModuleId")
        UserDefaults.standard.set("https://example.com/y.js", forKey: "lastUsedModuleId")

        let payload = try XCTUnwrap(ModulesBackupSection().export())

        XCTAssertEqual(payload.activeModuleId, "https://example.com/x.js")
        XCTAssertEqual(payload.lastUsedModuleId, "https://example.com/y.js")
    }

    func testExportOnlyIncludesModulesThatCanBeReinstalled() throws {
        let payload = try XCTUnwrap(ModulesBackupSection().export())
        // Every exported entry must carry a usable manifest URL, or a restore could not
        // reinstall it.
        for entry in payload.modules {
            XCTAssertFalse(entry.jsonUrl.isEmpty)
            XCTAssertNotNil(URL(string: entry.jsonUrl))
        }
        XCTAssertEqual(payload.modules.count,
                       ModuleManager.shared.modules.filter { ($0.jsonUrl ?? "").isEmpty == false }.count)
    }

    func testUnreachableModulesAreReportedAsWarningsNotFailures() async throws {
        let payload = ModulesBackupPayload(
            modules: [.init(jsonUrl: "://not-a-url",
                            sourceName: "Broken",
                            scriptUrl: "https://example.invalid/broken.js")],
            activeModuleId: nil,
            lastUsedModuleId: nil)

        let warnings = try await ModulesBackupSection().apply(payload)

        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Broken"), "The warning should name the module")
    }

    func testEmptyModuleListAppliesWithoutWarnings() async throws {
        let payload = ModulesBackupPayload(modules: [], activeModuleId: nil, lastUsedModuleId: nil)
        let warnings = try await ModulesBackupSection().apply(payload)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(ModuleManager.shared.modules.isEmpty, "Restore replaces the module list")
    }

    func testLastUsedModuleIdIsRestored() async throws {
        UserDefaults.standard.removeObject(forKey: "lastUsedModuleId")
        let payload = ModulesBackupPayload(modules: [],
                                           activeModuleId: nil,
                                           lastUsedModuleId: "https://example.com/z.js")

        _ = try await ModulesBackupSection().apply(payload)

        XCTAssertEqual(UserDefaults.standard.string(forKey: "lastUsedModuleId"),
                       "https://example.com/z.js")
    }
}
