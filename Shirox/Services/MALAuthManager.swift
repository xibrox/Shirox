import Foundation
import AuthenticationServices
import Security
import Combine

enum MALAuthError: Error {
    /// The refresh-token grant failed (e.g. invalid_grant). Caller should sign out.
    case refreshFailed(status: Int)
}

@MainActor
final class MALAuthManager: NSObject, ObservableObject {
    static let shared = MALAuthManager()

    @Published var isLoggedIn = false
    @Published var username: String?
    @Published var avatarURL: String?
    @Published var userId: Int?

    // Register app at https://myanimelist.net/apiconfig
    // App Type: other, Redirect URI: shirox://auth-mal
    let clientId = "9e0dc49b04d7c8f95014ddcb7718fcb9"

    private let accessTokenKey = "mal_access_token"
    private let refreshTokenKey = "mal_refresh_token"
    private let profileKey = "mal_user_profile"
    private let tokenExpiryKey = "mal_token_expiry"
    private var codeVerifier: String?
    private var authSession: ASWebAuthenticationSession?
    nonisolated(unsafe) var presentationAnchorWindow: ASPresentationAnchor?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()
    private var refreshTask: Task<Void, Error>?

    private struct CachedProfile: Codable {
        let id: Int; let name: String; let avatarURL: String?
    }

    private override init() {
        super.init()
        isLoggedIn = accessToken != nil
        if isLoggedIn, let data = UserDefaults.standard.data(forKey: profileKey),
           let cached = try? JSONDecoder().decode(CachedProfile.self, from: data) {
            userId = cached.id
            username = cached.name
            avatarURL = cached.avatarURL
        }
    }

    // MARK: - Keychain

    var accessToken: String? { keychainRead(key: accessTokenKey) }
    var refreshToken: String? { keychainRead(key: refreshTokenKey) }

    private func keychainRead(key: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                      kSecAttrAccount: key,
                                      kSecReturnData: true,
                                      kSecMatchLimit: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(key: String, value: String) {
        let data = Data(value.utf8)
        let deleteQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: key]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
                                          kSecAttrAccount: key,
                                          kSecValueData: data,
                                          kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func keychainDelete(key: String) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: key]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: - Token expiry

    /// Absolute expiry of the current access token, if known.
    private var tokenExpiry: Date? {
        let t = UserDefaults.standard.double(forKey: tokenExpiryKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func storeTokenExpiry(expiresIn: Int) {
        let date = Date().addingTimeInterval(TimeInterval(expiresIn))
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: tokenExpiryKey)
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Login

    func login(presentationAnchor: ASPresentationAnchor) {
        presentationAnchorWindow = presentationAnchor
        let verifier = generateCodeVerifier()
        codeVerifier = verifier

        var components = URLComponents(string: "https://myanimelist.net/v1/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code_challenge", value: verifier),
            URLQueryItem(name: "code_challenge_method", value: "plain"),
            URLQueryItem(name: "redirect_uri", value: "shirox://auth-mal")
        ]

        let session = ASWebAuthenticationSession(
            url: components.url!,
            callbackURLScheme: "shirox"
        ) { [weak self] callbackURL, error in
            guard let self, let url = callbackURL, error == nil else { return }
            Task { await self.handleCallback(url: url) }
        }

        #if !os(tvOS)
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
        #endif
        
        authSession = session
        session.start()
    }

    private func handleCallback(url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let verifier = codeVerifier else { return }
        do {
            try await exchangeCode(code, verifier: verifier)
            await fetchCurrentUser()
        } catch {
            print("MAL auth error: \(error)")
        }
    }

    private func exchangeCode(_ code: String, verifier: String) async throws {
        let url = URL(string: "https://myanimelist.net/v1/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyParts = [
            "client_id=\(clientId)",
            "code=\(code)",
            "code_verifier=\(verifier)",
            "grant_type=authorization_code",
            "redirect_uri=shirox://auth-mal"
        ]
        request.httpBody = bodyParts.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        struct TokenResponse: Decodable { let access_token: String; let refresh_token: String; let expires_in: Int }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        keychainWrite(key: accessTokenKey, value: tokens.access_token)
        keychainWrite(key: refreshTokenKey, value: tokens.refresh_token)
        storeTokenExpiry(expiresIn: tokens.expires_in)
        isLoggedIn = true
    }

    func refreshAccessToken() async throws {
        guard let refresh = refreshToken else { throw ProviderError.unauthenticated }
        let url = URL(string: "https://myanimelist.net/v1/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(clientId)&grant_type=refresh_token&refresh_token=\(refresh)"
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw MALAuthError.refreshFailed(status: http.statusCode)
        }
        struct TokenResponse: Decodable { let access_token: String; let refresh_token: String; let expires_in: Int }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        keychainWrite(key: accessTokenKey, value: tokens.access_token)
        keychainWrite(key: refreshTokenKey, value: tokens.refresh_token)
        storeTokenExpiry(expiresIn: tokens.expires_in)
        Logger.shared.log("[MAL] access token refreshed (expires in \(tokens.expires_in)s)", type: "Info")
    }

    func fetchCurrentUser() async {
        do {
            let profile = try await MALSocialService.shared.fetchCurrentUserProfile()
            userId = profile.id
            username = profile.name
            avatarURL = profile.avatarURL
            let cached = CachedProfile(id: profile.id, name: profile.name, avatarURL: profile.avatarURL)
            if let data = try? JSONEncoder().encode(cached) {
                UserDefaults.standard.set(data, forKey: profileKey)
            }
        } catch {
            print("MAL fetchCurrentUser error: \(error)")
        }
    }

    func logout() {
        keychainDelete(key: accessTokenKey)
        keychainDelete(key: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: tokenExpiryKey)
        isLoggedIn = false
        username = nil
        avatarURL = nil
        userId = nil
        PendingWriteQueue.shared.discardWrites(for: .mal)
    }

    func authorizedRequest(url: URL, method: String = "GET") async throws -> URLRequest {
        guard let token = accessToken else { throw ProviderError.unauthenticated }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Refresh the access token if it is expired/near-expiry, or unconditionally when `force`.
    /// Concurrent callers share a single in-flight refresh.
    private func refreshIfNeeded(force: Bool) async throws {
        if !force, let expiry = tokenExpiry, expiry.timeIntervalSinceNow > 60 { return }
        if let task = refreshTask {
            try await task.value
            return
        }
        let task = Task<Void, Error> { try await self.performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performRefresh() async throws {
        do {
            try await refreshAccessToken()
        } catch {
            if case MALAuthError.refreshFailed(let status) = error, status == 400 || status == 401 {
                Logger.shared.log("[MAL] token refresh rejected (status \(status)) — signing out", type: "Error")
                logout()
            } else {
                Logger.shared.log("[MAL] token refresh failed: \(error)", type: "Error")
            }
            throw error
        }
    }

    /// Send an authenticated request to the official MAL API, refreshing the token
    /// proactively and (once) reactively on a 401. Returns the decoded HTTP response.
    func send(url: URL,
              method: String = "GET",
              body: Data? = nil,
              contentType: String? = nil) async throws -> (Data, HTTPURLResponse) {
        Logger.shared.log("[MAL] authenticated \(method) \(url.path)", type: "Debug")
        try await refreshIfNeeded(force: false)

        func attempt() async throws -> (Data, HTTPURLResponse) {
            var request = try await authorizedRequest(url: url, method: method)
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            if let body { request.httpBody = body }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.networkError(URLError(.badServerResponse))
            }
            return (data, http)
        }

        var (data, http) = try await attempt()
        if http.statusCode == 401 {
            try await refreshIfNeeded(force: true)
            (data, http) = try await attempt()
            if http.statusCode == 401 {
                logout()
                throw ProviderError.unauthenticated
            }
        }
        return (data, http)
    }
}

#if !os(tvOS)
extension MALAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { presentationAnchorWindow ?? ASPresentationAnchor() }
    }
}
#endif
