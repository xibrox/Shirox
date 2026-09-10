import XCTest
@testable import Shirox

/// The envelope is what makes a backup survive version drift: sections are held as
/// verbatim JSON so one corrupt section can't fail the file, and a section written by
/// a newer Shirox round-trips untouched instead of being dropped.
final class BackupEnvelopeTests: XCTestCase {

    private func makeEnvelope(sections: [String: JSONValue],
                              formatVersion: Int = BackupEnvelope.currentFormatVersion,
                              includesAccounts: Bool = false) -> BackupEnvelope {
        BackupEnvelope(formatVersion: formatVersion,
                       createdAt: Date(timeIntervalSince1970: 1_757_500_000),
                       app: .init(version: "1.0.6", build: "112", platform: "iOS"),
                       includesAccounts: includesAccounts,
                       sections: sections)
    }

    func testEnvelopeRoundTripsThroughJSON() throws {
        let original = makeEnvelope(sections: ["settings": .object(["preferredQuality": .string("auto")])])
        let data = try BackupCoding.encoder.encode(original)
        let decoded = try BackupEnvelope.decode(from: data)
        XCTAssertEqual(decoded, original)
    }

    func testUnknownSectionSurvivesRoundTripInsteadOfBeingDropped() throws {
        let original = makeEnvelope(sections: [
            "settings": .object(["preferredQuality": .string("auto")]),
            "sectionFromTheFuture": .object(["whatever": .number(7)])
        ])
        let data = try BackupCoding.encoder.encode(original)
        let decoded = try BackupEnvelope.decode(from: data)
        XCTAssertEqual(decoded.sections["sectionFromTheFuture"],
                       .object(["whatever": .number(7)]))
    }

    func testNewerFormatVersionIsRefused() throws {
        let future = makeEnvelope(sections: [:],
                                  formatVersion: BackupEnvelope.currentFormatVersion + 1)
        let data = try BackupCoding.encoder.encode(future)
        XCTAssertThrowsError(try BackupEnvelope.decode(from: data)) { error in
            XCTAssertEqual(error as? BackupValidationError,
                           .newerFormat(fileVersion: BackupEnvelope.currentFormatVersion + 1,
                                        appVersion: BackupEnvelope.currentFormatVersion))
        }
    }

    func testUnrelatedJSONIsRefusedAsNotABackup() {
        let data = Data(#"{"hello":"world"}"#.utf8)
        XCTAssertThrowsError(try BackupEnvelope.decode(from: data)) { error in
            XCTAssertEqual(error as? BackupValidationError, .notABackupFile)
        }
    }

    func testGarbageBytesAreRefusedAsNotABackup() {
        XCTAssertThrowsError(try BackupEnvelope.decode(from: Data([0x00, 0x01, 0x02]))) { error in
            XCTAssertEqual(error as? BackupValidationError, .notABackupFile)
        }
    }

    func testTypedPayloadDecodesFromAJSONValue() throws {
        struct Payload: Codable, Equatable { var name: String; var count: Int }
        let payload = Payload(name: "shirox", count: 3)
        let value = try JSONValue.encoding(payload, using: BackupCoding.encoder)
        XCTAssertEqual(try value.decoded(as: Payload.self, using: BackupCoding.decoder), payload)
    }

    func testDatesRoundTripThroughJSONValue() throws {
        struct Payload: Codable, Equatable { var at: Date }
        let payload = Payload(at: Date(timeIntervalSince1970: 1_757_500_000))
        let value = try JSONValue.encoding(payload, using: BackupCoding.encoder)
        XCTAssertEqual(try value.decoded(as: Payload.self, using: BackupCoding.decoder), payload)
    }

    func testBooleansDoNotDecodeAsNumbers() throws {
        let data = Data(#"{"flag":true,"n":1}"#.utf8)
        let value = try BackupCoding.decoder.decode(JSONValue.self, from: data)
        XCTAssertEqual(value, .object(["flag": .bool(true), "n": .number(1)]))
    }
}
