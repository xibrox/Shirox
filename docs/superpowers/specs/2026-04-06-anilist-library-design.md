# AniList Library Implementation Design

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an AniList-authenticated Library tab where users can view and update their anime list across all 6 statuses.

**Architecture:** OAuth implicit flow via `ASWebAuthenticationSession`, token stored in Keychain, GraphQL queries/mutations via a new `AniListLibraryService`, new `LibraryView` tab with `LibraryViewModel`.

**Tech Stack:** SwiftUI, AuthenticationServices, Security (Keychain), AniList GraphQL API, existing `AniListService` patterns.

---

## Files

### New Files
- `Shirox/Services/AniListAuthManager.swift` — Keychain token storage + OAuth flow
- `Shirox/Services/AniListLibraryService.swift` — GraphQL list fetch + update mutation
- `Shirox/Models/LibraryEntry.swift` — `AniListMedia` + progress/score/status wrapper
- `Shirox/ViewModels/LibraryViewModel.swift` — `@MainActor ObservableObject`, per-status fetch + cache
- `Shirox/Views/LibraryView.swift` — tab root: logged-out login prompt or logged-in list
- `Shirox/Views/Library/LibraryEntryEditSheet.swift` — status/progress/score editor sheet

### Modified Files
- `Shirox/ShiroxApp.swift` — add Library tab (second position), register `shirox://` URL scheme handler
- `Shirox/Views/AniListDetailView.swift` — add Edit button → `LibraryEntryEditSheet`
- `Shirox/Info.plist` — add `shirox` URL scheme

---

## Models

### `LibraryEntry`
```swift
struct LibraryEntry: Identifiable, Codable {
    let id: Int           // mediaListEntry id from AniList
    let media: AniListMedia
    var status: MediaListStatus
    var progress: Int     // episodes watched
    var score: Double     // 0–10
}

enum MediaListStatus: String, Codable, CaseIterable {
    case current   = "CURRENT"    // Watching
    case planning  = "PLANNING"
    case completed = "COMPLETED"
    case dropped   = "DROPPED"
    case paused    = "PAUSED"
    case repeating = "REPEATING"

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
```

---

## AniListAuthManager

- Singleton `@MainActor final class`
- `@Published var isLoggedIn: Bool` — derived from token presence
- `@Published var username: String?`, `@Published var avatarURL: String?`
- `func login(presentationAnchor:) async` — starts `ASWebAuthenticationSession` with:
  - URL: `https://anilist.co/api/v2/oauth/authorize?client_id=<ID>&response_type=token`
  - Callback scheme: `shirox`
  - Parses fragment `#access_token=...&expires_in=...` from redirect URL
  - Saves token to Keychain under key `"anilist_access_token"`
- `func logout()` — deletes Keychain entry, clears published state
- `var accessToken: String?` — reads from Keychain
- `@Published var userId: Int?` — set after `fetchViewer()`
- `func fetchViewer() async` — GraphQL `Viewer` query to get `id`, `name`, `avatar.large` — called after login, stores `userId`

**Keychain wrapper:** simple private helper using `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete` with `kSecClassGenericPassword`.

**AniList OAuth app:** User must create an AniList API client at `https://anilist.co/settings/developer` with redirect URI `shirox://auth`. The `client_id` is stored as a constant in `AniListAuthManager`.

---

## AniListLibraryService

Follows same pattern as `AniListService` (GraphQL POST to `https://graphql.anilist.co`).

### `fetchList(status: MediaListStatus, userId: Int) async throws -> [LibraryEntry]`
Query: `MediaListCollection(userId:, type: ANIME, status:)` → `lists[].entries[]` with:
```graphql
id
status
progress
score
media {
  id
  title { romaji english }
  coverImage { large extraLarge }
  episodes
}
```

### `updateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double) async throws`
Mutation: `SaveMediaListEntry(mediaId:, status:, progress:, score:)` — uses `score` as a Float (AniList stores 0–10 with decimals).

Both methods add `Authorization: Bearer <token>` header from `AniListAuthManager.shared.accessToken`.

---

## LibraryViewModel

```swift
@MainActor final class LibraryViewModel: ObservableObject {
    @Published var entries: [LibraryEntry] = []
    @Published var isLoading = false
    @Published var error: String? = nil
    @Published var selectedStatus: MediaListStatus = .current

    func load() async  // fetches for selectedStatus + AniListAuthManager.shared.userId
    func refresh() async  // re-fetch, clears cache for current status
    func update(entry: LibraryEntry) async  // calls updateEntry mutation, updates local list
}
```

Caches results per status in a `[MediaListStatus: [LibraryEntry]]` dict to avoid refetching on tab switch.

---

## LibraryView

**Logged-out state:**
```
[AniList logo]
"Track your anime with AniList"
[Sign in with AniList] button (red, pill shape)
```

**Logged-in state:**
- `NavigationStack`
- Title: "Library"
- Top-right: avatar circle + username → tap shows logout confirmation alert
- Below nav: horizontal `ScrollView` of filter chips for all 6 statuses
- Content: `LazyVGrid` 2 columns, each cell = cover image + title + progress badge ("12 / 24 ep" or "? ep" if unknown)
- Tapping a cell → `AniListDetailView(mediaId:)` (existing)
- Pull to refresh → `refresh()`
- Empty state per status: icon + "Nothing here yet"
- Error state: message + Retry button

---

## LibraryEntryEditSheet

Presented as `.sheet` from `AniListDetailView` top-right Edit button (only shown when logged in).

Contents:
- **Status** — `Picker` with all 6 `MediaListStatus` values (menu style)
- **Progress** — `Stepper("X episodes watched", value: $progress, in: 0...(media.episodes ?? 9999))`
- **Score** — `Slider(value: $score, in: 0...10, step: 0.5)` + `Text("\(score, specifier: "%.1f")")`
- **Save** button — calls `LibraryViewModel.shared`-style update or passed-in closure, dismisses
- **Cancel** button

---

## ShiroxApp Changes

- Add Library tab second (after Home): `books.vertical.fill` icon, label "Library"
- iOS 18+ `Tab("Library", systemImage: "books.vertical.fill") { LibraryView() }`
- iOS 17 fallback: `.tabItem { Label("Library", systemImage: "books.vertical.fill") }`
- Register URL scheme `shirox` in `Info.plist` under `CFBundleURLTypes`
- Handle incoming URL in `onOpenURL` modifier on root `TabView` → pass to `AniListAuthManager.shared.handleCallback(url:)`

---

## AniListDetailView Changes

- Inject `@StateObject` or `@EnvironmentObject` access to `AniListAuthManager`
- If `isLoggedIn`: show Edit button (top-right toolbar) → present `LibraryEntryEditSheet`
- Pass current `LibraryEntry` if found in library, else pass nil (sheet handles both add-new and edit)

---

## Error Handling

- Token expired (401 from API) → `AniListAuthManager.logout()` + show login prompt
- Network errors → surface in `LibraryViewModel.error`, shown in view
- Rate limit (429) → same `AniListError.rateLimited` path as existing service

---

## Out of Scope

- Manga lists
- Notifications
- Social features (followers, activities)
- Offline caching beyond in-session dict
