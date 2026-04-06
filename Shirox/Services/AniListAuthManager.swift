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

    // Replace with your AniList API client ID from https://anilist.co/settings/developer
    // Redirect URI must be set to: shirox://auth
    private let clientId = "YOUR_ANILIST_CLIENT_ID"
    private let keychainKey = "anilist_access_token"

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
            URLQueryItem(name: "response_type", value: "token")
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
        session.prefersEphemeralWebBrowserSession = false
        session.start()
    }

    func handleCallback(url: URL) {
        // AniList returns token in fragment: shirox://auth#access_token=...&token_type=Bearer&expires_in=...
        guard let fragment = url.fragment else { return }
        var params: [String: String] = [:]
        for part in fragment.components(separatedBy: "&") {
            let kv = part.components(separatedBy: "=")
            if kv.count == 2 { params[kv[0]] = kv[1] }
        }
        guard let token = params["access_token"] else { return }
        saveToken(token)
        isLoggedIn = true
        Task { await fetchViewer() }
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
