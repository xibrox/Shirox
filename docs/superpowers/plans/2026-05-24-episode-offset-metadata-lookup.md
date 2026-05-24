# Episode Offset Metadata Lookup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix episode thumbnail/title lookups in DetailView and AniListDetailView when a module uses absolute episode numbering (e.g. 25–32) but the AniList entry uses relative numbering (e.g. 1–8).

**Architecture:** Add a single `getEpisode(for:episodeNumber:provider:)` method to `TVDBMappingService` that centralises a four-step lookup waterfall (cache → fresh fetch → offset-adjusted fetch → nil). Replace the inline lookup blocks in both episode row containers with a call to this method.

**Tech Stack:** Swift 5.9, SwiftUI, `TVDBMappingService` (in `AniListService.swift`), Anira/TVDB APIs already wired.

---

## File Map

| File | What changes |
|------|-------------|
| `Shirox/Services/AniListService.swift` | Add `getEpisode(for:episodeNumber:provider:)` to `TVDBMappingService` (insert after line 686) |
| `Shirox/Views/DetailView.swift` | Replace `ModuleEpisodeRowContainer.task` body (lines 1550–1564) |
| `Shirox/Views/AniListDetailView.swift` | Replace `AniListEpisodeRowContainer.task` body (lines 1327–1339) |

---

### Task 1: Add `getEpisode` to `TVDBMappingService`

**Files:**
- Modify: `Shirox/Services/AniListService.swift` after line 686 (after `getCachedEpisode`)

- [ ] **Step 1: Insert the new method**

  Open `Shirox/Services/AniListService.swift`. After the closing `}` of `getCachedEpisode` (line 686), insert:

  ```swift
  /// Resolves episode metadata for a given episode number, handling absolute/relative
  /// numbering mismatches via a four-step waterfall.
  func getEpisode(for id: Int, episodeNumber: Int, provider: ProviderType = .anilist) async -> AniMapEpisode? {
      // 1. In-memory cache (checks both .episode and .absolute fields)
      if let hit = getCachedEpisode(for: id, provider: provider, episodeNumber: episodeNumber) {
          return hit
      }

      // 2. Fresh network fetch + check both fields
      let eps = await getEpisodes(for: id, provider: provider)
      if let hit = eps.first(where: { $0.episode == episodeNumber })
                   ?? eps.first(where: { $0.absolute == episodeNumber }) {
          return hit
      }

      // 3. Offset fallback — ensures epOffset is cached, then tries ±offset variants
      _ = await getTVDBId(for: id, provider: provider)
      let offset = cachedEpOffset(for: id, provider: provider) ?? 0
      guard offset > 0 else { return nil }

      // Module absolute → AniList-relative (e.g. 25 − 24 = 1)
      let relative = episodeNumber - offset
      if relative > 0, let hit = eps.first(where: { $0.episode == relative }) {
          return hit
      }

      // AniList-relative → absolute (e.g. 1 + 24 = 25)
      let absolute = episodeNumber + offset
      if let hit = eps.first(where: { $0.episode == absolute }) {
          return hit
      }

      return nil
  }
  ```

- [ ] **Step 2: Build and confirm no compile errors**

  ```bash
  xcodebuild -project Shirox.xcodeproj -scheme Shirox_iOS \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build 2>&1 | tail -20
  ```

  Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

  ```bash
  git add Shirox/Services/AniListService.swift
  git commit -m "feat: add getEpisode offset-aware lookup to TVDBMappingService"
  ```

---

### Task 2: Update `ModuleEpisodeRowContainer.task` in DetailView

**Files:**
- Modify: `Shirox/Views/DetailView.swift` lines 1550–1564

- [ ] **Step 1: Replace the `.task` body**

  Find this exact block starting at line 1550:

  ```swift
          .task {
              guard let aid = aniListID else { return }
              if aniMapEpisode == nil {
                  aniMapEpisode = TVDBMappingService.shared.getCachedEpisode(for: aid, episodeNumber: epNum)
                  if aniMapEpisode == nil {
                      let eps = await TVDBMappingService.shared.getEpisodes(for: aid)
                      aniMapEpisode = eps.first(where: { $0.episode == epNum })
                  }
              }
              // If episode was found but has no thumbnail, fall back to series fanart
              if aniMapEpisode?.thumbnail == nil {
                  let artwork = await TVDBMappingService.shared.getArtwork(for: aid)
                  fallbackThumbnail = artwork.fanart ?? artwork.poster
              }
          }
  ```

  Replace with:

  ```swift
          .task {
              guard let aid = aniListID else { return }
              aniMapEpisode = await TVDBMappingService.shared.getEpisode(for: aid, episodeNumber: epNum)
              if aniMapEpisode?.thumbnail == nil {
                  let artwork = await TVDBMappingService.shared.getArtwork(for: aid)
                  fallbackThumbnail = artwork.fanart ?? artwork.poster
              }
          }
  ```

- [ ] **Step 2: Build**

  ```bash
  xcodebuild -project Shirox.xcodeproj -scheme Shirox_iOS \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build 2>&1 | tail -20
  ```

  Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

  ```bash
  git add Shirox/Views/DetailView.swift
  git commit -m "feat: use getEpisode in ModuleEpisodeRowContainer for offset-aware lookup"
  ```

---

### Task 3: Update `AniListEpisodeRowContainer.task` in AniListDetailView

**Files:**
- Modify: `Shirox/Views/AniListDetailView.swift` lines 1327–1339

- [ ] **Step 1: Replace the `.task` body**

  Find this exact block starting at line 1327:

  ```swift
          .task {
              if aniMapEpisode == nil {
                  aniMapEpisode = TVDBMappingService.shared.getCachedEpisode(for: mediaId, provider: provider, episodeNumber: ep)
                  if aniMapEpisode == nil {
                      let eps = await TVDBMappingService.shared.getEpisodes(for: mediaId, provider: provider)
                      aniMapEpisode = eps.first(where: { $0.episode == ep })
                  }
              }
              if aniMapEpisode?.thumbnail == nil {
                  let artwork = await TVDBMappingService.shared.getArtwork(for: mediaId, provider: provider)
                  fallbackThumbnail = artwork.fanart ?? artwork.poster
              }
          }
  ```

  Replace with:

  ```swift
          .task {
              aniMapEpisode = await TVDBMappingService.shared.getEpisode(for: mediaId, episodeNumber: ep, provider: provider)
              if aniMapEpisode?.thumbnail == nil {
                  let artwork = await TVDBMappingService.shared.getArtwork(for: mediaId, provider: provider)
                  fallbackThumbnail = artwork.fanart ?? artwork.poster
              }
          }
  ```

- [ ] **Step 2: Build**

  ```bash
  xcodebuild -project Shirox.xcodeproj -scheme Shirox_iOS \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build 2>&1 | tail -20
  ```

  Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

  ```bash
  git add Shirox/Views/AniListDetailView.swift
  git commit -m "feat: use getEpisode in AniListEpisodeRowContainer for offset-aware lookup"
  ```

---

### Task 4: Manual Smoke Test

No automated test target exists. Verify behaviour manually with a show that uses absolute episode numbering.

- [ ] **Step 1: Identify a test case**

  Find an anime where:
  - The AniList entry covers e.g. 8 episodes (season/cour-relative 1–8)
  - The streaming module returns absolute episode numbers (e.g. 25–32)
  - Known example pattern: split-cour or multi-part shows (e.g. Attack on Titan Part 2, Demon Slayer arcs)

- [ ] **Step 2: Test DetailView (module-based)**

  1. Open the app in the iOS Simulator.
  2. Navigate to the show via a module search → DetailView.
  3. Confirm episode rows 25–32 now display thumbnails and episode titles.
  4. Previously they would show only the episode number circle with no image/title.

- [ ] **Step 3: Test AniListDetailView**

  1. Navigate to the same show via AniList search → AniListDetailView.
  2. Confirm episode rows 1–8 display correct thumbnails and titles from Anira/TVDB.
  3. Previously the thumbnails may have been missing if Anira returned absolute-keyed data.

- [ ] **Step 4: Confirm fallback still works**

  For a show with no Anira episode data at all, confirm episode rows still show the series fanart as a thumbnail (the `fallbackThumbnail` path).
