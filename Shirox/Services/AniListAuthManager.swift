import Foundation
import AuthenticationServices
import Security

@MainActor
final class AniListAuthManager: NSObject, ObservableObject {
    static let shared = AniListAuthManager()

    @Published var isLoggedIn = false
    @Published var username: String?
    @Published var avatarURL: String?
    @Published var userId: Int?

    // From https://anilist.co/settings/developer — Redirect URI: shirox://auth
    private let clientId = "38624"
    private let clientSecret = Bundle.main.infoDictionary?["ANILIST_CLIENT_SECRET"] as? String ?? ""
    private let keychainKey = "anilist_access_token"
    private var authSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        isLoggedIn = accessToken != nil
    }

    // MARK: - Token

    var accessToken: String? {
        get {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: keychainKey,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private func saveToken(_ token: String) {
        let data = Data(token.utf8)
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: keychainKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: keychainKey,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func deleteToken() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: keychainKey
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - OAuth

    func login(presentationAnchor: ASPresentationAnchor) async {
        guard var components = URLComponents(string: "https://anilist.co/api/v2/oauth/authorize") else { return }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: "shirox://auth")
        ]
        guard let authURL = components.url else { return }

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: "shirox"
        ) { [weak self] callbackURL, error in
            guard let self, let url = callbackURL, error == nil else { return }
            Task { @MainActor in self.handleCallback(url: url) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        authSession = session
        session.start()
    }

    func handleCallback(url: URL) {
        // AniList returns authorization code as query param: shirox://auth?code=...
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return }
        Task { await exchangeCode(code) }
    }

    private func exchangeCode(_ code: String) async {
        guard let url = URL(string: "https://anilist.co/api/v2/oauth/token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": "shirox://auth",
            "code": code
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }

        struct TokenResponse: Decodable {
            let access_token: String?
        }
        if let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
           let token = response.access_token {
            saveToken(token)
            isLoggedIn = true
            await fetchViewer()
        } else {
            print("[AniList] Token exchange failed: \(String(data: data, encoding: .utf8) ?? "")")
        }
    }

    func logout() {
        deleteToken()
        isLoggedIn = false
        username = nil
        avatarURL = nil
        userId = nil
    }

    // MARK: - Viewer

    func fetchViewer() async {
        guard let token = accessToken else { return }
        let query = """
        query {
          Viewer {
            id
            name
            avatar { large }
          }
        }
        """
        guard let url = URL(string: "https://graphql.anilist.co") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["query": query]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }

        struct ViewerResponse: Decodable {
            struct ResponseData: Decodable {
                let Viewer: Viewer
            }
            struct Viewer: Decodable {
                let id: Int
                let name: String
                let avatar: Avatar
            }
            struct Avatar: Decodable {
                let large: String?
            }
            let data: ResponseData?
        }
        if let response = try? JSONDecoder().decode(ViewerResponse.self, from: data) {
            userId = response.data?.Viewer.id
            username = response.data?.Viewer.name
            avatarURL = response.data?.Viewer.avatar.large
        }
    }
}

extension AniListAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
