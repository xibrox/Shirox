import Foundation
import Security
#if os(iOS)
import UIKit
#endif

enum JellyfinAuthError: Error, LocalizedError {
    case invalidURL, unreachable, badCredentials, server(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a valid server address."
        case .unreachable: return "Couldn't reach the server. Check the address and your network."
        case .badCredentials: return "Wrong username or password."
        case .server(let code): return "Server error (\(code))."
        }
    }
}

@MainActor
final class JellyfinAuthManager: ObservableObject {
    static let shared = JellyfinAuthManager()

    @Published private(set) var isAuthenticated = false
    @Published private(set) var serverName: String?

    private enum Keys {
        static let serverURL = "jellyfin_server_url"
        static let serverName = "jellyfin_server_name"
        static let deviceId = "jellyfin_device_id"
        static let tokenAccount = "jellyfin_access_token"
        static let userIdAccount = "jellyfin_user_id"
    }

    let deviceId: String

    private init() {
        if let existing = UserDefaults.standard.string(forKey: Keys.deviceId) {
            deviceId = existing
        } else {
            let new = UUID().uuidString
            UserDefaults.standard.set(new, forKey: Keys.deviceId)
            deviceId = new
        }
        serverName = UserDefaults.standard.string(forKey: Keys.serverName)
        isAuthenticated = JellyfinKeychain.read(Keys.tokenAccount) != nil
            && UserDefaults.standard.string(forKey: Keys.serverURL) != nil
    }

    // MARK: - Stored values

    var serverURL: URL? {
        UserDefaults.standard.string(forKey: Keys.serverURL).flatMap(URL.init(string:))
    }
    var accessToken: String? { JellyfinKeychain.read(Keys.tokenAccount) }
    var userId: String? { JellyfinKeychain.read(Keys.userIdAccount) }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
    static var deviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Shirox"
        #endif
    }

    func authorizationHeader(token: String? = nil) -> String {
        JellyfinAuthHeader.value(client: "Shirox", device: Self.deviceName,
                                 deviceId: deviceId, version: Self.appVersion,
                                 token: token ?? accessToken)
    }

    // MARK: - Pure helper

    nonisolated static func normalizeServerURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    // MARK: - Auth

    func authenticate(serverURL raw: String, username: String, password: String) async throws {
        guard let base = Self.normalizeServerURL(raw) else { throw JellyfinAuthError.invalidURL }
        var req = URLRequest(url: base.appendingPathComponent("Users/AuthenticateByName"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authorizationHeader(token: nil), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw JellyfinAuthError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw JellyfinAuthError.unreachable }
        if http.statusCode == 401 { throw JellyfinAuthError.badCredentials }
        guard http.statusCode == 200 else { throw JellyfinAuthError.server(http.statusCode) }

        let result = try JSONDecoder().decode(JellyfinAuthResult.self, from: data)
        JellyfinKeychain.save(result.accessToken, account: Keys.tokenAccount)
        JellyfinKeychain.save(result.userId, account: Keys.userIdAccount)
        UserDefaults.standard.set(base.absoluteString, forKey: Keys.serverURL)
        let name = base.host ?? result.userName
        UserDefaults.standard.set(name, forKey: Keys.serverName)
        serverName = name
        isAuthenticated = true
    }

    func logout() {
        JellyfinKeychain.delete(Keys.tokenAccount)
        JellyfinKeychain.delete(Keys.userIdAccount)
        UserDefaults.standard.removeObject(forKey: Keys.serverURL)
        UserDefaults.standard.removeObject(forKey: Keys.serverName)
        serverName = nil
        isAuthenticated = false
    }
}

// MARK: - Keychain (generic password, mirrors AniListAuthManager)

private enum JellyfinKeychain {
    static func read(_ account: String) -> String? {
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

    static func save(_ value: String, account: String) {
        delete(account)
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: account
        ] as CFDictionary)
    }
}
