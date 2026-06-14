# MAL UX Consistency & Provider Switching — Design

**Date:** 2026-06-14
**Project:** 2 of 3 in the "bring MyAnimeList to parity with AniList" effort
**Status:** Approved (pending spec review)

## Problem

Two MAL UX problems reported by the user:

1. **Switching between the AniList and MAL libraries is confusing.** The app follows
   `ProviderManager.primary`, but the only ways to change it are reordering providers
   in Settings or selecting one in the module list. There is no obvious switch in the
   main browsing surfaces.
2. **MAL feels second-class.** Tapping the AniList avatar in the Library toolbar opens
   a rich `ProfileView`; tapping the **MAL** avatar only opens a logout confirmation
   dialog — no profile screen at all.

## Key facts established during exploration

- The active provider is **global**: `HomeViewModel`, `SearchView`, and `LibraryView`
  all follow `ProviderManager.primary` and reload automatically when it changes
  (`HomeViewModel` subscribes to `ProviderManager.shared.$orderedProviders`).
- `ProviderManager.selectProvider(_:)` already moves a provider to primary (index 0)
  and persists the order. This is the single mutation point for "which provider is
  active."
- Notifications are **already** hidden for MAL in the Library toolbar
  (`activeProviderType == .anilist` gate). No work needed there.
- `ProfileView` already supports MAL for the Activity (Jikan history), Stats
  (anime_statistics), and Social/Friends (Jikan friends) tabs. It lacks a MAL data
  source for the Favourites tab. The follow button is already gated to AniList.

## Goals

- Make switching the active provider obvious and consistent from the main surfaces.
- Give MAL users a real profile screen, matching AniList where data exists.
- Ensure no AniList-only affordance appears broken/empty under MAL.

## Non-goals

- Social writes (post status, like, reply, follow) and notifications — MAL's official
  API does not expose them; notifications are already hidden for MAL.
- The MAL episode-thumbnail mapping quirk (cosmetic) — belongs to Project 3.
- Changing discovery/search data sources — they are already provider-aware.

## Design

### 1. Global provider switcher (`ProviderSwitcher`)

A new reusable SwiftUI view, `ProviderSwitcher`, in `Shirox/Views/Shared/`.

- Renders an iOS segmented `Picker` over the authenticated providers, bound to the
  current `ProviderManager.primary?.providerType`.
- On selection change, calls `ProviderManager.shared.selectProvider(newType)`. No other
  wiring needed — subscribers reload themselves.
- **Visibility:** renders only when **both** AniList and MAL are authenticated
  (`AniListAuthManager.shared.isLoggedIn && MALAuthManager.shared.isLoggedIn`).
  Otherwise it returns `EmptyView()` — with a single provider there is nothing to
  switch.
- Observes `ProviderManager.shared`, `AniListAuthManager.shared`, and
  `MALAuthManager.shared` so it appears/updates reactively on login/logout/switch.

**Placement:**

- **Home** (`HomeView`): at the top of the content, above the carousel/sections.
- **Library** (`LibraryView`): in the header area, above the status tabs.
- **Settings → Providers** (`ProvidersSettingsSection`): keep the drag-to-reorder list
  (it configures the fallback ordering), but (a) make the primary row visually
  unmistakable as "Primary," and (b) allow tapping a non-primary row to call
  `selectProvider` so Settings stays in sync with the header switcher.

One source of truth (`ProviderManager.primary`), three entry points.

### 2. MAL profile parity

- In `LibraryView`, change the avatar/username button so that for **both** providers it
  opens `ProfileView` (currently MAL opens `showMALLogoutConfirm`). Remove the
  MAL-only logout branch from that button.
- Logout for MAL is reached through `ProfileView`'s existing toolbar logout button,
  which already handles `activeProviderType == .mal`
  (`MALAuthManager.shared.logout()`). So the avatar tap becomes consistently "open
  profile."
- In `ProfileView`, hide the **Favourites** tab (selectedTab segment) when
  `activeProviderType == .mal`, since there is no MAL favourites data source. The
  remaining tabs (Activity, Stats, Social) render with the MAL data already wired.
- Audit the profile/social write affordances and confirm each is gated to AniList
  (post status, like, reply, follow). Close any gap found. Most are already gated
  (e.g. the follow button at `ProfileView` line ~150).

### 3. Consistency audit

- Confirm the Library toolbar notifications bell stays AniList-only (already true).
- Verify no other Library/Home affordance shows an empty/broken state under MAL.

## Components touched

- Create: `Shirox/Views/Shared/ProviderSwitcher.swift` (new reusable view).
- Modify: `Shirox/Views/HomeView.swift` (mount switcher).
- Modify: `Shirox/Views/LibraryView.swift` (mount switcher; avatar → ProfileView).
- Modify: `Shirox/Views/SettingsView.swift` (`ProvidersSettingsSection`: clearer
  primary + tap-to-select).
- Modify: `Shirox/Views/Profile/ProfileView.swift` (hide Favourites tab for MAL;
  confirm write affordances gated).

New file registration: `ProviderSwitcher.swift` must be added to the iOS and macOS
targets in `project.pbxproj`.

## Error handling

- No new network paths. `selectProvider` is synchronous and already persists order.
- If a provider logs out while it is primary, `ProviderSwitcher` recomputes visibility
  reactively; existing screens already handle an unauthenticated provider.

## Testing / verification

No unit-test target exists. Verification:

1. **Build:** `xcodebuild -project Shirox.xcodeproj -scheme Shirox_iOS -destination
   'generic/platform=iOS Simulator' -configuration Debug build` must succeed.
2. **Manual:**
   - Signed into both services: the segmented switcher appears on Home and Library;
     switching flips Home, Search, and Library together; Settings reflects the same
     primary.
   - Signed into only one service: the switcher is hidden everywhere.
   - Tapping the MAL avatar opens `ProfileView` with Activity/Stats/Social populated
     and no Favourites tab; logout is reachable from the profile toolbar.
   - No empty/broken AniList-only affordance is visible under MAL.

## Risks

- Adding the switcher to two headers must not disrupt existing toolbar/layout. Mitigate
  by keeping `ProviderSwitcher` self-contained and conditionally rendered.
- macOS uses different toolbar placement; the switcher should render in the content
  area (not a platform-specific toolbar slot) to behave consistently. The pre-existing
  macOS build issue noted in project memory is unrelated and out of scope.
