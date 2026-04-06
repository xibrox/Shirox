# AniList Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an AniList OAuth Library tab where users can view and update their anime list across all 6 statuses.

**Architecture:** OAuth implicit flow via `ASWebAuthenticationSession`, token in Keychain, new `AniListAuthManager` + `AniListLibraryService`, `LibraryView` tab inserted second in `ShiroxApp`, edit sheet wired into `AniListDetailView`.

**Tech Stack:** SwiftUI, AuthenticationServices, Security framework (Keychain), AniList GraphQL API.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Shirox/Models/LibraryEntry.swift` | Create | `LibraryEntry` struct + `MediaListStatus` enum |
| `Shirox/Services/AniListAuthManager.swift` | Create | Keychain token, OAuth flow, viewer fetch |
| `Shirox/Services/AniListLibraryService.swift` | Create | GraphQL list fetch + update mutation |
| `Shirox/ViewModels/LibraryViewModel.swift` | Create | Per-status fetch, cache, update |
| `Shirox/Views/Library/LibraryEntryEditSheet.swift` | Create | Status/progress/score editor |
| `Shirox/Views/LibraryView.swift` | Create | Tab root — login prompt or list |
| `Shirox/Views/AniListDetailView.swift` | Modify | Add Edit toolbar button + sheet |
| `Shirox/ShiroxApp.swift` | Modify | Add Library tab + `onOpenURL` handler |
| `Shirox/Info.plist` | Modify | Register `shirox` URL scheme |
| `Shirox.xcodeproj/project.pbxproj` | Modify | Register all new Swift files in both targets |

---

### Task 1: LibraryEntry model + MediaListStatus enum

**Files:**
- Create: `Shirox/Models/LibraryEntry.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

enum MediaListStatus: String, Codable, CaseIterable, Identifiable {
    case current   = "CURRENT"
    case planning  = "PLANNING"
    case completed = "COMPLETED"
    case dropped   = "DROPPED"
    case paused    = "PAUSED"
    case repeating = "REPEATING"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .current:   return "Watching"
        case .planning:  return "Planning"
        case .completed: return "Completed"
        case .dropped:   return "Dropped"
        case .paused:    return "Paused"
        case .repeating: return "Repeating"
        }
    }
}

struct LibraryEntry: Identifiable, Codable {
    let id: Int           // mediaListEntry id (not media id)
    let media: AniListMedia
    var status: MediaListStatus
    var progress: Int     // episodes watched
    var score: Double     // 0–10
}
```

- [ ] **Step 2: Register in project.pbxproj**

Open `Shirox.xcodeproj/project.pbxproj`. Following the exact same pattern as the `VTTSubtitlesLoader.swift` entries (search for `AA000001000000000000BB02`), add:

In the `PBXBuildFile` section:
```
AA000001000000000000AA60 /* LibraryEntry.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB60 /* LibraryEntry.swift */; };
AA000001000000000000AA61 /* LibraryEntry.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB60 /* LibraryEntry.swift */; };
```

In the `PBXFileReference` section:
```
AA000001000000000000BB60 /* LibraryEntry.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LibraryEntry.swift; sourceTree = "<group>"; };
```

Find the group that contains `AniListMedia.swift` and add:
```
AA000001000000000000BB60 /* LibraryEntry.swift */,
```

Find both `Sources` build phase sections (one per target) that contain `AA000001000000000000AA02 /* SubtitleSettingsManager.swift in Sources */` and add to each:
- iOS target: `AA000001000000000000AA61 /* LibraryEntry.swift in Sources */,`
- macOS target: `AA000001000000000000AA60 /* LibraryEntry.swift in Sources */,`

- [ ] **Step 3: Build to confirm no errors**

In Xcode: Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 4: Commit**

```bash
git add Shirox/Models/LibraryEntry.swift Shirox.xcodeproj/project.pbxproj
git commit -m "feat: add LibraryEntry model and MediaListStatus enum"
```

---

### Task 2: AniListAuthManager — Keychain + OAuth

**Files:**
- Create: `Shirox/Services/AniListAuthManager.swift`

- [ ] **Step 1: Create the file**

```swift
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
        // Delete existing first
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

        do {
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
            struct Data: Decodable {
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
            let data: Data?
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
```

- [ ] **Step 2: Register in project.pbxproj**

Following the same pattern as Task 1 Step 2, add entries with IDs `AA000001000000000000AA62/63` and `AA000001000000000000BB62` for `AniListAuthManager.swift` in `Shirox/Services/`.

In PBXBuildFile section:
```
AA000001000000000000AA62 /* AniListAuthManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB62 /* AniListAuthManager.swift */; };
AA000001000000000000AA63 /* AniListAuthManager.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB62 /* AniListAuthManager.swift */; };
```

In PBXFileReference section:
```
AA000001000000000000BB62 /* AniListAuthManager.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AniListAuthManager.swift; sourceTree = "<group>"; };
```

Add file ref to Services group, add build file refs to both target Sources sections.

- [ ] **Step 3: Add AuthenticationServices to Info.plist URL scheme**

In `Shirox/Info.plist`, add inside the root `<dict>` (after the `UIBackgroundModes` array):

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>shirox</string>
        </array>
        <key>CFBundleURLName</key>
        <string>com.shirox.auth</string>
    </dict>
</array>
```

- [ ] **Step 4: Build to confirm no errors**

Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 5: Commit**

```bash
git add Shirox/Services/AniListAuthManager.swift Shirox/Info.plist Shirox.xcodeproj/project.pbxproj
git commit -m "feat: add AniListAuthManager with Keychain storage and OAuth implicit flow"
```

---

### Task 3: AniListLibraryService — fetch list + update mutation

**Files:**
- Create: `Shirox/Services/AniListLibraryService.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

final class AniListLibraryService {
    static let shared = AniListLibraryService()
    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private init() {}

    // MARK: - Fetch list

    func fetchList(status: MediaListStatus, userId: Int) async throws -> [LibraryEntry] {
        let query = """
        query ($userId: Int, $status: MediaListStatus) {
          MediaListCollection(userId: $userId, type: ANIME, status: $status) {
            lists {
              entries {
                id
                status
                progress
                score
                media {
                  id
                  title { romaji english native }
                  coverImage { large extraLarge }
                  episodes
                  status
                  averageScore
                  genres
                  bannerImage
                  description(asHtml: false)
                  season
                  seasonYear
                }
              }
            }
          }
        }
        """
        let variables: [String: Any] = ["userId": userId, "status": status.rawValue]
        let data = try await post(query: query, variables: variables)

        struct Response: Decodable {
            struct Data: Decodable {
                let MediaListCollection: Collection
            }
            struct Collection: Decodable {
                let lists: [MediaList]
            }
            struct MediaList: Decodable {
                let entries: [RawEntry]
            }
            struct RawEntry: Decodable {
                let id: Int
                let status: MediaListStatus
                let progress: Int
                let score: Double
                let media: AniListMedia
            }
            let data: Data?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.data?.MediaListCollection.lists
            .flatMap(\.entries)
            .map { LibraryEntry(id: $0.id, media: $0.media, status: $0.status, progress: $0.progress, score: $0.score) }
            ?? []
    }

    // MARK: - Update entry

    func updateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double) async throws {
        let mutation = """
        mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $score: Float) {
          SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, score: $score) {
            id
          }
        }
        """
        let variables: [String: Any] = [
            "mediaId": mediaId,
            "status": status.rawValue,
            "progress": progress,
            "score": score
        ]
        _ = try await post(query: mutation, variables: variables)
    }

    // MARK: - Private

    private func post(query: String, variables: [String: Any]) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = AniListAuthManager.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            await AniListAuthManager.shared.logout()
            throw AniListError.httpError(401)
        }
        return data
    }
}
```

- [ ] **Step 2: Register in project.pbxproj**

Add entries with IDs `AA000001000000000000AA64/65` and `AA000001000000000000BB64` for `AniListLibraryService.swift` in `Shirox/Services/`.

In PBXBuildFile section:
```
AA000001000000000000AA64 /* AniListLibraryService.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB64 /* AniListLibraryService.swift */; };
AA000001000000000000AA65 /* AniListLibraryService.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB64 /* AniListLibraryService.swift */; };
```

In PBXFileReference section:
```
AA000001000000000000BB64 /* AniListLibraryService.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AniListLibraryService.swift; sourceTree = "<group>"; };
```

Add to Services group and both target Sources sections.

- [ ] **Step 3: Build to confirm no errors**

Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 4: Commit**

```bash
git add Shirox/Services/AniListLibraryService.swift Shirox.xcodeproj/project.pbxproj
git commit -m "feat: add AniListLibraryService with list fetch and update mutation"
```

---

### Task 4: LibraryViewModel

**Files:**
- Create: `Shirox/ViewModels/LibraryViewModel.swift`

- [ ] **Step 1: Create the file**

```swift
import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryEntry] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedStatus: MediaListStatus = .current

    private var cache: [MediaListStatus: [LibraryEntry]] = [:]

    func load() async {
        guard let userId = AniListAuthManager.shared.userId else {
            // userId not yet fetched — fetch viewer first
            await AniListAuthManager.shared.fetchViewer()
            guard let uid = AniListAuthManager.shared.userId else { return }
            await fetch(status: selectedStatus, userId: uid)
            return
        }
        await fetch(status: selectedStatus, userId: userId)
    }

    func selectStatus(_ status: MediaListStatus) async {
        selectedStatus = status
        if let cached = cache[status] {
            entries = cached
            return
        }
        await load()
    }

    func refresh() async {
        cache[selectedStatus] = nil
        await load()
    }

    func update(entry: LibraryEntry, status: MediaListStatus, progress: Int, score: Double) async {
        do {
            try await AniListLibraryService.shared.updateEntry(
                mediaId: entry.media.id,
                status: status,
                progress: progress,
                score: score
            )
            // Invalidate cache for old and new status
            cache[entry.status] = nil
            cache[status] = nil
            // Refresh current view
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fetch(status: MediaListStatus, userId: Int) async {
        isLoading = true
        error = nil
        do {
            let result = try await AniListLibraryService.shared.fetchList(status: status, userId: userId)
            cache[status] = result
            entries = result
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
```

- [ ] **Step 2: Register in project.pbxproj**

Add entries with IDs `AA000001000000000000AA66/67` and `AA000001000000000000BB66` for `LibraryViewModel.swift` in `Shirox/ViewModels/`.

In PBXBuildFile section:
```
AA000001000000000000AA66 /* LibraryViewModel.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB66 /* LibraryViewModel.swift */; };
AA000001000000000000AA67 /* LibraryViewModel.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB66 /* LibraryViewModel.swift */; };
```

In PBXFileReference section:
```
AA000001000000000000BB66 /* LibraryViewModel.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LibraryViewModel.swift; sourceTree = "<group>"; };
```

Add to ViewModels group and both target Sources sections.

- [ ] **Step 3: Build to confirm no errors**

Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 4: Commit**

```bash
git add Shirox/ViewModels/LibraryViewModel.swift Shirox.xcodeproj/project.pbxproj
git commit -m "feat: add LibraryViewModel with per-status cache"
```

---

### Task 5: LibraryEntryEditSheet

**Files:**
- Create: `Shirox/Views/Library/LibraryEntryEditSheet.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct LibraryEntryEditSheet: View {
    let entry: LibraryEntry?         // nil = adding new (not in library yet)
    let media: AniListMedia
    let onSave: (MediaListStatus, Int, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: MediaListStatus
    @State private var progress: Int
    @State private var score: Double

    init(entry: LibraryEntry?, media: AniListMedia, onSave: @escaping (MediaListStatus, Int, Double) -> Void) {
        self.entry = entry
        self.media = media
        self.onSave = onSave
        _status = State(initialValue: entry?.status ?? .planning)
        _progress = State(initialValue: entry?.progress ?? 0)
        _score = State(initialValue: entry?.score ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(MediaListStatus.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Progress") {
                    Stepper(
                        "\(progress) episode\(progress == 1 ? "" : "s") watched",
                        value: $progress,
                        in: 0...(media.episodes ?? 9999)
                    )
                    if let total = media.episodes {
                        Text("of \(total) total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Score") {
                    HStack {
                        Slider(value: $score, in: 0...10, step: 0.5)
                        Text(score == 0 ? "—" : String(format: "%.1f", score))
                            .monospacedDigit()
                            .frame(width: 36)
                    }
                }
            }
            .navigationTitle(entry == nil ? "Add to Library" : "Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(status, progress, score)
                        dismiss()
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Register in project.pbxproj**

Add entries with IDs `AA000001000000000000AA68/69` and `AA000001000000000000BB68` for `LibraryEntryEditSheet.swift` in `Shirox/Views/Library/`.

Note: the `path` in PBXFileReference uses only the filename; the group hierarchy controls the folder. Find the group containing `AniListDetailView.swift` and add a new child group for `Library/` or just add the file ref directly to the Views group.

In PBXBuildFile section:
```
AA000001000000000000AA68 /* LibraryEntryEditSheet.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB68 /* LibraryEntryEditSheet.swift */; };
AA000001000000000000AA69 /* LibraryEntryEditSheet.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB68 /* LibraryEntryEditSheet.swift */; };
```

In PBXFileReference section:
```
AA000001000000000000BB68 /* LibraryEntryEditSheet.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LibraryEntryEditSheet.swift; sourceTree = "<group>"; };
```

Add to Views group and both target Sources sections.

- [ ] **Step 3: Build to confirm no errors**

Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 4: Commit**

```bash
git add Shirox/Views/Library/LibraryEntryEditSheet.swift Shirox.xcodeproj/project.pbxproj
git commit -m "feat: add LibraryEntryEditSheet for status/progress/score editing"
```

---

### Task 6: LibraryView

**Files:**
- Create: `Shirox/Views/LibraryView.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct LibraryView: View {
    @StateObject private var vm = LibraryViewModel()
    @ObservedObject private var auth = AniListAuthManager.shared
    @State private var showLogoutAlert = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isLoggedIn {
                    loginPrompt
                } else {
                    libraryContent
                }
            }
            .navigationTitle("Library")
            .toolbar {
                if auth.isLoggedIn, let name = auth.username {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showLogoutAlert = true
                        } label: {
                            HStack(spacing: 6) {
                                if let urlStr = auth.avatarURL, let url = URL(string: urlStr) {
                                    AsyncImage(url: url) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        Circle().fill(Color.secondary.opacity(0.3))
                                    }
                                    .frame(width: 28, height: 28)
                                    .clipShape(Circle())
                                }
                                Text(name)
                                    .font(.subheadline)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .alert("Log out?", isPresented: $showLogoutAlert) {
                Button("Log out", role: .destructive) { auth.logout() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Login prompt

    private var loginPrompt: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Track your anime with AniList")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Sign in to view and manage your anime library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task {
                    #if os(iOS)
                    let anchor = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .flatMap { $0.windows }
                        .first { $0.isKeyWindow } ?? UIWindow()
                    await auth.login(presentationAnchor: anchor)
                    #endif
                }
            } label: {
                Text("Sign in with AniList")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.red, in: Capsule())
                    .padding(.horizontal, 40)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Library content

    private var libraryContent: some View {
        VStack(spacing: 0) {
            // Status filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MediaListStatus.allCases) { status in
                        Button {
                            Task { await vm.selectStatus(status) }
                        } label: {
                            Text(status.displayName)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    vm.selectedStatus == status
                                        ? Color.red
                                        : Color.secondary.opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(vm.selectedStatus == status ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if vm.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = vm.error {
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "wifi.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await vm.refresh() } }
                }
            } else if vm.entries.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "tray",
                    description: Text("Add anime to \(vm.selectedStatus.displayName) on AniList.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(vm.entries) { entry in
                            NavigationLink(destination: AniListDetailView(
                                mediaId: entry.media.id,
                                preloadedMedia: entry.media
                            )) {
                                LibraryCardView(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
                .refreshable { await vm.refresh() }
            }
        }
        .task { await vm.load() }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            if loggedIn { Task { await vm.load() } }
        }
    }
}

// MARK: - Library card

private struct LibraryCardView: View {
    let entry: LibraryEntry

    var body: some View {
        let imageURL = URL(string: entry.media.coverImage.best ?? "")
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                ZStack(alignment: .bottom) {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                        default:
                            Rectangle()
                                .fill(Color.secondary.opacity(0.15))
                                .overlay(ProgressView())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.85)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.media.title.displayTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(progressLabel)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
    }

    private var progressLabel: String {
        if let total = entry.media.episodes {
            return "\(entry.progress) / \(total) ep"
        }
        return "\(entry.progress) ep watched"
    }
}
```

- [ ] **Step 2: Register in project.pbxproj**

Add entries with IDs `AA000001000000000000AA70/71` and `AA000001000000000000BB70` for `LibraryView.swift`.

In PBXBuildFile section:
```
AA000001000000000000AA70 /* LibraryView.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB70 /* LibraryView.swift */; };
AA000001000000000000AA71 /* LibraryView.swift in Sources */ = {isa = PBXBuildFile; fileRef = AA000001000000000000BB70 /* LibraryView.swift */; };
```

In PBXFileReference section:
```
AA000001000000000000BB70 /* LibraryView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LibraryView.swift; sourceTree = "<group>"; };
```

Add to Views group and both target Sources sections.

- [ ] **Step 3: Build to confirm no errors**

Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 4: Commit**

```bash
git add Shirox/Views/LibraryView.swift Shirox.xcodeproj/project.pbxproj
git commit -m "feat: add LibraryView with login prompt, status filter chips, and grid"
```

---

### Task 7: Wire Library tab into ShiroxApp + URL scheme handler

**Files:**
- Modify: `Shirox/ShiroxApp.swift`

- [ ] **Step 1: Update ShiroxApp.swift**

Replace the entire `var body: some Scene` block with:

```swift
var body: some Scene {
    WindowGroup {
        if #available(iOS 18, *) {
            TabView {
                Tab("Home", systemImage: "house.fill") {
                    HomeView()
                }
                Tab("Library", systemImage: "books.vertical.fill") {
                    LibraryView()
                }
                Tab("Settings", systemImage: "gearshape.fill") {
                    SettingsView()
                }
                Tab(role: .search) {
                    SearchView()
                }
            }
            .tint(.red)
            .environmentObject(moduleManager)
            .onOpenURL { url in
                guard url.scheme == "shirox" else { return }
                AniListAuthManager.shared.handleCallback(url: url)
            }
            .task {
                await moduleManager.restoreActiveModule()
                await moduleManager.checkForUpdates()
                if AniListAuthManager.shared.isLoggedIn {
                    await AniListAuthManager.shared.fetchViewer()
                }
            }
        } else {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                LibraryView()
                    .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
            }
            .tint(.red)
            .environmentObject(moduleManager)
            .onOpenURL { url in
                guard url.scheme == "shirox" else { return }
                AniListAuthManager.shared.handleCallback(url: url)
            }
            .task {
                await moduleManager.restoreActiveModule()
                await moduleManager.checkForUpdates()
                if AniListAuthManager.shared.isLoggedIn {
                    await AniListAuthManager.shared.fetchViewer()
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build to confirm no errors**

Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 3: Commit**

```bash
git add Shirox/ShiroxApp.swift
git commit -m "feat: add Library tab and onOpenURL handler for AniList OAuth callback"
```

---

### Task 8: Edit button in AniListDetailView

**Files:**
- Modify: `Shirox/Views/AniListDetailView.swift`

- [ ] **Step 1: Add state and sheet**

At the top of `AniListDetailView`, after the existing `@State private var showResetConfirmation = false` line, add:

```swift
@State private var showLibraryEdit = false
@ObservedObject private var auth = AniListAuthManager.shared
@StateObject private var libraryVM = LibraryViewModel()
```

- [ ] **Step 2: Add toolbar Edit button**

Find the `.task { ... }` modifier on the root `Group`. Add a `.toolbar` modifier after the `#if os(iOS)` block (around line 50–55):

```swift
.toolbar {
    if auth.isLoggedIn {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showLibraryEdit = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 17, weight: .medium))
            }
        }
    }
}
```

- [ ] **Step 3: Add sheet presentation**

After the last existing `.sheet(isPresented: $vm.showFinalStreamPicker ...)` block, add:

```swift
.sheet(isPresented: $showLibraryEdit) {
    if let media = vm.media {
        let existingEntry = libraryVM.entries.first { $0.media.id == media.id }
        LibraryEntryEditSheet(entry: existingEntry, media: media) { status, progress, score in
            Task {
                if let existing = existingEntry {
                    await libraryVM.update(entry: existing, status: status, progress: progress, score: score)
                } else {
                    try? await AniListLibraryService.shared.updateEntry(
                        mediaId: media.id, status: status, progress: progress, score: score
                    )
                }
            }
        }
    }
}
.task(id: showLibraryEdit) {
    if showLibraryEdit, let media = vm.media, auth.isLoggedIn {
        await libraryVM.selectStatus(libraryVM.selectedStatus)
    }
}
```

- [ ] **Step 4: Build to confirm no errors**

Product → Build (⌘B). Expected: Build Succeeded.

- [ ] **Step 5: Commit**

```bash
git add Shirox/Views/AniListDetailView.swift
git commit -m "feat: add Edit library button to AniListDetailView"
```

---

### Task 9: Get AniList client ID and test end-to-end

**Files:**
- Modify: `Shirox/Services/AniListAuthManager.swift` (replace placeholder client ID)

- [ ] **Step 1: Create AniList API client**

1. Go to `https://anilist.co/settings/developer`
2. Click "Create new client"
3. Set Name: `Shirox`
4. Set Redirect URI: `shirox://auth`
5. Copy the **Client ID** (numbers only — implicit flow does not need a secret)

- [ ] **Step 2: Set client ID**

In `Shirox/Services/AniListAuthManager.swift`, replace:
```swift
private let clientId = "YOUR_ANILIST_CLIENT_ID"
```
with the actual numeric ID, e.g.:
```swift
private let clientId = "12345"
```

- [ ] **Step 3: Test on device**

1. Build and run on a real iPhone
2. Tap Library tab → "Sign in with AniList" button
3. Safari/ASWebAuthenticationSession opens AniList login
4. Log in and authorize → app returns to Library tab
5. Avatar + username appear in toolbar
6. Watching list loads
7. Tap a status chip → list updates
8. Pull to refresh → list reloads
9. Tap an anime → AniListDetailView shows ➕ button
10. Tap ➕ → edit sheet opens, change status/progress/score, tap Save
11. Return to Library → entry reflects changes

- [ ] **Step 4: Commit**

```bash
git add Shirox/Services/AniListAuthManager.swift
git commit -m "feat: set AniList client ID for OAuth"
```
