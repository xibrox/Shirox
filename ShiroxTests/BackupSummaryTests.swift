import XCTest
@testable import Shirox

/// The import confirmation has to name what it is about to replace, so the counts come
/// from the file rather than from the device.
@MainActor
final class BackupSummaryTests: XCTestCase {

    private func manager() -> BackupManager {
        BackupManager(sections: BackupManager.defaultSections,
                      directory: FileManager.default.temporaryDirectory)
    }

    private func envelopeData(sections: [String: JSONValue],
                              includesAccounts: Bool = false) throws -> Data {
        try BackupCoding.encoder.encode(
            BackupEnvelope(formatVersion: BackupEnvelope.currentFormatVersion,
                           createdAt: Date(timeIntervalSince1970: 1_757_500_000),
                           app: .init(version: "1.0.6", build: "112", platform: "iOS"),
                           includesAccounts: includesAccounts,
                           sections: sections))
    }

    func testSummaryReportsCountsFromTheFile() throws {
        let progress = ProgressBackupPayload(
            dataVersion: ContinueWatchingManager.currentDataVersion,
            continueWatching: [],
            watchedKeys: ["a", "b", "c"],
            watchedHrefKeys: [],
            continueReading: [],
            readChapters: [:],
            watchHistory: [])
        let modules = ModulesBackupPayload(
            modules: [.init(jsonUrl: "https://example.com/m.json",
                            sourceName: "Example",
                            scriptUrl: "https://example.com/m.js")],
            activeModuleId: nil,
            lastUsedModuleId: nil)

        let data = try envelopeData(sections: [
            BackupSectionID.progress: try JSONValue.encoding(progress, using: BackupCoding.encoder),
            BackupSectionID.modules: try JSONValue.encoding(modules, using: BackupCoding.encoder),
            BackupSectionID.settings: .object(["bools": .object([:]), "ints": .object([:]),
                                               "doubles": .object([:]), "strings": .object([:])])
        ])

        let (_, summary) = try manager().summarize(data)

        XCTAssertEqual(summary.appVersion, "1.0.6")
        XCTAssertEqual(summary.platform, "iOS")
        XCTAssertFalse(summary.includesAccounts)
        XCTAssertTrue(summary.lines.contains { $0.contains("3") && $0.contains("watched") },
                      "Expected a watched-episode count, got \(summary.lines)")
        XCTAssertTrue(summary.lines.contains { $0.contains("1") && $0.contains("module") },
                      "Expected a module count, got \(summary.lines)")
        XCTAssertTrue(summary.lines.contains { $0.lowercased().contains("settings") },
                      "Expected a settings line, got \(summary.lines)")
    }

    func testSummaryFlagsAccountsSoTheSheetCanWarn() throws {
        let data = try envelopeData(sections: [BackupSectionID.accounts: .object([:])],
                                    includesAccounts: true)
        let (_, summary) = try manager().summarize(data)
        XCTAssertTrue(summary.includesAccounts)
    }

    func testSummaryOfAnUnreadableFileThrowsNotABackup() {
        XCTAssertThrowsError(try manager().summarize(Data("nope".utf8))) { error in
            XCTAssertEqual(error as? BackupValidationError, .notABackupFile)
        }
    }

    func testSummaryRefusesANewerFormat() throws {
        var envelope = BackupEnvelope(formatVersion: BackupEnvelope.currentFormatVersion + 1,
                                      createdAt: Date(timeIntervalSince1970: 1_757_500_000),
                                      app: .init(version: "9.9.9", build: "999", platform: "iOS"),
                                      includesAccounts: false,
                                      sections: [:])
        envelope.formatVersion = BackupEnvelope.currentFormatVersion + 1
        let data = try BackupCoding.encoder.encode(envelope)
        XCTAssertThrowsError(try manager().summarize(data))
    }

    func testSummaryOmitsLinesForSectionsTheFileLacks() throws {
        let data = try envelopeData(sections: [:])
        let (_, summary) = try manager().summarize(data)
        XCTAssertTrue(summary.lines.isEmpty)
    }

    func testCorruptSectionDoesNotBreakTheSummary() throws {
        let data = try envelopeData(sections: [
            BackupSectionID.progress: .string("this is not a progress payload")
        ])
        let (_, summary) = try manager().summarize(data)
        // A section it can't read simply contributes no line — the summary still renders.
        XCTAssertTrue(summary.lines.isEmpty)
    }
}
