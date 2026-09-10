import XCTest
@testable import Shirox

@MainActor
final class BackupLocalLibrarySectionTests: XCTestCase {

    private let touchedKeys = ["libraryCustomListNames", "individualSortPreferences",
                               "localScoreFormat", "localAutoTrackEnabled"]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in touchedKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
        }
    }

    override func tearDown() {
        for key in touchedKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    func testSectionIdIsLocalLibrary() {
        XCTAssertEqual(LocalLibraryBackupSection.id, BackupSectionID.localLibrary)
    }

    func testCompanionKeysRoundTrip() async throws {
        UserDefaults.standard.set(["Favourites", "Rewatching"], forKey: "libraryCustomListNames")
        UserDefaults.standard.set(["show-1": true], forKey: "individualSortPreferences")
        UserDefaults.standard.set("POINT_100", forKey: "localScoreFormat")
        UserDefaults.standard.set(false, forKey: "localAutoTrackEnabled")

        let section = LocalLibraryBackupSection()
        let payload = try XCTUnwrap(section.export())

        UserDefaults.standard.removeObject(forKey: "libraryCustomListNames")
        UserDefaults.standard.removeObject(forKey: "individualSortPreferences")
        UserDefaults.standard.set("POINT_10", forKey: "localScoreFormat")
        UserDefaults.standard.set(true, forKey: "localAutoTrackEnabled")

        _ = try await section.apply(payload)

        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "libraryCustomListNames"),
                       ["Favourites", "Rewatching"])
        XCTAssertEqual(UserDefaults.standard.dictionary(forKey: "individualSortPreferences") as? [String: Bool],
                       ["show-1": true])
        XCTAssertEqual(UserDefaults.standard.string(forKey: "localScoreFormat"), "POINT_100")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "localAutoTrackEnabled"))
    }

    func testCollectionsRoundTripIntoPublishedState() async throws {
        let manager = LocalLibraryManager.shared
        let originalEntries = manager.entries
        let originalCollections = manager.collections
        addTeardownBlock { @MainActor in
            manager.restore(entries: originalEntries, collections: originalCollections)
        }

        let seeded = [LocalCollection(name: "Comfort Shows", mediaUniqueIds: ["anilist-1", "anilist-2"]),
                      LocalCollection(name: "To Rewatch", mediaUniqueIds: [])]
        manager.restore(entries: originalEntries, collections: seeded)

        let section = LocalLibraryBackupSection()
        let payload = try XCTUnwrap(section.export())

        manager.restore(entries: [], collections: [])
        XCTAssertTrue(manager.collections.isEmpty)

        _ = try await section.apply(payload)

        XCTAssertEqual(manager.collections.map(\.name), ["Comfort Shows", "To Rewatch"])
        XCTAssertEqual(manager.collections.first?.mediaUniqueIds, ["anilist-1", "anilist-2"])
        XCTAssertEqual(manager.entries.count, originalEntries.count)
    }

    func testApplyWritesTheLibraryFileNotJustMemory() async throws {
        let manager = LocalLibraryManager.shared
        let originalEntries = manager.entries
        let originalCollections = manager.collections
        addTeardownBlock { @MainActor in
            manager.restore(entries: originalEntries, collections: originalCollections)
        }

        manager.restore(entries: originalEntries,
                        collections: [LocalCollection(name: "Persisted", mediaUniqueIds: [])])
        let payload = try XCTUnwrap(LocalLibraryBackupSection().export())
        manager.restore(entries: [], collections: [])

        _ = try await LocalLibraryBackupSection().apply(payload)

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let data = try Data(contentsOf: dir.appendingPathComponent("local_library.json"))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("Persisted"), "The restore must reach the JSON file on disk")
    }

    func testAbsentCompanionKeysStayAbsentAfterRestore() async throws {
        for key in touchedKeys { UserDefaults.standard.removeObject(forKey: key) }

        let section = LocalLibraryBackupSection()
        let payload = try XCTUnwrap(section.export())
        XCTAssertNil(payload.localScoreFormat)
        XCTAssertNil(payload.localAutoTrackEnabled)

        UserDefaults.standard.set("POINT_100", forKey: "localScoreFormat")
        _ = try await section.apply(payload)

        // A key the backup never recorded must not be forced to a default.
        XCTAssertEqual(UserDefaults.standard.string(forKey: "localScoreFormat"), "POINT_100")
    }
}
