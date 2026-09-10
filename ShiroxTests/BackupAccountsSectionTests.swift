import XCTest
@testable import Shirox

/// The privacy assertions matter as much as the round-trip ones: a backup taken without
/// the opt-in must contain no credentials at all.
@MainActor
final class BackupAccountsSectionTests: XCTestCase {

    private func manager() -> BackupManager {
        BackupManager(sections: BackupManager.defaultSections,
                      directory: FileManager.default.temporaryDirectory)
    }

    func testSectionIdIsAccounts() {
        XCTAssertEqual(AccountsBackupSection.id, BackupSectionID.accounts)
    }

    func testDefaultExportOmitsTheAccountsSectionEntirely() throws {
        let envelope = manager().makeEnvelope(includeAccounts: false, date: Date())
        XCTAssertNil(envelope.sections[BackupSectionID.accounts])
        XCTAssertFalse(envelope.includesAccounts)
    }

    func testDefaultExportJSONContainsNoTokenBearingKeys() throws {
        let data = try BackupCoding.encoder.encode(manager().makeEnvelope(includeAccounts: false,
                                                                          date: Date()))
        let json = String(decoding: data, as: UTF8.self)
        for needle in ["anilistAccessToken", "malAccessToken", "malRefreshToken",
                       "jellyfinAccessToken", "accounts"] {
            XCTAssertFalse(json.contains(needle), "\(needle) leaked into a no-accounts backup")
        }
        // And no live token value either.
        if let token = AniListAuthManager.shared.accessToken, !token.isEmpty {
            XCTAssertFalse(json.contains(token), "A live AniList token leaked into the backup")
        }
    }

    func testOptedInExportIncludesTheAccountsSection() throws {
        let envelope = manager().makeEnvelope(includeAccounts: true, date: Date())
        XCTAssertNotNil(envelope.sections[BackupSectionID.accounts])
        XCTAssertTrue(envelope.includesAccounts)
    }

    func testDeviceIdIsNeverBackedUp() throws {
        let payload = try XCTUnwrap(AccountsBackupSection().export())
        let data = try BackupCoding.encoder.encode(payload)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("deviceId"))
        XCTAssertFalse(json.contains(JellyfinAuthManager.shared.deviceId))
    }

    func testEmptyPayloadAppliesWithoutClobberingASignedInAccount() async throws {
        // A backup that recorded no accounts must not sign the device out.
        let tokenBefore = AniListAuthManager.shared.accessToken
        let empty = AccountsBackupPayload(anilistAccessToken: nil, anilistUserId: nil,
                                          anilistScoreFormat: nil, malAccessToken: nil,
                                          malRefreshToken: nil, malTokenExpiry: nil,
                                          malUserProfile: nil, jellyfinAccessToken: nil,
                                          jellyfinUserId: nil, jellyfinServerURL: nil,
                                          jellyfinServerName: nil)

        let warnings = try await AccountsBackupSection().apply(empty)

        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(AniListAuthManager.shared.accessToken, tokenBefore)
    }

    /// Writes a throwaway token into the *simulator's* keychain; the original is put back
    /// when the device had one. Simulator keychain state is disposable.
    func testAniListTokenRoundTripsThroughTheKeychain() async throws {
        let manager = AniListAuthManager.shared
        let original = manager.accessToken
        addTeardownBlock { @MainActor in
            if let original {
                manager.restoreAccount(token: original, userId: nil, scoreFormat: nil)
            }
        }

        manager.restoreAccount(token: "test-token-round-trip", userId: 4242, scoreFormat: "POINT_100")

        XCTAssertEqual(manager.accessToken, "test-token-round-trip")
        XCTAssertEqual(manager.userId, 4242)
        XCTAssertTrue(manager.isLoggedIn)

        let payload = try XCTUnwrap(AccountsBackupSection().export())
        XCTAssertEqual(payload.anilistAccessToken, "test-token-round-trip")
        XCTAssertEqual(payload.anilistUserId, 4242)
        XCTAssertEqual(payload.anilistScoreFormat, "POINT_100")
    }

    func testAccountsIsTheLastSectionApplied() {
        // A credential write must never be what half-finishes a data restore.
        XCTAssertEqual(BackupManager.defaultSections.last?.id, BackupSectionID.accounts)
    }
}
