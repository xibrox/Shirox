import Foundation

// MARK: - Section protocol

/// One data domain's half of the backup.
///
/// `apply` must write the domain's persistent storage **and** refresh its manager's
/// published state in the same step. Every store in this app is a `@MainActor` singleton
/// that reads storage once from a `private init()`, so writing UserDefaults underneath a
/// live singleton changes nothing on screen and gets overwritten by that singleton's next
/// mutation. That requirement is the reason this protocol exists instead of a flat
/// key-copying service — see the design doc before replacing it with one.
protocol BackupSection {
    associatedtype Payload: Codable
    static var id: String { get }

    /// Nil means "nothing to record", and the section is left out of the file.
    @MainActor func export() throws -> Payload?

    /// Returns human-readable warnings for parts that could not be restored but did not
    /// invalidate the section (a module whose manifest is unreachable, say).
    @MainActor func apply(_ payload: Payload) async throws -> [String]
}

/// Type-erased `BackupSection`, so `BackupManager` can hold an ordered heterogeneous list.
struct AnyBackupSection {
    let id: String
    let export: @MainActor () throws -> JSONValue?
    let apply: @MainActor (JSONValue) async throws -> [String]
}

extension BackupSection {
    @MainActor func erased() -> AnyBackupSection {
        AnyBackupSection(
            id: Self.id,
            export: {
                guard let payload = try self.export() else { return nil }
                return try JSONValue.encoding(payload, using: BackupCoding.encoder)
            },
            apply: { value in
                let payload = try value.decoded(as: Payload.self, using: BackupCoding.decoder)
                return try await self.apply(payload)
            }
        )
    }
}

// MARK: - Errors and reporting

enum BackupSectionError: LocalizedError, Equatable {
    /// The backup's Continue Watching data version isn't the one this app reads. The
    /// stored item shape differs, so the section is skipped rather than imported blind.
    case incompatibleDataVersion(found: Int, expected: Int)

    var errorDescription: String? {
        switch self {
        case .incompatibleDataVersion(let found, let expected):
            return "Progress data from an incompatible app version (found \(found), expected \(expected))."
        }
    }
}

struct BackupImportReport: Equatable {
    struct Note: Equatable {
        let section: String
        let detail: String
    }

    var applied: [String] = []
    var skipped: [Note] = []
    var warnings: [Note] = []
}

// MARK: - Summary

struct BackupSummary: Equatable {
    var createdAt: Date
    var appVersion: String
    var platform: String
    var includesAccounts: Bool
    /// Human-readable counts for the confirmation sheet, e.g. "1,204 watched episodes".
    var lines: [String]
}

// MARK: - Manager

@MainActor
final class BackupManager {
    static let shared = BackupManager(sections: defaultSections,
                                      directory: FileManager.default.temporaryDirectory)

    /// Apply order, not file order. Modules come before progress because Continue Watching
    /// items reference module ids, and accounts come last so a credential write can never
    /// be the thing that half-finishes a data restore.
    static var defaultSections: [AnyBackupSection] {
        [SettingsBackupSection().erased(),
         ModulesBackupSection().erased(),
         LocalLibraryBackupSection().erased(),
         ProgressBackupSection().erased(),
         AccountsBackupSection().erased()]
    }

    private let sections: [AnyBackupSection]
    private let directory: URL

    init(sections: [AnyBackupSection], directory: URL) {
        self.sections = sections
        self.directory = directory
    }

    // MARK: Export

    func makeEnvelope(includeAccounts: Bool, date: Date = Date()) -> BackupEnvelope {
        var payloads: [String: JSONValue] = [:]
        for section in sections {
            if section.id == BackupSectionID.accounts && !includeAccounts { continue }
            // `try?` flattens the optional return, so this skips a section that has
            // nothing to record and one whose export threw alike.
            guard let value = try? section.export() else { continue }
            payloads[section.id] = value
        }
        return BackupEnvelope(formatVersion: BackupEnvelope.currentFormatVersion,
                              createdAt: date,
                              app: .current,
                              includesAccounts: includeAccounts,
                              sections: payloads)
    }

    func exportFile(includeAccounts: Bool, date: Date = Date()) throws -> URL {
        let data = try BackupCoding.encoder.encode(makeEnvelope(includeAccounts: includeAccounts,
                                                                date: date))
        let url = directory.appendingPathComponent(Self.fileName(for: date))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "Shirox-Backup-\(f.string(from: date)).shiroxbackup"
    }

    // MARK: Import

    /// Sections are the atomic unit: each applies on its own, and one that fails is
    /// recorded and skipped so the rest still land. A skipped section leaves that
    /// domain's existing local data untouched.
    func importBackup(from data: Data) async throws -> BackupImportReport {
        let envelope = try BackupEnvelope.decode(from: data)
        var report = BackupImportReport()
        for section in sections {
            guard let value = envelope.sections[section.id] else { continue }
            do {
                let warnings = try await section.apply(value)
                report.applied.append(section.id)
                report.warnings.append(contentsOf: warnings.map {
                    .init(section: section.id, detail: $0)
                })
            } catch {
                report.skipped.append(.init(section: section.id,
                                            detail: error.localizedDescription))
            }
        }
        return report
    }
}
