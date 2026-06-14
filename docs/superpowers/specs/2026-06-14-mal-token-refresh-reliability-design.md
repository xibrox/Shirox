# MAL Token Refresh & Reliable Tracking — Design

**Date:** 2026-06-14
**Project:** 1 of 3 in the "bring MyAnimeList to parity with AniList" effort
**Status:** Approved (pending spec review)

## Problem

MyAnimeList tracking "sometimes" stops working. Once it breaks, progress no longer
syncs to MAL until the user manually logs out and back in.

### Root cause

MAL access tokens expire, but the app never refreshes them.

- `MALAuthManager.refreshAccessToken()` exists but is **never called anywhere**.
- `MALAuthManager.authorizedRequest(url:method:)` simply attaches whatever access
  token is currently in the keychain — no expiry check, no refresh.
- Token expiry (`expires_in` from the OAuth token response) is never stored, so the
  app cannot even know the token is stale.
- Once the token is expired, every authenticated MAL call returns HTTP 401. The
  auto-tracking call sites swallow this with `try?`
  (`ContinueWatchingManager`, `PlayerPresenter`), so the failure is silent. Tracking
  appears to "randomly" stop.

## Goals

- MAL access tokens refresh automatically; tracking keeps working without manual
  re-login.
- Authenticated MAL requests recover from an expired token transparently.
- Tracking failures are no longer silent — they are logged for diagnosis.

## Non-goals (handled by later projects / explicitly out of scope)

- UX consistency / hiding AniList-only affordances under MAL (Project 2).
- Feature parity: other-user profiles, following/followers, banners, richer detail,
  symmetric cross-add (Project 3).
- Social writes & notifications (MAL official API does not expose them).
- A persistent offline retry queue for failed writes (YAGNI — token refresh removes
  the dominant failure mode).

## Authenticated surface (what this touches)

Calls that use the **official MAL API** and require a bearer token:

- `MALLibraryService`: `fetchLibrary`, `fetchEntry`, `updateEntry`, `deleteEntry`
- `MALSocialService.fetchCurrentUserProfile`

Everything else MAL-related (`MALDiscoveryService`, `MALSocialService.fetchProfile`,
`fetchHistory`, `fetchFriends`) goes through **Jikan**, which is unauthenticated and
is **not** affected by this change.

## Design

### 1. Token expiry tracking — `MALAuthManager`

- Decode `expires_in` (seconds) from the token response in **both** `exchangeCode`
  and `refreshAccessToken`.
- Persist an absolute expiry `Date` in UserDefaults under key `mal_token_expiry`
  (computed as `Date() + expires_in`). The expiry is not secret, so UserDefaults is
  appropriate and matches the existing `mal_user_profile` cache pattern.
- Clear `mal_token_expiry` on `logout()`.

### 2. Single authenticated choke point — `MALAuthManager`

Add:

```swift
func send(url: URL,
          method: String = "GET",
          body: Data? = nil,
          contentType: String? = nil) async throws -> (Data, HTTPURLResponse)
```

Behavior:

1. **Proactive refresh:** if the stored expiry is in the past or within a 60-second
   margin, refresh before sending.
2. Build the request via the existing `authorizedRequest`, attach `body` /
   `contentType` when provided, and send via the shared `URLSession`.
3. **Reactive refresh:** if the response is HTTP 401, refresh **once** and retry the
   request a single time.
4. **Concurrency guard:** all refreshes funnel through a single in-flight `Task`, so
   simultaneous tracking + library calls trigger at most one network refresh; other
   callers await the same task.
5. **Dead refresh token:** if refresh fails because the refresh token is invalid
   (`invalid_grant`), call `logout()` so the UI cleanly reflects a signed-out state
   rather than retrying forever.

`authorizedRequest` remains for constructing the request. The two MAL-API services
replace their direct `session.data(for:)` calls with `MALAuthManager.shared.send(...)`.

### 3. Stop silent tracking failures

At the auto-tracking call sites that currently use `try?`:

- `ContinueWatchingManager` (around lines 460, 774, 782)
- `PlayerPresenter` (around line 203)

wrap the MAL update in `do/catch` and log failures via `Logger.shared.log(...)` (type
`"MAL"` or similar). These remain **non-fatal** — they must never interrupt playback
or marking. The goal is visibility, not behavior change on the happy path.

## Error handling

`send` classifies responses:

- 401 → refresh + retry once; still 401 after retry → `ProviderError.unauthenticated`
  and `logout()`.
- 404 → `ProviderError.notFound`.
- ≥500 → `ProviderError.serverError(code)`.
- Refresh network/decoding failure → propagate; `invalid_grant` → `logout()`.

Existing per-service `validateResponse` logic for 404/500 is preserved; the 401 path
moves into `send`.

## Testing / verification

No test target exists in this project, so:

1. **Build:** `xcodebuild -project Shirox.xcodeproj -scheme Shirox_iOS
   -destination 'generic/platform=iOS Simulator' -configuration Debug build`
   must succeed.
2. **Manual smoke test:** force expiry by writing a past `Date` to `mal_token_expiry`,
   then perform a library edit. Confirm:
   - the edit succeeds (a refresh happened first), and
   - the in-app logs show a token refresh rather than a swallowed 401.

## Risks

- MAL's refresh-token lifetime is finite; when it finally expires, `logout()` is the
  correct fallback (user re-authenticates). This is expected, not a regression.
- The concurrency guard must avoid deadlock: callers await the shared refresh task and
  then proceed; the refresh task itself must not re-enter `send`.
