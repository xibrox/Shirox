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
    private let keychainKey = "anilist_access_token"
    private var authSession: ASWebAuthenticationSession?
    nonisolated(unsafe) var presentationAnchorWindow: ASPresentationAnchor?

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

    func login(presentationAnchor: ASPresentationAnchor) {
        presentationAnchorWindow = presentationAnchor
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
            Logger.shared.log("[AniList] callback fired — url: \(callbackURL?.absoluteString ?? "nil"), error: \(error?.localizedDescription ?? "nil")", type: "Debug")
            guard let self, let url = callbackURL, error == nil else { return }
            Task { @MainActor in self.handleCallback(url: url) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true
        authSession = session
        session.start()
    }

    func handleCallback(url: URL) {
        Logger.shared.log("[AniList] handleCallback url: \(url.absoluteString)", type: "Debug")
        // Implicit flow returns token in fragment: shirox://auth#access_token=...
        guard let fragment = url.fragment else {
            Logger.shared.log("[AniList] handleCallback: no fragment in URL", type: "Error")
            return
        }
        var params: [String: String] = [:]
        for part in fragment.components(separatedBy: "&") {
            let kv = part.components(separatedBy: "=")
            if kv.count == 2 { params[kv[0]] = kv[1] }
        }
        guard let token = params["access_token"] else {
            Logger.shared.log("[AniList] handleCallback: no access_token in fragment", type: "Error")
            return
        }
        Logger.shared.log("[AniList] got token, fetching viewer", type: "Debug")
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

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return }
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            logout()
            return
        }

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
        if let response = try? JSONDecoder().decode(ViewerResponse.self, from: data),
           let viewer = response.data?.Viewer {
            userId = viewer.id
            username = viewer.name
            avatarURL = viewer.avatar.large
        } else {
            // Token is present but invalid — clear it
            logout()
        }
    }
}

extension AniListAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationAnchorWindow ?? ASPresentationAnchor()
    }
}
