import XCTest
@testable import Shirox

@MainActor
final class BackupSettingsSectionTests: XCTestCase {

    private var savedDefaults: [String: Any] = [:]
    private var allKeys: [String] {
        SettingsBackupSection.boolKeys + SettingsBackupSection.intKeys
            + SettingsBackupSection.doubleKeys + SettingsBackupSection.stringKeys
            + ["subtitle.enabled", "subtitle.fontSize", "subtitle.shadowRadius",
               "subtitle.backgroundEnabled", "subtitle.bottomPadding", "subtitle.delay",
               "subtitle.color.r", "subtitle.color.g", "subtitle.color.b", "subtitle.color.a"]
    }

    override func setUp() {
        super.setUp()
        for key in allKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
        }
    }

    override func tearDown() {
        for key in allKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    func testSectionIdIsSettings() {
        XCTAssertEqual(SettingsBackupSection.id, BackupSectionID.settings)
    }

    func testTypedPreferencesRoundTrip() async throws {
        UserDefaults.standard.set(true, forKey: "autoNextEpisode")
        UserDefaults.standard.set(7, forKey: "maxConcurrentDownloads")
        UserDefaults.standard.set(77.5, forKey: "watchedPercentage")
        UserDefaults.standard.set("1080p", forKey: "preferredQuality")

        let section = SettingsBackupSection()
        let payload = try XCTUnwrap(section.export())

        UserDefaults.standard.set(false, forKey: "autoNextEpisode")
        UserDefaults.standard.set(1, forKey: "maxConcurrentDownloads")
        UserDefaults.standard.set(10.0, forKey: "watchedPercentage")
        UserDefaults.standard.set("auto", forKey: "preferredQuality")

        _ = try await section.apply(payload)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: "autoNextEpisode"))
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "maxConcurrentDownloads"), 7)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "watchedPercentage"), 77.5)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "preferredQuality"), "1080p")
    }

    func testDeviceLocalAndOnboardingKeysAreNotBackedUp() {
        let excluded = ["hasCompletedOnboarding", "hasRequestedDownloadNotifications",
                        "lastLandscapeOrientation", "orientation", "drawsBackground"]
        for key in excluded {
            XCTAssertFalse(SettingsBackupSection.boolKeys.contains(key), "\(key) must not be backed up")
            XCTAssertFalse(SettingsBackupSection.intKeys.contains(key), "\(key) must not be backed up")
            XCTAssertFalse(SettingsBackupSection.doubleKeys.contains(key), "\(key) must not be backed up")
            XCTAssertFalse(SettingsBackupSection.stringKeys.contains(key), "\(key) must not be backed up")
        }
    }

    func testLocalLibraryKeysLiveOnlyInTheLocalLibrarySection() {
        for key in ["localScoreFormat", "localAutoTrackEnabled"] {
            XCTAssertFalse(SettingsBackupSection.stringKeys.contains(key))
            XCTAssertFalse(SettingsBackupSection.boolKeys.contains(key))
        }
    }

    func testUnsetKeysAreOmittedAndNotForcedToDefaultsOnRestore() async throws {
        UserDefaults.standard.removeObject(forKey: "preferredQuality")
        let section = SettingsBackupSection()
        let payload = try XCTUnwrap(section.export())
        XCTAssertNil(payload.strings["preferredQuality"])

        UserDefaults.standard.set("1080p", forKey: "preferredQuality")
        _ = try await section.apply(payload)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "preferredQuality"), "1080p")
    }

    func testSubtitleSettingsRestoreIntoPublishedStateNotJustDefaults() async throws {
        let manager = SubtitleSettingsManager.shared
        manager.fontSize = 42
        manager.enabled = false
        manager.delaySeconds = 1.5

        let section = SettingsBackupSection()
        let payload = try XCTUnwrap(section.export())

        manager.fontSize = 12
        manager.enabled = true
        manager.delaySeconds = 0

        _ = try await section.apply(payload)

        // Published state, not just the key — a direct UserDefaults write would leave
        // these stale and the player would keep using 12pt.
        XCTAssertEqual(manager.fontSize, 42)
        XCTAssertFalse(manager.enabled)
        XCTAssertEqual(manager.delaySeconds, 1.5)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "subtitle.fontSize"), 42)
    }

    func testAllowlistsAreDisjoint() {
        let all = SettingsBackupSection.boolKeys + SettingsBackupSection.intKeys
            + SettingsBackupSection.doubleKeys + SettingsBackupSection.stringKeys
        XCTAssertEqual(all.count, Set(all).count, "A key must appear in exactly one type list")
    }
}
