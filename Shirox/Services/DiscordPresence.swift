#if !os(tvOS)
import AuthenticationServices
import Combine
import Foundation

/// What's playing or being read, as the user's Discord status. No Discord SDK and no user
/// token: the user signs in with Discord (OAuth with PKCE, as a public client, so no server is
/// needed), and the presence is a "headless session" set over Discord's HTTP API with that
/// sign-in's `activities.write`, which the `sdk.social_layer_presence` scope grants.
///
/// Player- and reader-agnostic: the player's Now Playing update and the readers call
/// `updateMedia` / `updateManga`, and `clear` when they close.
@MainActor
final class DiscordPresence: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = DiscordPresence()

    static let enabledKey = "discordPresenceEnabled"
    static let applicationIDKey = "discordApplicationID"
    static let showsCoverKey = "discordShowsCover"
    static let showsDetailsKey = "discordShowsDetails"
    /// Shirox's Discord application (Social SDK on, public client, redirect `shirox://discord`).
    static let defaultApplicationID = "1375525918696669305"
    static let redirectURI = "shirox://discord"
    nonisolated static let accessTokenAccount = "discord_access_token"
    nonisolated static let refreshTokenAccount = "discord_refresh_token"
    private static let expiryKey = "discord_token_expiry"
    private static let usernameKey = "discord_username"
    private static let api = URL(string: "https://discord.com/api/v10")!
    /// A headless session ends by itself after 20 minutes; it's renewed well before that.
    private static let renewInterval: TimeInterval = 10 * 60

    @Published private(set) var username: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastError: String?
    /// The test status from Settings is up.
    @Published private(set) var isShowingTest = false

    var isSignedIn: Bool { keychainRead(Self.refreshTokenAccount) != nil }

    private var authSession: ASWebAuthenticationSession?
    private var anchor: ASPresentationAnchor?
    /// The headless session's token, to update and end it.
    private var sessionToken: String?
    /// What was last sent, to skip repeats: the player reports several times a second.
    private var sent: Activity?
    private var pending: Activity?
    private var sendTask: Task<Void, Never>?
    private var renewTimer: Timer?
    /// The token refresh under way. Discord hands out a new refresh token with each one and
    /// takes the old one only once, so a second refresh at the same time would fail and lose
    /// the sign-in.
    private var refreshTask: Task<String, Error>?

    private override init() {
        super.init()
        username = UserDefaults.standard.string(forKey: Self.usernameKey)
    }

    private var defaults: UserDefaults { .standard }
    private var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    private var applicationID: String {
        let id = defaults.string(forKey: Self.applicationIDKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return id.isEmpty ? Self.defaultApplicationID : id
    }
    private var showsCover: Bool { defaults.object(forKey: Self.showsCoverKey) as? Bool ?? true }
    private var showsDetails: Bool { defaults.object(forKey: Self.showsDetailsKey) as? Bool ?? true }

    // MARK: - What's shown

    /// Something playing: a show's episode, a movie, a video. `elapsed` sets the timer Discord
    /// counts up from while it plays, and with `duration` it shows a progress bar; paused,
    /// there's neither. `rate` is the playback speed, so the bar ends when the episode does.
    func updateMedia(title: String, subtitle: String?, season: Int?, episode: Int?,
                     coverURL: String?, isPlaying: Bool, elapsed: Double? = nil,
                     duration: Double? = nil, rate: Double = 1) {
        var lines: [String] = []
        if showsDetails {
            switch (season, episode) {
            case let (season?, episode?):
                lines.append(String(localized: "shared.discord_season_episode \(season) \(episode)"))
            case let (nil, episode?):
                lines.append(String(localized: "common.episode \(episode)"))
            default:
                break
            }
            if let subtitle, !subtitle.isEmpty { lines.append(subtitle) }
        }
        if !isPlaying { lines.append(String(localized: "shared.discord_paused")) }
        let speed = rate > 0 ? rate : 1
        let now = Date()
        let start = isPlaying ? now.addingTimeInterval(-(elapsed ?? 0) / speed) : nil
        var end: Date?
        if isPlaying, let duration, duration > 0 {
            end = now.addingTimeInterval(max(duration - (elapsed ?? 0), 0) / speed)
        }
        show(Activity(type: .watching, details: title, state: lines.joined(separator: " · "),
                      cover: coverURL, coverText: title, start: start, end: end))
    }

    /// A manga open in the reader, at a chapter.
    func updateManga(title: String, chapter: String?, volume: String?, coverURL: String?) {
        var lines: [String] = []
        if showsDetails {
            if let volume, !volume.isEmpty { lines.append(volume) }
            if let chapter, !chapter.isEmpty { lines.append(chapter) }
        }
        show(Activity(type: .playing, details: String(localized: "shared.discord_reading \(title)"),
                      state: lines.joined(separator: " · "), cover: coverURL, coverText: title, start: Date(), end: nil))
    }

    /// A sample status with the Shirox icon, to try the setup without anything playing.
    func showTest() {
        updateMedia(title: "Shirox", subtitle: String(localized: "settings.discord_test_status"),
                    season: 1, episode: 1, coverURL: Self.iconURL, isPlaying: true)
        isShowingTest = true
    }

    /// Shirox's icon, as Discord serves it for the application.
    private static let iconURL =
        "https://cdn.discordapp.com/app-icons/1375525918696669305/a1d768656bd887068ec1103230785e52.png?size=512"

    /// Nothing open any more: the status goes.
    func clear() {
        isShowingTest = false
        pending = nil
        sendTask?.cancel()
        sendTask = nil
        renewTimer?.invalidate()
        renewTimer = nil
        sent = nil
        guard let token = sessionToken else { return }
        sessionToken = nil
        Task { try? await self.deleteSession(token) }
    }

    private func show(_ activity: Activity) {
        guard isEnabled, isSignedIn else { return }
        // A playing update restarts the timer every time; only a new title, line or state counts.
        if let sent, sent.sameContent(as: activity) { return }
        // The player reports twice a second. Waiting again on each report never let the wait
        // run out, so nothing was sent while something played: the same status keeps its wait.
        if let pending, pending.sameContent(as: activity), sendTask != nil {
            self.pending = activity
            return
        }
        pending = activity
        // Coalesced: a burst of changes (a new episode starting) goes out once.
        sendTask?.cancel()
        sendTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self.sendTask = nil
            guard let activity = self.pending else { return }
            await self.send(activity)
        }
    }

    private func send(_ activity: Activity) async {
        do {
            do {
                try await post(activity)
            } catch DiscordError.http(let status) where (400..<500).contains(status) {
                // The session ran out (the app was away for more than its 20 minutes) or the
                // token was turned down: start over with a fresh session and token once,
                // rather than failing every update until the app is opened again.
                sessionToken = nil
                if status == 401 { invalidateAccessToken() }
                try await post(activity)
            }
            sent = activity
            if pending?.sameContent(as: activity) == true { pending = nil }
            lastError = nil
            scheduleRenewal()
        } catch {
            lastError = error.localizedDescription
            Logger.shared.log("[Discord] Presence not set: \(error.localizedDescription)", type: "Error")
        }
    }

    private func post(_ activity: Activity) async throws {
        let token = try await validAccessToken()
        var body: [String: Any] = ["activities": [activity.json(applicationID: applicationID,
                                                               showsCover: showsCover)]]
        if let sessionToken { body["token"] = sessionToken }
        let data = try await request("users/@me/headless-sessions", body: body, token: token)
        if let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let session = reply["token"] as? String {
            sessionToken = session
        }
    }

    /// Sends the same activity again before the session's 20 minutes run out.
    private func scheduleRenewal() {
        renewTimer?.invalidate()
        renewTimer = Timer.scheduledTimer(withTimeInterval: Self.renewInterval, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let activity = DiscordPresence.shared.sent else { return }
                Task { await DiscordPresence.shared.send(activity) }
            }
        }
    }

    private func deleteSession(_ session: String) async throws {
        let token = try await validAccessToken()
        _ = try await request("users/@me/headless-sessions/delete", body: ["token": session], token: token)
    }

    // MARK: - Sign-in

    func signIn(presentationAnchor: ASPresentationAnchor) {
        guard let verifier = SimklOAuth.makeCodeVerifier() else { return }
        let state = UUID().uuidString
        guard var components = URLComponents(string: "https://discord.com/oauth2/authorize") else { return }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: applicationID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: "openid sdk.social_layer_presence"),
            URLQueryItem(name: "code_challenge", value: SimklOAuth.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else { return }
        anchor = presentationAnchor
        isSigningIn = true
        lastError = nil
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "shirox") { callbackURL, _ in
            Task { @MainActor in
                defer { DiscordPresence.shared.isSigningIn = false }
                guard let callbackURL,
                      let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                      items.first(where: { $0.name == "state" })?.value == state,
                      let code = items.first(where: { $0.name == "code" })?.value else { return }
                await DiscordPresence.shared.finishSignIn(code: code, verifier: verifier)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    private func finishSignIn(code: String, verifier: String) async {
        do {
            let tokens = try await tokenRequest([
                ("client_id", applicationID), ("grant_type", "authorization_code"), ("code", code),
                ("redirect_uri", Self.redirectURI), ("code_verifier", verifier)
            ])
            store(tokens)
            let data = try await request("users/@me", body: nil, token: tokens.access)
            if let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                username = (user["global_name"] as? String) ?? (user["username"] as? String)
                defaults.set(username, forKey: Self.usernameKey)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        clear()
        if let refresh = keychainRead(Self.refreshTokenAccount) {
            let body = SimklOAuth.formBody([("client_id", applicationID), ("token", refresh),
                                            ("token_type_hint", "refresh_token")])
            var request = URLRequest(url: URL(string: "https://discord.com/api/oauth2/token/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            URLSession.shared.dataTask(with: request).resume()
        }
        keychainDelete(Self.accessTokenAccount)
        keychainDelete(Self.refreshTokenAccount)
        defaults.removeObject(forKey: Self.expiryKey)
        defaults.removeObject(forKey: Self.usernameKey)
        username = nil
        objectWillChange.send()
    }

    // MARK: - Tokens

    private struct Tokens {
        let access: String
        let refresh: String
        let expiresIn: Double
    }

    private enum DiscordError: LocalizedError {
        case signedOut
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .signedOut: return String(localized: "shared.discord_signed_out")
            case .http(let status): return String(localized: "shared.server_returned_http \(status)")
            }
        }
    }

    private func validAccessToken() async throws -> String {
        let expiry = defaults.double(forKey: Self.expiryKey)
        if let access = keychainRead(Self.accessTokenAccount), Date().timeIntervalSince1970 < expiry - 60 {
            return access
        }
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = keychainRead(Self.refreshTokenAccount) else { throw DiscordError.signedOut }
        let task = Task { () throws -> String in
            let tokens = try await self.tokenRequest([("client_id", self.applicationID),
                                                      ("grant_type", "refresh_token"), ("refresh_token", refresh)])
            self.store(tokens)
            return tokens.access
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    /// The access token was turned down before it ran out: the next request refreshes it.
    private func invalidateAccessToken() {
        defaults.set(0, forKey: Self.expiryKey)
    }

    private func store(_ tokens: Tokens) {
        keychainWrite(Self.accessTokenAccount, tokens.access)
        keychainWrite(Self.refreshTokenAccount, tokens.refresh)
        defaults.set(Date().timeIntervalSince1970 + tokens.expiresIn, forKey: Self.expiryKey)
        objectWillChange.send()
    }

    private func tokenRequest(_ form: [(String, String)]) async throws -> Tokens {
        var request = URLRequest(url: Self.api.appendingPathComponent("oauth2/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SimklOAuth.formBody(form)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            // A refresh token Discord no longer takes: signed out for good, and Settings says so.
            // Only the one that was sent, though: one stored since is still good.
            let sent = form.first { $0.0 == "refresh_token" }?.1
            if status == 400 || status == 401, let sent, sent == keychainRead(Self.refreshTokenAccount) {
                keychainDelete(Self.refreshTokenAccount)
                objectWillChange.send()
            }
            throw DiscordError.http(status)
        }
        return Tokens(access: access, refresh: refresh, expiresIn: (json["expires_in"] as? Double) ?? 604_800)
    }

    private func request(_ path: String, body: [String: Any]?, token: String) async throws -> Data {
        var request = URLRequest(url: Self.api.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DiscordError.http(status) }
        return data
    }

    // MARK: - Keychain

    // The same shape as the other accounts' (see `SimklAuthManager`): the items are listed in
    // `FreshInstallKeychainPurge.accounts`, so a reinstall and a profile switch handle them too.

    private func keychainRead(_ key: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: key,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(_ key: String, _ value: String) {
        keychainDelete(key)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: key,
                                      kSecValueData: Data(value.utf8),
                                      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func keychainDelete(_ key: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: key]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor ?? ASPresentationAnchor() }
    }
}

// MARK: - Activity

/// One status, as Discord's activity object takes it.
private struct Activity: Equatable {
    enum Kind: Int {
        case playing = 0
        case watching = 3
    }

    let type: Kind
    let details: String
    let state: String
    let cover: String?
    let coverText: String
    let start: Date?
    /// When the progress bar is full; nil shows only the timer.
    let end: Date?

    /// The same thing shown: a timer a second further on isn't a change. With a progress bar a
    /// seek is; without one (the reader starts its timer anew on every page) only whether there
    /// is a timer counts.
    func sameContent(as other: Activity) -> Bool {
        guard type == other.type, details == other.details, state == other.state, cover == other.cover,
              (start == nil) == (other.start == nil) else { return false }
        if end == nil, other.end == nil { return true }
        return Self.close(start, other.start) && Self.close(end, other.end)
    }

    /// Both unset, or within a few seconds: the player's reports drift a little.
    private static func close(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) < 5
        default: return false
        }
    }

    func json(applicationID: String, showsCover: Bool) -> [String: Any] {
        var json: [String: Any] = [
            "name": "Shirox",
            "type": type.rawValue,
            "application_id": applicationID,
            "platform": Self.platform,
            "details": String(details.prefix(128)),
            // The title, not "Shirox", in the member list.
            "status_display_type": 2
        ]
        if !state.isEmpty { json["state"] = String(state.prefix(128)) }
        if let start {
            var timestamps = ["start": Int(start.timeIntervalSince1970 * 1_000)]
            if let end { timestamps["end"] = Int(end.timeIntervalSince1970 * 1_000) }
            json["timestamps"] = timestamps
        }
        // Discord fetches outside images through its own proxy for headless sessions.
        if showsCover, let cover, cover.hasPrefix("https://") {
            json["assets"] = ["large_image": cover, "large_text": String(coverText.prefix(128))]
        }
        return json
    }

    private static var platform: String {
        #if os(macOS)
        return "desktop"
        #else
        return ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac ? "desktop" : "ios"
        #endif
    }
}
#endif
