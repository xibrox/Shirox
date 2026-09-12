import XCTest
@testable import Shirox

/// Tests for the one launch on which leftover Keychain credentials are dropped.
///
/// Deleting an iOS app leaves its Keychain items on the device. Every auth manager here decides
/// it is signed in by asking whether a token exists, so a reinstall came up claiming an account
/// nobody had signed into — with a token long since dead, which then failed every authenticated
/// request it was used for.
@MainActor
final class FreshInstallKeychainPurgeTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FreshInstallPurgeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        FreshInstallKeychainPurge.resetForTesting()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        FreshInstallKeychainPurge.resetForTesting()
        super.tearDown()
    }

    private let marker = "com.shirox.hasLaunchedSinceInstall"

    /// Throwaway account names, unique per test run.
    ///
    /// Never the real ones: on the simulator the test host shares a keychain with the app, so
    /// an earlier version of these tests — which wrote and deleted `anilist_access_token`
    /// directly — signed the actual app out of AniList every time the suite ran.
    private var fakeAccount: String { "test.shirox.purge.\(suiteName!)" }

    /// A fresh install — nothing in UserDefaults, because deleting the app cleared it — is the
    /// launch that has to clean up.
    func testFirstLaunchMarksItselfAsHavingRun() {
        XCTAssertFalse(defaults.bool(forKey: marker))
        FreshInstallKeychainPurge.runIfNeeded(defaults: defaults, accounts: [fakeAccount])
        XCTAssertTrue(defaults.bool(forKey: marker),
                      "the first launch must record itself, or every later launch would purge again")
    }

    /// The crucial guarantee: an ordinary later launch — or an app update, which keeps
    /// UserDefaults — must leave a genuine signed-in session completely alone.
    func testLaterLaunchDoesNotPurge() {
        defaults.set(true, forKey: marker)

        // A token saved by the "previous" launch must still be there afterwards.
        let account = fakeAccount
        saveToken("live-session-token", account: account)
        defer { deleteToken(account: account) }

        FreshInstallKeychainPurge.resetForTesting()
        FreshInstallKeychainPurge.runIfNeeded(defaults: defaults, accounts: [account])

        XCTAssertEqual(readToken(account: account), "live-session-token",
                       "an update or ordinary relaunch must not sign the user out")
    }

    /// The actual bug: a token left behind by a previous install is gone after the purge, so
    /// `isLoggedIn = accessToken != nil` can no longer report a session nobody signed into.
    func testFirstLaunchDropsALeftoverToken() {
        let account = fakeAccount
        saveToken("token-from-a-previous-install", account: account)
        defer { deleteToken(account: account) }

        FreshInstallKeychainPurge.runIfNeeded(defaults: defaults, accounts: [account])

        XCTAssertNil(readToken(account: account))
    }

    /// Runs once per process: a second call in the same launch must not re-purge, or a sign-in
    /// completed moments after startup would be wiped by the next manager to initialise.
    func testRunsOnlyOncePerProcess() {
        let account = fakeAccount
        FreshInstallKeychainPurge.runIfNeeded(defaults: defaults, accounts: [account])

        saveToken("signed-in-after-launch", account: account)
        defer { deleteToken(account: account) }

        FreshInstallKeychainPurge.runIfNeeded(defaults: defaults, accounts: [account])

        XCTAssertEqual(readToken(account: account), "signed-in-after-launch")
    }

    // MARK: - Keychain helpers

    private func saveToken(_ value: String, account: String) {
        deleteToken(account: account)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func readToken(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteToken(account: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account
        ] as CFDictionary)
    }
}
