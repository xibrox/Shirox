import Foundation

// MARK: - JSONValue

/// Any JSON value, so a backup envelope can hold each section's payload verbatim.
///
/// Sections are decoded one at a time out of these. That is what lets a corrupt section
/// be skipped without failing the whole restore, and lets a section written by a newer
/// version of Shirox survive a decode/encode round-trip untouched rather than being
/// silently dropped.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Bool before Double: JSONDecoder keeps the two distinct, and checking Bool first
        // stops `true` from arriving as 1.
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension JSONValue {
    /// Decodes a typed section payload out of this value.
    func decoded<T: Decodable>(as type: T.Type, using decoder: JSONDecoder) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(type, from: data)
    }

    /// Captures a typed section payload as verbatim JSON.
    static func encoding<T: Encodable>(_ value: T, using encoder: JSONEncoder) throws -> JSONValue {
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - Coding

/// One encoder/decoder pair for the whole backup, so export and import always agree on
/// date representation. Dates go out as ISO-8601 strings: a backup file is meant to be
/// readable and stable across app versions, not compact.
enum BackupCoding {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - Section identifiers

enum BackupSectionID {
    static let progress = "progress"
    static let localLibrary = "localLibrary"
    static let settings = "settings"
    static let modules = "modules"
    static let accounts = "accounts"
}

// MARK: - Errors

enum BackupValidationError: LocalizedError, Equatable {
    case notABackupFile
    case newerFormat(fileVersion: Int, appVersion: Int)

    var errorDescription: String? {
        switch self {
        case .notABackupFile:
            return "This isn't a Shirox backup file."
        case .newerFormat(let file, let app):
            return "This backup was made by a newer version of Shirox (format \(file); this version reads up to \(app)). Update Shirox and try again."
        }
    }
}

// MARK: - Envelope

struct BackupEnvelope: Codable, Equatable {
    static let currentFormatVersion = 1

    struct AppInfo: Codable, Equatable {
        let version: String
        let build: String
        let platform: String
    }

    var formatVersion: Int
    var createdAt: Date
    var app: AppInfo
    /// Recorded in the envelope so the import screen can warn about credentials before
    /// any section is decoded.
    var includesAccounts: Bool
    var sections: [String: JSONValue]

    static func decode(from data: Data) throws -> BackupEnvelope {
        guard let envelope = try? BackupCoding.decoder.decode(BackupEnvelope.self, from: data) else {
            throw BackupValidationError.notABackupFile
        }
        guard envelope.formatVersion <= currentFormatVersion else {
            throw BackupValidationError.newerFormat(fileVersion: envelope.formatVersion,
                                                    appVersion: currentFormatVersion)
        }
        return envelope
    }
}

extension BackupEnvelope.AppInfo {
    static var current: BackupEnvelope.AppInfo {
        let info = Bundle.main.infoDictionary
        #if targetEnvironment(macCatalyst)
        let platform = "macCatalyst"
        #elseif os(iOS)
        let platform = "iOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "tvOS"
        #endif
        return .init(version: info?["CFBundleShortVersionString"] as? String ?? "0",
                     build: info?["CFBundleVersion"] as? String ?? "0",
                     platform: platform)
    }
}
