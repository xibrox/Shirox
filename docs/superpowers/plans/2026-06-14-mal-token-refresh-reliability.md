# MAL Token Refresh & Reliable Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make MyAnimeList tracking reliable by automatically refreshing expired OAuth access tokens, so progress keeps syncing without manual re-login.

**Architecture:** Centralize all authenticated MAL requests through a single `send(...)` method on `MALAuthManager` that (a) proactively refreshes the token before expiry, (b) reactively refreshes once on a 401 and retries, and (c) serializes concurrent refreshes through one in-flight task. Token expiry is derived from the OAuth `expires_in` field and persisted in UserDefaults. Remaining silent `try?` MAL write sites get do/catch logging.

**Tech Stack:** Swift, async/await, URLSession, Security (Keychain), Combine (`@MainActor ObservableObject`).

**Note on testing:** This project has **no unit-test target**. The verification gate for each code task is a successful iOS build, plus a final manual smoke test. Build command used throughout:

```
xcodebuild -project Shirox.xcodeproj -scheme Shirox_iOS -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

---

### Task 1: Persist token expiry in MALAuthManager

**Files:**
- Modify: `Shirox/Services/MALAuthManager.swift`

- [ ] **Step 1: Add the expiry storage key**

In `Shirox/Services/MALAuthManager.swift`, find the existing key declarations (around lines 19-21):

```swift
    private let accessTokenKey = "mal_access_token"
    private let refreshTokenKey = "mal_refresh_token"
    private let profileKey = "mal_user_profile"
```

Add a new key right after `profileKey`:

```swift
    private let accessTokenKey = "mal_access_token"
    private let refreshTokenKey = "mal_refresh_token"
    private let profileKey = "mal_user_profile"
    private let tokenExpiryKey = "mal_token_expiry"
```

- [ ] **Step 2: Add expiry read/write helpers**

Immediately after the `keychainDelete(key:)` method (ends around line 71, before `// MARK: - PKCE`), add:

```swift
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
```

- [ ] **Step 3: Decode and store `expires_in` on initial token exchange**

In `exchangeCode(_:verifier:)` (around lines 142-147), update the `TokenResponse` struct and store the expiry:

```swift
        let (data, _) = try await URLSession.shared.data(for: request)
        struct TokenResponse: Decodable { let access_token: String; let refresh_token: String; let expires_in: Int }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        keychainWrite(key: accessTokenKey, value: tokens.access_token)
        keychainWrite(key: refreshTokenKey, value: tokens.refresh_token)
        storeTokenExpiry(expiresIn: tokens.expires_in)
        isLoggedIn = true
```

- [ ] **Step 4: Clear expiry on logout**

In `logout()` (around lines 180-188), add the expiry removal alongside the profile removal:

```swift
    func logout() {
        keychainDelete(key: accessTokenKey)
        keychainDelete(key: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: tokenExpiryKey)
        isLoggedIn = false
        username = nil
        avatarURL = nil
        userId = nil
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run the build command above.
Expected: **BUILD SUCCEEDED** (the macOS scheme has a known pre-existing failure; use the iOS scheme).

- [ ] **Step 6: Commit**

```bash
git add Shirox/Services/MALAuthManager.swift
git commit -m "feat(mal): persist access-token expiry from expires_in"
```

---

### Task 2: Harden refreshAccessToken (detect dead refresh token)

**Files:**
- Modify: `Shirox/Services/MALAuthManager.swift`

- [ ] **Step 1: Add an auth error type**

At the top of `Shirox/Services/MALAuthManager.swift`, after the `import` lines (before `@MainActor final class MALAuthManager`), add:

```swift
enum MALAuthError: Error {
    /// The refresh-token grant failed (e.g. invalid_grant). Caller should sign out.
    case refreshFailed(status: Int)
}
```

- [ ] **Step 2: Validate the refresh response and store the new expiry**

Replace the body of `refreshAccessToken()` (around lines 150-163) with:

```swift
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
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 4: Commit**

```bash
git add Shirox/Services/MALAuthManager.swift
git commit -m "feat(mal): validate refresh response and surface dead refresh token"
```

---

### Task 3: Add the authenticated send() choke point

**Files:**
- Modify: `Shirox/Services/MALAuthManager.swift`

- [ ] **Step 1: Add a URLSession and the refresh coordination task**

In `Shirox/Services/MALAuthManager.swift`, find the stored properties near the top of the class (after `nonisolated(unsafe) var presentationAnchorWindow: ASPresentationAnchor?`, around line 24) and add:

```swift
    nonisolated(unsafe) var presentationAnchorWindow: ASPresentationAnchor?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()
    private var refreshTask: Task<Void, Error>?
```

- [ ] **Step 2: Add the refresh-coordination and send methods**

Replace the existing `authorizedRequest(url:method:)` method (around lines 190-196) with the version below **plus** the new helpers (keep `authorizedRequest` — `send` builds on it):

```swift
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
                logout()
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
```

- [ ] **Step 3: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 4: Commit**

```bash
git add Shirox/Services/MALAuthManager.swift
git commit -m "feat(mal): add send() with proactive + reactive token refresh"
```

---

### Task 4: Route MALLibraryService through send()

**Files:**
- Modify: `Shirox/Services/MALLibraryService.swift`

- [ ] **Step 1: Route fetchLibrary through send()**

In `fetchLibrary()` (around lines 66-78), replace the per-page request/response with `send`:

```swift
    func fetchLibrary() async throws -> [MALListEntry] {
        var allEntries: [MALListEntry] = []
        var nextURL: URL? = makeLibraryURL()
        while let url = nextURL {
            let (data, response) = try await MALAuthManager.shared.send(url: url)
            try validateResponse(response)
            let page = try JSONDecoder().decode(MALListPage.self, from: data)
            allEntries.append(contentsOf: page.data)
            nextURL = page.paging?.next.flatMap { URL(string: $0) }
        }
        return allEntries
    }
```

- [ ] **Step 2: Route fetchEntry through send()**

In `fetchEntry(malId:)` (around lines 93-100), replace the request/response lines:

```swift
        let (data, response) = try await MALAuthManager.shared.send(url: components.url!)
        if response.statusCode == 404 { return nil }
        try validateResponse(response)
```

(Leave the rest of the method — `NodeWithStatus` decoding and mapping — unchanged.)

- [ ] **Step 3: Route updateEntry through send()**

Replace the body of `updateEntry(malId:status:progress:score:numTimesRewatched:)` (around lines 120-131):

```swift
    func updateEntry(malId: Int, status: MediaListStatus, progress: Int, score: Double, numTimesRewatched: Int? = nil) async throws {
        let url = base.appendingPathComponent("anime/\(malId)/my_list_status")
        let malStatus = mapStatusToMAL(status)
        let scoreInt = Int(score)
        var bodyString = "status=\(malStatus)&num_watched_episodes=\(progress)&score=\(scoreInt)"
        if let numTimesRewatched { bodyString += "&num_times_rewatched=\(numTimesRewatched)" }
        let (_, response) = try await MALAuthManager.shared.send(
            url: url, method: "PATCH",
            body: bodyString.data(using: .utf8),
            contentType: "application/x-www-form-urlencoded")
        try validateResponse(response)
    }
```

- [ ] **Step 4: Route deleteEntry through send()**

Replace the body of `deleteEntry(malId:)` (around lines 133-138):

```swift
    func deleteEntry(malId: Int) async throws {
        let url = base.appendingPathComponent("anime/\(malId)/my_list_status")
        let (_, response) = try await MALAuthManager.shared.send(url: url, method: "DELETE")
        try validateResponse(response)
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 6: Commit**

```bash
git add Shirox/Services/MALLibraryService.swift
git commit -m "feat(mal): route library calls through refreshing send()"
```

---

### Task 5: Route MALSocialService.fetchCurrentUserProfile through send()

**Files:**
- Modify: `Shirox/Services/MALSocialService.swift`

- [ ] **Step 1: Replace the request/response lines**

In `fetchCurrentUserProfile()` (around lines 16-24), replace:

```swift
        let request = try await MALAuthManager.shared.authorizedRequest(url: components.url!)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw ProviderError.unauthenticated
        }
```

with:

```swift
        let (data, response) = try await MALAuthManager.shared.send(url: components.url!)
        if response.statusCode == 401 {
            throw ProviderError.unauthenticated
        }
```

(The `response` is now `HTTPURLResponse`, so `.statusCode` is accessed directly. The rest of the method — `MALUser` decoding and mapping — is unchanged. The Jikan-based methods in this file are unauthenticated and must remain untouched.)

- [ ] **Step 2: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Commit**

```bash
git add Shirox/Services/MALSocialService.swift
git commit -m "feat(mal): route current-user profile through refreshing send()"
```

---

### Task 6: Stop silent MAL tracking failures (logging)

**Files:**
- Modify: `Shirox/Services/ContinueWatchingManager.swift`
- Modify: `Shirox/Services/PlayerPresenter.swift`

These sites currently use `try?` and swallow failures. Wrap each in do/catch with a
log. They must stay non-fatal (never throw out of the surrounding closure).

- [ ] **Step 1: Unmark-confirm site in ContinueWatchingManager**

Around lines 459-462, replace:

```swift
                    if let mid = malID, capturedMalLoggedIn {
                        try? await MALProvider.shared.updateEntry(
                            mediaId: mid, status: remoteStatus, progress: capturedProposed, score: 0)
                    }
```

with:

```swift
                    if let mid = malID, capturedMalLoggedIn {
                        do {
                            try await MALProvider.shared.updateEntry(
                                mediaId: mid, status: remoteStatus, progress: capturedProposed, score: 0)
                        } catch {
                            Logger.shared.log("[Tracking] MAL unmark update failed: \(error)", type: "Error")
                        }
                    }
```

- [ ] **Step 2: Single-episode rewatch site**

Around lines 762-764, replace:

```swift
                            try? await MALLibraryService.shared.updateEntry(
                                malId: mid, status: .completed, progress: ep, score: 0,
                                numTimesRewatched: newRepeat)
```

with:

```swift
                            do {
                                try await MALLibraryService.shared.updateEntry(
                                    malId: mid, status: .completed, progress: ep, score: 0,
                                    numTimesRewatched: newRepeat)
                            } catch {
                                Logger.shared.log("[Tracking] MAL single-ep rewatch update failed: \(error)", type: "Error")
                            }
```

- [ ] **Step 3: Multi-episode rewatch site**

Around lines 767-768, replace:

```swift
                            try? await MALLibraryService.shared.updateEntry(
                                malId: mid, status: .repeating, progress: ep, score: 0)
```

with:

```swift
                            do {
                                try await MALLibraryService.shared.updateEntry(
                                    malId: mid, status: .repeating, progress: ep, score: 0)
                            } catch {
                                Logger.shared.log("[Tracking] MAL rewatch update failed: \(error)", type: "Error")
                            }
```

- [ ] **Step 4: Entry-not-found fallback site**

Around lines 781-784, replace:

```swift
                } else {
                    try? await MALProvider.shared.updateEntry(
                        mediaId: mid, status: targetStatus, progress: ep, score: 0)
                }
```

with:

```swift
                } else {
                    do {
                        try await MALProvider.shared.updateEntry(
                            mediaId: mid, status: targetStatus, progress: ep, score: 0)
                        Logger.shared.log("[Tracking] MAL progress updated (new entry): ep \(ep), malId \(mid)", type: "Info")
                    } catch {
                        Logger.shared.log("[Tracking] MAL new-entry update failed: \(error)", type: "Error")
                    }
                }
```

- [ ] **Step 5: Rating-submit site in PlayerPresenter**

In `Shirox/Services/PlayerPresenter.swift`, `submitRating(_:for:)` around lines 201-204, replace:

```swift
            if let mid = context.malID, MALAuthManager.shared.isLoggedIn,
               let entry = try? await MALProvider.shared.fetchEntry(mediaId: mid) {
                try? await MALProvider.shared.updateEntry(mediaId: mid, status: entry.status, progress: entry.progress, score: score)
            }
```

with:

```swift
            if let mid = context.malID, MALAuthManager.shared.isLoggedIn,
               let entry = try? await MALProvider.shared.fetchEntry(mediaId: mid) {
                do {
                    try await MALProvider.shared.updateEntry(mediaId: mid, status: entry.status, progress: entry.progress, score: score)
                } catch {
                    Logger.shared.log("[Rating] MAL score update failed: \(error)", type: "Error")
                }
            }
```

- [ ] **Step 6: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 7: Commit**

```bash
git add Shirox/Services/ContinueWatchingManager.swift Shirox/Services/PlayerPresenter.swift
git commit -m "feat(mal): log previously-silent tracking write failures"
```

---

### Task 7: Manual smoke test

**Files:** none (verification only)

- [ ] **Step 1: Force token expiry**

With the app signed into MAL, simulate an expired token by setting a past expiry.
In the running app's debugger console (LLDB) or a temporary debug action, run the
equivalent of:

```swift
UserDefaults.standard.set(Date().addingTimeInterval(-60).timeIntervalSince1970, forKey: "mal_token_expiry")
```

(Alternatively, wait until natural expiry, or temporarily lower the proactive margin
in `refreshIfNeeded` while testing.)

- [ ] **Step 2: Trigger an authenticated MAL call**

Open an anime detail screen and edit its MAL library entry (change status or progress),
or mark an episode watched while signed into MAL.

- [ ] **Step 3: Confirm the expected behavior**

Expected:
- The edit/mark **succeeds** (a proactive refresh ran before the request).
- The in-app Logger shows a successful update, **not** a swallowed 401.
- Re-opening the detail screen reflects the new progress/status from MAL.

- [ ] **Step 4: Confirm dead-refresh-token fallback (optional)**

If you can revoke the app's access at https://myanimelist.net/apiconfig, confirm that
after revocation an authenticated call results in a clean signed-out state (the MAL
sign-in prompt reappears) rather than a silent failure loop.

---

## Self-Review Notes

- **Spec coverage:** Token expiry tracking → Task 1; harden refresh / invalid_grant → Tasks 2 & 3 (`performRefresh` logout); single send() choke point with proactive + reactive refresh + concurrency guard → Task 3; route the 5 authenticated call sites → Tasks 4 (library: fetchLibrary, fetchEntry, updateEntry, deleteEntry) & 5 (fetchCurrentUserProfile); stop silent failures → Task 6; testing/verification → Task 7 plus per-task builds.
- **Type consistency:** `send(url:method:body:contentType:) -> (Data, HTTPURLResponse)`, `refreshIfNeeded(force:)`, `performRefresh()`, `storeTokenExpiry(expiresIn:)`, `tokenExpiry`, and `MALAuthError.refreshFailed(status:)` are used consistently across tasks.
- **Jikan untouched:** Discovery and the Jikan-based social reads remain unauthenticated, as required by the spec.
