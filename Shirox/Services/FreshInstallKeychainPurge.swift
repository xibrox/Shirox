import Foundation
import Security

/// Clears credentials a *previous* install left behind in the Keychain.
///
/// Deleting an iOS app does not delete its Keychain items. Reinstalling therefore finds the old
/// tokens still sitting there, and every auth manager here decides whether it is signed in by
/// asking exactly that question — `isLoggedIn = accessToken != nil` — so the app came up
/// claiming an account nobody had signed into on this install. Worse, those tokens are usually
/// dead by then (revoked, expired, or simply belonging to whoever used the device before), so
/// the ghost session produced authenticated requests that could only fail.
///
/// `UserDefaults`, unlike the Keychain, *is* erased when the app is deleted. Its emptiness is
/// therefore a reliable "nobody has launched this install before" signal, and the one launch
/// where that holds is the launch where leftover credentials must go.
///
/// Deliberately not run on an app *update*: the marker survives alongside the Keychain, so a
/// genuine signed-in session is left completely alone.
@MainActor
enum FreshInstallKeychainPurge {

    /// Set on the first launch of an install and never read for anything else. Its absence is
    /// what identifies a fresh install.
    private static let marker = "com.shirox.hasLaunchedSinceInstall"

    /// Every account this app stores under `kSecClassGenericPassword`. A credential missing
    /// from this list would survive a reinstall and go on impersonating a signed-in account,
    /// so anything added to the Keychain elsewhere belongs here too.
    static let accounts = [
        "anilist_access_token",
        "mal_access_token",
        "mal_refresh_token",
        "jellyfin_access_token",
        "jellyfin_user_id"
    ]

    private static var hasRun = false

    /// Runs once per process, before any auth manager reads its token.
    ///
    /// Called from each auth manager's initialiser rather than from app startup: whichever of
    /// them is touched first has to find the Keychain already cleaned, and singleton init order
    /// isn't something the call sites should have to get right.
    ///
    /// - Parameter accounts: injectable so tests drive this against throwaway account names.
    ///   They must never be pointed at the real ones: on the simulator the test host shares a
    ///   keychain with the app, so a test that writes and deletes `anilist_access_token` signs
    ///   the actual app out — which is exactly what happened when these tests first landed.
    static func runIfNeeded(defaults: UserDefaults = .standard,
                            accounts: [String] = FreshInstallKeychainPurge.accounts) {
        guard !hasRun else { return }
        hasRun = true

        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)

        let cleared = accounts.filter { delete(account: $0) }
        guard !cleared.isEmpty else { return }
        Logger.shared.log(
            "[Keychain] Fresh install — dropped \(cleared.count) credential(s) left by a previous install: \(cleared.joined(separator: ", "))",
            type: "Info")
    }

    /// Deletes one generic-password item. Returns whether something was actually there, so the
    /// log reports real leftovers rather than a line on every clean first launch.
    @discardableResult
    private static func delete(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Test seam: lets a test drive the "second launch" path without a real reinstall.
    static func resetForTesting() {
        hasRun = false
    }
}
