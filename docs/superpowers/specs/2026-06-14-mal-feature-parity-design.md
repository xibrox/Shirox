# MAL Feature Parity — Design

**Date:** 2026-06-14
**Project:** 3 of 3 in the "bring MyAnimeList to parity with AniList" effort
**Status:** Approved (pending spec review)

## Problem

MAL content is functional but visibly thinner than AniList: no banner art, only
sequel relations, no way to cross-add a MAL title to AniList, dishonest
"Followers/Following" tabs that both show the same friends list, and missing episode
thumbnails on the Continue Watching cards and in-player episode list for MAL-tracked
anime.

## Scope (confirmed with user)

In: MAL banners, richer relations, MAL→AniList cross-add, honest Friends relabel,
Continue Watching / player thumbnail keying.

Out: viewing other MAL users' profiles (requires threading usernames through a protocol
keyed on `userId: Int` — invasive, low value), social writes, notifications (not in
MAL's official API).

## Key facts established during exploration

- `AniListDetailViewModel.load(id:)` sets `media` from `provider.detail(id:)`. For MAL
  this comes from `MALDiscoveryService.mapToMedia`, which sets `bannerImage: nil`.
- TVDB fanart for MAL ids is already fetched/cached:
  `TVDBMappingService.getArtwork(for:provider:.mal)` returns `(poster, fanart)`.
- The detail screen already renders `Media.bannerImage` and already renders any
  relations via `relationsSection`.
- The detail episode list already passes `media.provider` to `getEpisode`
  (`AniListEpisodeRowContainer(... provider: media.provider)`), so the MAL detail
  episode list already resolves via the MAL endpoint. The remaining gaps are the
  Continue Watching card (`getEpisodes(for: aid)`) and the in-player list
  (`getEpisodes(for: aniListID)`), both defaulting to `.anilist`.
- Reverse ID mapping exists: `IDMappingService.anilistId(forMALId:)` (async) and
  `cachedAnilistId(forMALId:)` (sync cache).
- `MALDiscoveryService.mapToMedia` filters relations to `relation == "Sequel"` only.
- `ProfileSocialView` shows Followers/Following segments; for MAL both
  `fetchFollowers`/`fetchFollowing` resolve to the same Jikan friends list.

## Design

### 1. MAL banner images

In `AniListDetailViewModel.load(id:)`, after `media` is assigned and the provider is
MAL with no banner, fetch TVDB fanart and apply it:

- After the successful `detail(id:)` assignment, if
  `media?.provider == .mal && media?.bannerImage == nil`, call
  `TVDBMappingService.shared.getArtwork(for: id, provider: .mal)` and, if a `fanart`
  URL is returned, set it as the media's `bannerImage`.
- `Media.bannerImage` is changed from `let` to `var` so the value can be updated in
  place (it is a struct held in `@Published var media`). Reassigning `media` triggers
  the view update.
- No UI change: the detail view already renders `bannerImage`, and the no-banner
  fallback already exists for the case where TVDB has no fanart.

### 2. Richer relations

In `MALDiscoveryService.mapToMedia`, replace the `Sequel`-only filter with a mapping of
the meaningful Jikan relation types to the app's `relationType` strings:

- `Sequel` → `"SEQUEL"`, `Prequel` → `"PREQUEL"`, `Side story` → `"SIDE_STORY"`,
  `Parent story` → `"PARENT"`, `Alternative version` → `"ALTERNATIVE"`,
  `Alternative setting` → `"ALTERNATIVE"`.
- Keep only `type == "anime"` entries (current behavior).
- The existing sequel-chaining logic keys on `relationType == "SEQUEL"`, which this
  preserves, so next-episode advancement is unaffected.
- `relationsSection` already renders the resulting edges.

### 3. MAL → AniList cross-add (symmetric)

`AniListDetailView` currently computes `malMediaId` (the MAL id of an AniList-provider
media) and offers "Edit on MyAnimeList" when both services are authenticated. Add the
symmetric path:

- Add a computed `anilistMediaId`: for a `provider == .mal` media, return the AniList
  id from `IDMappingService.shared.cachedAnilistId(forMALId: media.id)`; trigger an
  async `anilistId(forMALId:)` prefetch on load so the cache is warm.
- Generalize the edit menu so that when viewing a MAL item and AniList is signed in and
  `anilistMediaId != nil`, it offers "Edit on AniList" using
  `AniListProvider.shared.fetchEntry(mediaId: anilistMediaId)` and the existing AniList
  library edit sheet.
- The existing AniList→MAL behavior is unchanged; this only adds the reverse branch.

### 4. Honest "Friends" for MAL

In `ProfileSocialView`, when the active provider is MAL:

- Hide the Followers/Following segmented toggle and show a single list titled
  **Friends** (the friends already loaded via `loadSocial`).
- Keep both segments and labels for AniList unchanged.
- The empty-state text becomes "No friends yet." for MAL.

### 5. Continue Watching / player thumbnails for MAL

Make the two thumbnail-prefetch call sites provider-aware:

- `ContinueWatchingCard` (`getEpisodes(for: aid)`) and `PlayerView`
  (`getEpisodes(for: aniListID)`): when the tracked item is MAL-based (has a MAL id and
  no AniList id, or its provider is MAL), call
  `getEpisodes(for: <malId>, provider: .mal)` instead of the default AniList path.
- This is best-effort: thumbnails still depend on anira.dev coverage, but the lookup is
  keyed correctly so MAL-tracked items can show real thumbnails.

## Components touched

- Modify: `Shirox/Models/Media.swift` (`bannerImage` → `var`).
- Modify: `Shirox/ViewModels/AniListDetailViewModel.swift` (banner enrichment on load).
- Modify: `Shirox/Services/MALDiscoveryService.swift` (relation mapping).
- Modify: `Shirox/Views/AniListDetailView.swift` (symmetric cross-add: `anilistMediaId`
  + edit menu branch + prefetch).
- Modify: `Shirox/Views/Profile/ProfileSocialView.swift` (Friends for MAL).
- Modify: `Shirox/Views/ContinueWatchingCard.swift` and `Shirox/Views/PlayerView.swift`
  (provider-aware thumbnail prefetch).

No new files; no `project.pbxproj` changes.

## Error handling

- All new lookups (TVDB fanart, reverse ID mapping, episode thumbnails) are best-effort
  and already return optionals; failures leave the existing fallback behavior (no
  banner, no extra relations, generic thumbnail). None block the screen.
- `IDMappingService.anilistId(forMALId:)` is async and cached; the cross-add menu reads
  the sync cache and simply omits the AniList option until the id resolves.

## Testing / verification

No unit-test target exists. Verification:

1. **Build:** `xcodebuild -project Shirox.xcodeproj -scheme Shirox_iOS -destination
   'generic/platform=iOS Simulator' -configuration Debug build` must succeed.
2. **Manual (MAL active):**
   - Open a MAL anime with known TVDB art → a banner appears.
   - A MAL anime with prequel/side-story shows those under relations, not just sequels.
   - Signed into both services, the MAL detail edit menu offers "Edit on AniList" and
     the edit writes to AniList.
   - The profile Social tab shows a single **Friends** list for MAL (no
     Followers/Following toggle); AniList still shows both.
   - A MAL-tracked title shows real episode thumbnails on the Continue Watching card
     and in the player episode list where anira has art.

## Risks

- Making `Media.bannerImage` a `var` is low risk (struct field); confirm no code relies
  on it being `let` (it is only read).
- Generalizing the edit menu in `AniListDetailView` (a large file) must not regress the
  existing AniList→MAL dual-add. Mitigate by adding the reverse branch alongside, not
  rewriting the existing one.
- The macOS scheme has a pre-existing unrelated build failure (per project memory); iOS
  is the verification target.
