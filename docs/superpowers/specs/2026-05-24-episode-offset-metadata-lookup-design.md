# Episode Offset Metadata Lookup — Design Spec

**Date:** 2026-05-24  
**Status:** Approved

---

## Problem

When a JS module returns `EpisodeLink` numbers in absolute/series ordering (e.g. 25–32), but the corresponding AniList entry only covers episodes 1–8 of that series, two things break:

1. **DetailView** (`ModuleEpisodeRowContainer`): the `.task` block calls `getEpisodes(for:)` then filters with `eps.first(where: { $0.episode == epNum })`. Anira's episode data for that AniList ID uses `episode: 1–8`, so looking up by `epNum: 25` finds nothing — no thumbnail, no title.

2. **AniListDetailView** (`AniListEpisodeRowContainer`): same `.task` structure, same single-field filter `eps.first(where: { $0.episode == ep })`. Fails identically if Anira returns absolute-numbered episodes for that ID.

`getCachedEpisode` in `TVDBMappingService` already checks both `.episode` and `.absolute` fields — the gap is only in the fresh-fetch fallback path inside each `.task` block, and there is no offset-based fallback anywhere.

---

## Architecture

### New method: `TVDBMappingService.getEpisode(for:episodeNumber:provider:)`

A single `async` method that centralises all lookup logic. Both `.task` blocks call this instead of inline episode-fetching.

**Signature:**
```swift
func getEpisode(for id: Int, episodeNumber: Int, provider: ProviderType = .anilist) async -> AniMapEpisode?
```

**Lookup waterfall (stops at first match):**

1. **Cache hit** — `getCachedEpisode(for:provider:episodeNumber:)` already checks `.episode == num` and `.absolute == num`.
2. **Fresh fetch** — call `getEpisodes(for:provider:)`, then check `.episode == num` and `.absolute == num`.
3. **Offset fallback** — call `getTVDBId(for:provider:)` to ensure `epOffset` is populated, then:
   - Try `episode == num - offset` (module absolute → AniList-relative; e.g. 25 − 24 = 1)
   - Try `episode == num + offset` (AniList-relative → absolute; covers the reverse case)
4. **Thumbnail fallback** — if a match was found but its `thumbnail` is `nil`, synthesise a new `AniMapEpisode` with `thumbnail` injected from `getArtwork(for:provider:)` (fanart preferred, poster fallback).
5. **Returns `nil`** if nothing matched. Views handle `nil` with their existing `fallbackThumbnail` state.

Step 4 (thumbnail injection) keeps the method self-contained: callers get a fully-populated result or `nil`, not a half-populated one requiring a second call.

---

### Changes to `ModuleEpisodeRowContainer.task` (DetailView.swift ~L1550)

**Before:** ~15-line block — check cache, fetch all, filter `.episode`, separately fetch artwork.

**After:**
```swift
.task {
    guard let aid = aniListID else { return }
    aniMapEpisode = await TVDBMappingService.shared.getEpisode(for: aid, episodeNumber: epNum)
    if aniMapEpisode?.thumbnail == nil {
        let art = await TVDBMappingService.shared.getArtwork(for: aid)
        fallbackThumbnail = art.fanart ?? art.poster
    }
}
```

`@State private var aniMapEpisode` and `@State private var fallbackThumbnail` are unchanged.

---

### Changes to `AniListEpisodeRowContainer.task` (AniListDetailView.swift ~L1327)

Identical replacement pattern, passing `provider` through:

```swift
.task {
    aniMapEpisode = await TVDBMappingService.shared.getEpisode(for: mediaId, episodeNumber: ep, provider: provider)
    if aniMapEpisode?.thumbnail == nil {
        let art = await TVDBMappingService.shared.getArtwork(for: mediaId, provider: provider)
        fallbackThumbnail = art.fanart ?? art.poster
    }
}
```

---

## Data Flow

```
EpisodeLink.number (e.g. 25)
        │
        ▼
getEpisode(for: aniListID, episodeNumber: 25)
        │
        ├─ getCachedEpisode: .episode==25 or .absolute==25 → hit? return
        │
        ├─ getEpisodes + filter: .episode==25 or .absolute==25 → hit? return
        │
        ├─ getTVDBId → epOffset (e.g. 24)
        │   ├─ .episode == 25−24 = 1 → hit? return (injecting thumbnail if nil)
        │   └─ .episode == 25+24 = 49 → hit? return (injecting thumbnail if nil)
        │
        └─ nil (view uses fallbackThumbnail from getArtwork)
```

---

## Error Handling

- All network calls inside `getEpisode` delegate to existing methods (`getEpisodes`, `getTVDBId`, `getArtwork`) which already handle cancellation, timeouts, and log errors.
- `getEpisode` is non-throwing and returns `nil` on any failure; views degrade gracefully to `fallbackThumbnail`.

---

## Out of Scope

- Skip timestamps in the player (`SkipTimestampsService`) — already handles `epOffset` correctly for introdb/theIntroDB.
- Renumbering episode rows in AniListDetailView (episodes stay 1–8 from AniList's perspective).
- Any changes to `EpisodeLink`, `PlayerContext`, or `DetailViewModel`.

---

## Files Changed

| File | Change |
|------|--------|
| `Shirox/Services/AniListService.swift` | Add `getEpisode(for:episodeNumber:provider:)` to `TVDBMappingService` |
| `Shirox/Views/DetailView.swift` | Replace `ModuleEpisodeRowContainer.task` body |
| `Shirox/Views/AniListDetailView.swift` | Replace `AniListEpisodeRowContainer.task` body |
