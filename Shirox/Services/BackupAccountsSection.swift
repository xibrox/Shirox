import Foundation

/// Live AniList / MAL / Jellyfin credentials.
///
/// Opt-in only: `BackupManager` skips this section unless the user turns on "Include
/// Accounts", because a backup containing it is a credential file — anyone who gets it
/// gets those accounts. The envelope's `includesAccounts` flag lets the import screen warn
/// before any of this is decoded.
struct AccountsBackupPayload: Codable {
    var anilistAccessToken: String?
    var anilistUserId: Int?
    var anilistScoreFormat: String?
    var malAccessToken: String?
    var malRefreshToken: String?
    var malTokenExpiry: Double?
    var malUserProfile: Data?
    var jellyfinAccessToken: String?
    var jellyfinUserId: String?
    var jellyfinServerURL: String?
    var jellyfinServerName: String?
    // `jellyfin_device_id` is intentionally absent: it identifies one device in the
    // server's session list, and cloning it would make two devices claim one session.
}

struct AccountsBackupSection: BackupSection {
    typealias Payload = AccountsBackupPayload
    static var id: String { BackupSectionID.accounts }

    @MainActor func export() throws -> AccountsBackupPayload? {
        let d = UserDefaults.standard
        let anilist = AniListAuthManager.shared
        let mal = MALAuthManager.shared
        let jellyfin = JellyfinAuthManager.shared
        return AccountsBackupPayload(
            anilistAccessToken: anilist.accessToken,
            anilistUserId: anilist.userId,
            anilistScoreFormat: d.string(forKey: "anilist_score_format"),
            malAccessToken: mal.accessToken,
            malRefreshToken: mal.refreshToken,
            malTokenExpiry: d.object(forKey: "mal_token_expiry") == nil
                ? nil : d.double(forKey: "mal_token_expiry"),
            malUserProfile: d.data(forKey: "mal_user_profile"),
            jellyfinAccessToken: jellyfin.accessToken,
            jellyfinUserId: jellyfin.userId,
            jellyfinServerURL: jellyfin.serverURL?.absoluteString,
            jellyfinServerName: jellyfin.serverName)
    }

    @MainActor func apply(_ payload: AccountsBackupPayload) async throws -> [String] {
        // Each manager writes its own Keychain items and refreshes its own published login
        // state. A nil field means the backup recorded no such account, which must leave
        // whatever is on this device alone rather than signing the user out.
        AniListAuthManager.shared.restoreAccount(token: payload.anilistAccessToken,
                                                  userId: payload.anilistUserId,
                                                  scoreFormat: payload.anilistScoreFormat)
        MALAuthManager.shared.restoreAccount(accessToken: payload.malAccessToken,
                                              refreshToken: payload.malRefreshToken,
                                              expiry: payload.malTokenExpiry,
                                              profile: payload.malUserProfile)
        JellyfinAuthManager.shared.restoreAccount(token: payload.jellyfinAccessToken,
                                                   userId: payload.jellyfinUserId,
                                                   serverURL: payload.jellyfinServerURL,
                                                   serverName: payload.jellyfinServerName)
        return []
    }
}
