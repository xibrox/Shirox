import XCTest
@testable import Shirox

/// BackupManager owns the envelope and the apply order and nothing else. These tests
/// drive it with synthetic sections so the orchestration rules — order, per-section
/// isolation, the accounts opt-in — are pinned without touching any real singleton.
@MainActor
final class BackupManagerTests: XCTestCase {

    /// Records which sections applied, in order.
    private final class Recorder {
        var applied: [String] = []
    }

    private func recordingSection(id: String, into recorder: Recorder) -> AnyBackupSection {
        AnyBackupSection(
            id: id,
            export: { .object(["id": .string(id)]) },
            apply: { _ in recorder.applied.append(id); return [] }
        )
    }

    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    private func throwingSection(id: String) -> AnyBackupSection {
        AnyBackupSection(
            id: id,
            export: { .object([:]) },
            apply: { _ in throw Boom() }
        )
    }

    private func warningSection(id: String, warning: String) -> AnyBackupSection {
        AnyBackupSection(
            id: id,
            export: { .object([:]) },
            apply: { _ in [warning] }
        )
    }

    /// A section with a real typed payload, used to prove a payload that doesn't match
    /// the section's type is skipped rather than crashing the restore.
    private struct TypedSection: BackupSection {
        struct Payload: Codable { var count: Int }
        static var id: String { "typed" }
        func export() throws -> Payload? { Payload(count: 1) }
        func apply(_ payload: Payload) async throws -> [String] { [] }
    }

    private func makeManager(_ sections: [AnyBackupSection]) -> BackupManager {
        BackupManager(sections: sections, directory: FileManager.default.temporaryDirectory)
    }

    private func envelopeData(sections: [String: JSONValue],
                              includesAccounts: Bool = false,
                              formatVersion: Int = BackupEnvelope.currentFormatVersion) throws -> Data {
        let envelope = BackupEnvelope(formatVersion: formatVersion,
                                      createdAt: Date(timeIntervalSince1970: 1_757_500_000),
                                      app: .init(version: "1.0.6", build: "112", platform: "iOS"),
                                      includesAccounts: includesAccounts,
                                      sections: sections)
        return try BackupCoding.encoder.encode(envelope)
    }

    // MARK: - Export

    func testExportSkipsAccountsUnlessOptedIn() throws {
        let recorder = Recorder()
        let manager = makeManager([
            recordingSection(id: BackupSectionID.settings, into: recorder),
            recordingSection(id: BackupSectionID.accounts, into: recorder)
        ])

        let without = manager.makeEnvelope(includeAccounts: false, date: Date())
        XCTAssertNil(without.sections[BackupSectionID.accounts])
        XCTAssertFalse(without.includesAccounts)
        XCTAssertNotNil(without.sections[BackupSectionID.settings])

        let with = manager.makeEnvelope(includeAccounts: true, date: Date())
        XCTAssertNotNil(with.sections[BackupSectionID.accounts])
        XCTAssertTrue(with.includesAccounts)
    }

    func testExportWithoutAccountsContainsNoAccountsKeyInRawJSON() throws {
        let recorder = Recorder()
        let manager = makeManager([
            recordingSection(id: BackupSectionID.settings, into: recorder),
            AnyBackupSection(id: BackupSectionID.accounts,
                             export: { .object(["anilistAccessToken": .string("SECRET-TOKEN")]) },
                             apply: { _ in [] })
        ])
        let data = try BackupCoding.encoder.encode(manager.makeEnvelope(includeAccounts: false, date: Date()))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET-TOKEN"))
        XCTAssertFalse(json.contains("accounts"))
    }

    func testExportFileWritesToDirectoryWithDatedName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = Recorder()
        let manager = BackupManager(
            sections: [recordingSection(id: BackupSectionID.settings, into: recorder)],
            directory: dir)

        // 1_757_500_000 is 2025-09-10 UTC; the name is formatted in the device's own
        // timezone, since it stands for the user's "today".
        let url = try manager.exportFile(includeAccounts: false,
                                         date: Date(timeIntervalSince1970: 1_757_500_000))
        XCTAssertEqual(url.lastPathComponent, "Shirox-Backup-2025-09-10.shiroxbackup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNoThrow(try BackupEnvelope.decode(from: Data(contentsOf: url)))
    }

    // MARK: - Import

    func testImportAppliesSectionsInManagerOrderNotFileOrder() async throws {
        let recorder = Recorder()
        let manager = makeManager([
            recordingSection(id: BackupSectionID.settings, into: recorder),
            recordingSection(id: BackupSectionID.modules, into: recorder),
            recordingSection(id: BackupSectionID.localLibrary, into: recorder),
            recordingSection(id: BackupSectionID.progress, into: recorder)
        ])
        // Deliberately reversed in the file; the manager's order must win.
        let data = try envelopeData(sections: [
            BackupSectionID.progress: .object([:]),
            BackupSectionID.localLibrary: .object([:]),
            BackupSectionID.modules: .object([:]),
            BackupSectionID.settings: .object([:])
        ])

        let report = try await manager.importBackup(from: data)

        XCTAssertEqual(recorder.applied, [BackupSectionID.settings,
                                          BackupSectionID.modules,
                                          BackupSectionID.localLibrary,
                                          BackupSectionID.progress])
        XCTAssertEqual(report.applied, recorder.applied)
        XCTAssertTrue(report.skipped.isEmpty)
    }

    func testFailingSectionIsSkippedAndTheRestStillApply() async throws {
        let recorder = Recorder()
        let manager = makeManager([
            throwingSection(id: BackupSectionID.settings),
            recordingSection(id: BackupSectionID.progress, into: recorder)
        ])
        let data = try envelopeData(sections: [
            BackupSectionID.settings: .object([:]),
            BackupSectionID.progress: .object([:])
        ])

        let report = try await manager.importBackup(from: data)

        XCTAssertEqual(recorder.applied, [BackupSectionID.progress])
        XCTAssertEqual(report.applied, [BackupSectionID.progress])
        XCTAssertEqual(report.skipped, [.init(section: BackupSectionID.settings, detail: "boom")])
    }

    func testSectionWithMismatchedPayloadIsSkippedNotFatal() async throws {
        let recorder = Recorder()
        let manager = makeManager([
            TypedSection().erased(),
            recordingSection(id: BackupSectionID.progress, into: recorder)
        ])
        // "typed" expects { count: Int } and gets a string instead.
        let data = try envelopeData(sections: [
            "typed": .object(["count": .string("not a number")]),
            BackupSectionID.progress: .object([:])
        ])

        let report = try await manager.importBackup(from: data)

        XCTAssertEqual(report.applied, [BackupSectionID.progress])
        XCTAssertEqual(report.skipped.map(\.section), ["typed"])
    }

    func testSectionsAbsentFromTheFileAreLeftAlone() async throws {
        let recorder = Recorder()
        let manager = makeManager([
            recordingSection(id: BackupSectionID.settings, into: recorder),
            recordingSection(id: BackupSectionID.progress, into: recorder)
        ])
        let data = try envelopeData(sections: [BackupSectionID.progress: .object([:])])

        let report = try await manager.importBackup(from: data)

        XCTAssertEqual(recorder.applied, [BackupSectionID.progress])
        XCTAssertEqual(report.applied, [BackupSectionID.progress])
        XCTAssertTrue(report.skipped.isEmpty, "A section the file doesn't mention is not a skip")
    }

    func testUnknownSectionInFileIsIgnored() async throws {
        let recorder = Recorder()
        let manager = makeManager([recordingSection(id: BackupSectionID.settings, into: recorder)])
        let data = try envelopeData(sections: [
            BackupSectionID.settings: .object([:]),
            "sectionFromTheFuture": .object(["x": .number(1)])
        ])

        let report = try await manager.importBackup(from: data)

        XCTAssertEqual(report.applied, [BackupSectionID.settings])
        XCTAssertTrue(report.skipped.isEmpty)
    }

    func testWarningsAreReportedWithoutMarkingTheSectionSkipped() async throws {
        let manager = makeManager([warningSection(id: BackupSectionID.modules, warning: "1 module failed")])
        let data = try envelopeData(sections: [BackupSectionID.modules: .object([:])])

        let report = try await manager.importBackup(from: data)

        XCTAssertEqual(report.applied, [BackupSectionID.modules])
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertEqual(report.warnings, [.init(section: BackupSectionID.modules, detail: "1 module failed")])
    }

    // MARK: - Exclusions (real sections)

    /// The spec excludes downloaded media, rebuildable caches and the pending-write queue.
    /// Asserted against a real export rather than left to a manual check: media would make
    /// the file unshareable, and replaying queued AniList/MAL writes from a second device
    /// risks double-writes.
    func testRealExportExcludesDownloadsCachesAndPendingWrites() throws {
        let manager = BackupManager(sections: BackupManager.defaultSections,
                                    directory: FileManager.default.temporaryDirectory)
        let data = try BackupCoding.encoder.encode(manager.makeEnvelope(includeAccounts: true,
                                                                        date: Date()))
        let json = String(decoding: data, as: UTF8.self)

        for needle in ["shirox_downloads_v3", "downloads_manifest",
                       "manga_downloads_manifest", "MangaDownloads", "LocalImports",
                       "id_mappings_cache", "library-cache", "profile-cache",
                       "pending-writes"] {
            XCTAssertFalse(json.contains(needle), "\(needle) must not be in a backup")
        }
    }

    /// Every section the manager ships must be one the summary and the import know by id.
    func testRealSectionIdsAreTheDeclaredOnes() {
        let ids = BackupManager.defaultSections.map(\.id)
        XCTAssertEqual(Set(ids), Set([BackupSectionID.settings, BackupSectionID.modules,
                                      BackupSectionID.localLibrary, BackupSectionID.progress,
                                      BackupSectionID.accounts]))
        XCTAssertEqual(ids.count, Set(ids).count, "A section must be registered once")
    }

    func testImportRefusesANewerFormatVersionBeforeApplyingAnything() async throws {
        let recorder = Recorder()
        let manager = makeManager([recordingSection(id: BackupSectionID.settings, into: recorder)])
        let data = try envelopeData(sections: [BackupSectionID.settings: .object([:])],
                                    formatVersion: BackupEnvelope.currentFormatVersion + 1)

        do {
            _ = try await manager.importBackup(from: data)
            XCTFail("Expected a newerFormat error")
        } catch {
            XCTAssertEqual(error as? BackupValidationError,
                           .newerFormat(fileVersion: BackupEnvelope.currentFormatVersion + 1,
                                        appVersion: BackupEnvelope.currentFormatVersion))
        }
        XCTAssertTrue(recorder.applied.isEmpty, "Nothing may apply from a refused file")
    }
}
