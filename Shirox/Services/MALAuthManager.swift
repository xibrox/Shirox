import Foundation
import AuthenticationServices
import Security

@MainActor
final class MALAuthManager: NSObject, ObservableObject {
    static let shared = MALAuthManager()

    @Published var isLoggedIn = false
    @Published var username: String?
    @Published var avatarURL: String?
    @Published var userId: Int?

    // Register app at https://myanimelist.net/apiconfig
    // App Type: other, Redirect URI: shirox://auth-mal
    let clientId = "YOUR_MAL_CLIENT_ID"

    private let accessTokenKey = "mal_access_token"
    private let refreshTokenKey = "mal_refresh_token"
    private var codeVerifier: String?
    private var authSession: ASWebAuthenticationSession?
    nonisolated(unsafe) var presentationAnchorWindow: ASPresentationAnchor?

    private override init() {
        super.init()
        isLoggedIn = accessToken != nil
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
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
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
        struct TokenResponse: Decodable { let access_token: String; let refresh_token: String }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        keychainWrite(key: accessTokenKey, value: tokens.access_token)
        keychainWrite(key: refreshTokenKey, value: tokens.refresh_token)
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
        let (data, _) = try await URLSession.shared.data(for: request)
        struct TokenResponse: Decodable { let access_token: String; let refresh_token: String }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        keychainWrite(key: accessTokenKey, value: tokens.access_token)
        keychainWrite(key: refreshTokenKey, value: tokens.refresh_token)
    }

    func fetchCurrentUser() async {
        do {
            let profile = try await MALSocialService.shared.fetchCurrentUserProfile()
            userId = profile.id
            username = profile.name
            avatarURL = profile.avatarURL
        } catch {
            print("MAL fetchCurrentUser error: \(error)")
        }
    }

    func logout() {
        keychainDelete(key: accessTokenKey)
        keychainDelete(key: refreshTokenKey)
        isLoggedIn = false
        username = nil
        avatarURL = nil
        userId = nil
    }

    func authorizedRequest(url: URL, method: String = "GET") async throws -> URLRequest {
        guard let token = accessToken else { throw ProviderError.unauthenticated }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

extension MALAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationAnchorWindow ?? ASPresentationAnchor()
    }
}
