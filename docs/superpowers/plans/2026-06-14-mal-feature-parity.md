# MAL Feature Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close visible MAL/AniList gaps: MAL banner art, richer relations, MAL→AniList cross-add, an honest single "Friends" list, and correctly-keyed episode thumbnails for MAL-tracked anime.

**Architecture:** Each item reuses infrastructure that already exists (TVDB fanart, reverse ID mapping, the dual-edit sheet pattern). Changes are localized per feature; no new files, no pbxproj changes.

**Tech Stack:** SwiftUI, async/await, existing singletons (`TVDBMappingService`, `IDMappingService`, `MALProvider`, `AniListProvider`, `ProviderManager`).

**Note on testing:** No unit-test target exists. The gate for each code task is a successful iOS build, plus a final manual pass. Build command used throughout:

```
xcodebuild -project Shirox.xcodeproj -scheme Shirox_iOS -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

---

### Task 1: MAL banner images

**Files:**
- Modify: `Shirox/Models/Media.swift:28`
- Modify: `Shirox/ViewModels/AniListDetailViewModel.swift:44-48`

- [ ] **Step 1: Make bannerImage mutable**

In `Shirox/Models/Media.swift`, change line 28 from:

```swift
    let bannerImage: String?
```

to:

```swift
    var bannerImage: String?
```

- [ ] **Step 2: Enrich the MAL banner on detail load**

In `Shirox/ViewModels/AniListDetailViewModel.swift`, find the `do` block in `load(id:preloaded:)` (around lines 44-48):

```swift
        do {
            media = try await ProviderManager.shared.call { try await $0.detail(id: id) }
        } catch {
            self.error = error.localizedDescription
        }
```

Replace it with:

```swift
        do {
            media = try await ProviderManager.shared.call { try await $0.detail(id: id) }
            // MAL/Jikan has no banner art; reuse the already-cached TVDB fanart.
            if media?.provider == .mal, media?.bannerImage == nil {
                let artwork = await TVDBMappingService.shared.getArtwork(for: id, provider: .mal)
                if let fanart = artwork.fanart {
                    media?.bannerImage = fanart
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
```

- [ ] **Step 3: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 4: Commit**

```bash
git add Shirox/Models/Media.swift Shirox/ViewModels/AniListDetailViewModel.swift
git commit -m "feat(mal): show TVDB fanart as banner on MAL detail"
```

---

### Task 2: Richer MAL relations

**Files:**
- Modify: `Shirox/Services/MALDiscoveryService.swift:190-221`

- [ ] **Step 1: Map more relation types**

In `Shirox/Services/MALDiscoveryService.swift`, find the `relations:` closure inside `mapToMedia` (around lines 190-221). It currently filters to `Sequel` only:

```swift
            relations: {
                guard let jikanRelations = a.relations else { return nil }
                let edges: [MediaRelationEdge] = jikanRelations
                    .filter { $0.relation == "Sequel" }
                    .flatMap { $0.entry }
                    .filter { $0.type == "anime" }
                    .map { entry in
                        MediaRelationEdge(
                            relationType: "SEQUEL",
                            node: Media(
                                id: entry.mal_id,
                                idMal: entry.mal_id,
                                provider: .mal,
                                title: MediaTitle(romaji: entry.name, english: nil, native: nil),
                                coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                                bannerImage: nil,
                                description: nil,
                                episodes: nil,
                                status: nil,
                                averageScore: nil,
                                genres: nil,
                                season: nil,
                                seasonYear: nil,
                                nextAiringEpisode: nil,
                                relations: nil,
                                type: "TV",
                                format: nil
                            )
                        )
                    }
                return edges.isEmpty ? nil : MediaRelations(edges: edges)
            }(),
```

Replace it with a version that maps the meaningful Jikan relation types:

```swift
            relations: {
                guard let jikanRelations = a.relations else { return nil }
                // Map the meaningful Jikan relation labels to the app's relationType
                // strings. Sequel handling is preserved so next-episode chaining works.
                func relationType(for label: String) -> String? {
                    switch label {
                    case "Sequel":              return "SEQUEL"
                    case "Prequel":             return "PREQUEL"
                    case "Side story":          return "SIDE_STORY"
                    case "Parent story":        return "PARENT"
                    case "Alternative version",
                         "Alternative setting": return "ALTERNATIVE"
                    default:                    return nil
                    }
                }
                let edges: [MediaRelationEdge] = jikanRelations
                    .compactMap { rel -> [MediaRelationEdge]? in
                        guard let type = relationType(for: rel.relation) else { return nil }
                        return rel.entry
                            .filter { $0.type == "anime" }
                            .map { entry in
                                MediaRelationEdge(
                                    relationType: type,
                                    node: Media(
                                        id: entry.mal_id,
                                        idMal: entry.mal_id,
                                        provider: .mal,
                                        title: MediaTitle(romaji: entry.name, english: nil, native: nil),
                                        coverImage: MediaCoverImage(large: nil, extraLarge: nil),
                                        bannerImage: nil,
                                        description: nil,
                                        episodes: nil,
                                        status: nil,
                                        averageScore: nil,
                                        genres: nil,
                                        season: nil,
                                        seasonYear: nil,
                                        nextAiringEpisode: nil,
                                        relations: nil,
                                        type: "TV",
                                        format: nil
                                    )
                                )
                            }
                    }
                    .flatMap { $0 }
                return edges.isEmpty ? nil : MediaRelations(edges: edges)
            }(),
```

- [ ] **Step 2: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Commit**

```bash
git add Shirox/Services/MALDiscoveryService.swift
git commit -m "feat(mal): map prequel/side-story/parent/alternative relations"
```

---

### Task 3: MAL → AniList cross-add (symmetric)

**Files:**
- Modify: `Shirox/Views/AniListDetailView.swift`

This mirrors the existing `showMALEdit` sheet (which adds an AniList item to MAL) to provide the reverse for MAL items. The existing AniList-primary paths are left untouched.

- [ ] **Step 1: Add state for the reverse edit sheet**

In `Shirox/Views/AniListDetailView.swift`, find the edit state block (around lines 26-30):

```swift
    @State private var showLibraryEdit = false
    @State private var existingEntry: LibraryEntry? = nil
    @State private var existingMALEntry: LibraryEntry? = nil
    @State private var showMALEdit = false
    @State private var isLoadingEntry = false
```

Add two properties:

```swift
    @State private var showLibraryEdit = false
    @State private var existingEntry: LibraryEntry? = nil
    @State private var existingMALEntry: LibraryEntry? = nil
    @State private var showMALEdit = false
    @State private var showAniListEdit = false
    @State private var existingAniListCrossEntry: LibraryEntry? = nil
    @State private var isLoadingEntry = false
```

- [ ] **Step 2: Add the anilistMediaId computed and reverse-dual flag**

Find the `malMediaId` computed (around lines 63-66):

```swift
    private var malMediaId: Int? {
        guard let media = vm.media, media.provider == .anilist else { return nil }
        return media.idMal
    }
```

Directly after it, add:

```swift
    /// The AniList id for a MAL-provider media (from the reverse mapping cache).
    private var anilistMediaId: Int? {
        guard let media = vm.media, media.provider == .mal else { return nil }
        return IDMappingService.shared.cachedAnilistId(forMALId: media.id)
    }

    /// True when viewing a MAL item while AniList is signed in and its AniList id
    /// is known — enables the reverse "Edit on AniList" cross-add.
    private var isReverseDualAvailable: Bool {
        vm.media?.provider == .mal && auth.isLoggedIn && anilistMediaId != nil
    }
```

- [ ] **Step 3: Warm the reverse mapping + entry on load**

Find the load `.task` block that fetches the cross entry (around lines 198-200):

```swift
            if malAuth.isLoggedIn, let idMal = vm.media?.idMal, vm.media?.provider == .anilist {
                existingMALEntry = try? await MALProvider.shared.fetchEntry(mediaId: idMal)
            }
```

Directly after it, add the reverse warm-up:

```swift
            if auth.isLoggedIn, vm.media?.provider == .mal, let malId = vm.media?.id {
                _ = await IDMappingService.shared.anilistId(forMALId: malId)
                if let aniId = anilistMediaId {
                    existingAniListCrossEntry = try? await AniListProvider.shared.fetchEntry(mediaId: aniId)
                }
            }
```

- [ ] **Step 4: Offer "Edit on AniList" in the edit menu for MAL items**

Find the start of `editToolbarButton` (around lines 112-143):

```swift
    @ViewBuilder private var editToolbarButton: some View {
        if isDualAvailable && !dualSync {
            Menu {
```

Insert a new reverse-dual branch as the FIRST condition, so a MAL item with AniList available gets a menu. Replace:

```swift
    @ViewBuilder private var editToolbarButton: some View {
        if isDualAvailable && !dualSync {
            Menu {
```

with:

```swift
    @ViewBuilder private var editToolbarButton: some View {
        if isReverseDualAvailable {
            Menu {
                Button {
                    Task {
                        isLoadingEntry = true
                        existingEntry = try? await activeProvider.fetchEntry(mediaId: mediaId)
                        isLoadingEntry = false
                        showLibraryEdit = true
                    }
                } label: { Label("Edit on MyAnimeList", systemImage: "pencil") }
                Button {
                    Task {
                        isLoadingEntry = true
                        if let aniId = anilistMediaId {
                            existingAniListCrossEntry = try? await AniListProvider.shared.fetchEntry(mediaId: aniId)
                        }
                        isLoadingEntry = false
                        showAniListEdit = true
                    }
                } label: { Label("Edit on AniList", systemImage: "pencil") }
            } label: {
                if isLoadingEntry {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: "pencil.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
            .disabled(isLoadingEntry)
        } else if isDualAvailable && !dualSync {
            Menu {
```

(This keeps the existing `else if isDualAvailable && !dualSync` and the final `else if auth.isLoggedIn || malAuth.isLoggedIn` branches exactly as they are — you are only inserting a new leading `if` branch and changing the original `if` to `else if`.)

- [ ] **Step 5: Add the reverse AniList edit sheet**

Find the end of the `showMALEdit` sheet (around lines 366-372), which closes with:

```swift
                #if os(iOS)
                .adaptivePresentationDetents([.medium, .large])
                #else
                .frame(minWidth: 480, minHeight: 360)
                #endif
            }
        }
    }
```

Insert a new `showAniListEdit` sheet immediately before the final closing braces (after the `showMALEdit` sheet's closing `}` for `.adaptiveSheet`, and before the `}` that closes the view-modifier chain). Concretely, replace the block above with:

```swift
                #if os(iOS)
                .adaptivePresentationDetents([.medium, .large])
                #else
                .frame(minWidth: 480, minHeight: 360)
                #endif
            }
        }
        .adaptiveSheet(isPresented: $showAniListEdit) {
            if let media = vm.media, let aniId = anilistMediaId {
                let aniMedia = Media(
                    id: aniId, idMal: media.id, provider: .anilist,
                    title: media.title, coverImage: media.coverImage,
                    bannerImage: nil, description: nil, episodes: media.episodes,
                    status: nil, averageScore: nil, genres: nil,
                    season: nil, seasonYear: nil, nextAiringEpisode: nil,
                    relations: nil, type: nil, format: nil
                )
                LibraryEntryEditSheet(
                    entry: existingAniListCrossEntry,
                    media: aniMedia,
                    onSave: { status, progress, score in
                        if var updated = existingAniListCrossEntry {
                            updated.status = status
                            updated.progress = progress
                            updated.score = score
                            existingAniListCrossEntry = updated
                        }
                        Task { try? await AniListProvider.shared.updateEntry(mediaId: aniId, status: status, progress: progress, score: score) }
                    },
                    onDelete: existingAniListCrossEntry != nil ? {
                        let entryId = existingAniListCrossEntry!.id
                        existingAniListCrossEntry = nil
                        Task { try? await AniListProvider.shared.deleteEntry(entryId: entryId) }
                    } : nil
                )
                #if os(iOS)
                .adaptivePresentationDetents([.medium, .large])
                #else
                .frame(minWidth: 480, minHeight: 360)
                #endif
            }
        }
    }
```

- [ ] **Step 6: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 7: Commit**

```bash
git add Shirox/Views/AniListDetailView.swift
git commit -m "feat(mal): add Edit-on-AniList cross-add for MAL detail"
```

---

### Task 4: Honest "Friends" list for MAL

**Files:**
- Modify: `Shirox/Views/Profile/ProfileSocialView.swift`

- [ ] **Step 1: Add a provider check**

In `Shirox/Views/Profile/ProfileSocialView.swift`, add an observed object and an `isMAL` flag. Find the property block (around lines 4-10):

```swift
    @ObservedObject var vm: ProfileViewModel
    let userId: Int
    var topContent: AnyView? = nil

    @State private var selectedSocial: ProfileViewModel.SocialType = .followers
    @State private var targetUserId: Int?
    @State private var targetUsername: String?
```

Replace it with:

```swift
    @ObservedObject var vm: ProfileViewModel
    let userId: Int
    var topContent: AnyView? = nil

    @ObservedObject private var providerManager = ProviderManager.shared
    @State private var selectedSocial: ProfileViewModel.SocialType = .followers
    @State private var targetUserId: Int?
    @State private var targetUsername: String?

    private var isMAL: Bool { providerManager.primary?.providerType == .mal }
```

- [ ] **Step 2: Hide the Followers/Following toggle for MAL**

Find the `Picker` (around lines 26-39):

```swift
            Picker("Social", selection: $selectedSocial) {
                Text("Followers").tag(ProfileViewModel.SocialType.followers)
                Text("Following").tag(ProfileViewModel.SocialType.following)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            #if !os(tvOS)
            .listRowSeparator(.hidden)
            #endif
            .listRowBackground(Color.clear)
            .onChangeOf(selectedSocial) { newValue in
                Task { await vm.loadSocial(userId: userId, type: newValue) }
            }
```

Wrap it so it only shows for non-MAL:

```swift
            if !isMAL {
                Picker("Social", selection: $selectedSocial) {
                    Text("Followers").tag(ProfileViewModel.SocialType.followers)
                    Text("Following").tag(ProfileViewModel.SocialType.following)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                .listRowBackground(Color.clear)
                .onChangeOf(selectedSocial) { newValue in
                    Task { await vm.loadSocial(userId: userId, type: newValue) }
                }
            }
```

- [ ] **Step 3: Use "Friends" wording for the MAL empty state**

Find the empty-state text (around line 52):

```swift
                    Text(selectedSocial == .followers ? "No followers yet." : "Not following anyone yet.")
```

Replace it with:

```swift
                    Text(isMAL ? "No friends yet." : (selectedSocial == .followers ? "No followers yet." : "Not following anyone yet."))
```

- [ ] **Step 4: Make MAL friend rows non-navigable**

For MAL, opening another user's profile is out of scope (the profile layer is keyed on AniList user ids), so the rows should not look tappable. Find the user row `Button` (around lines 59-79):

```swift
                ForEach(users) { user in
                    Button {
                        targetUsername = user.name
                        targetUserId = user.id
                    } label: {
                        HStack(spacing: 12) {
                            CachedAsyncImage(urlString: user.avatarURL ?? "")
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                            Text(user.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
```

Replace it with:

```swift
                ForEach(users) { user in
                    Button {
                        guard !isMAL else { return }
                        targetUsername = user.name
                        targetUserId = user.id
                    } label: {
                        HStack(spacing: 12) {
                            CachedAsyncImage(urlString: user.avatarURL ?? "")
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                            Text(user.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if !isMAL {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isMAL)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
```

- [ ] **Step 5: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 6: Commit**

```bash
git add Shirox/Views/Profile/ProfileSocialView.swift
git commit -m "feat(mal): show a single non-navigable Friends list for MAL profiles"
```

---

### Task 5: Player episode thumbnails/titles for MAL

**Files:**
- Modify: `Shirox/Views/PlayerView.swift:1249-1265`

- [ ] **Step 1: Fall back to the MAL id for episode metadata**

In `Shirox/Views/PlayerView.swift`, find the episode-title fetch (around lines 1249-1265):

```swift
        guard let aniListID = currentContext?.aniListID,
```

This guard returns early for MAL-only playback (no AniList id). Locate the full block:

```swift
        guard let aniListID = currentContext?.aniListID, let ep = currentContext?.episodeNumber else { return }
        guard tvdbEpisodeTitle == nil else { return }
        Task {
            // Try Anira per-episode first for accurate title
            let aniraEp = await TVDBMappingService.shared.fetchAniraEpisode(id: aniListID, episodeNumber: ep)
            if let title = aniraEp?.title, !title.isEmpty {
                await MainActor.run { tvdbEpisodeTitle = title }
                return
            }
            // Fall back to TVDB / bulk episode list
            let eps = await TVDBMappingService.shared.getEpisodes(for: aniListID)
            await MainActor.run {
                tvdbEpisodeTitle = eps.first(where: { $0.episode == ep })?.title
            }
        }
```

Replace it with a version that uses the MAL id + `.mal` provider when there is no AniList id:

```swift
        guard let ep = currentContext?.episodeNumber else { return }
        guard tvdbEpisodeTitle == nil else { return }
        let aniListID = currentContext?.aniListID
        let malID = currentContext?.malID
        guard aniListID != nil || malID != nil else { return }
        Task {
            if let aniListID {
                let aniraEp = await TVDBMappingService.shared.fetchAniraEpisode(id: aniListID, episodeNumber: ep)
                if let title = aniraEp?.title, !title.isEmpty {
                    await MainActor.run { tvdbEpisodeTitle = title }
                    return
                }
                let eps = await TVDBMappingService.shared.getEpisodes(for: aniListID)
                await MainActor.run {
                    tvdbEpisodeTitle = eps.first(where: { $0.episode == ep })?.title
                }
            } else if let malID {
                let eps = await TVDBMappingService.shared.getEpisodes(for: malID, provider: .mal)
                await MainActor.run {
                    tvdbEpisodeTitle = eps.first(where: { $0.episode == ep })?.title
                }
            }
        }
```

- [ ] **Step 2: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Commit**

```bash
git add Shirox/Views/PlayerView.swift
git commit -m "feat(mal): resolve in-player episode titles via MAL id when no AniList id"
```

---

### Task 6: Continue Watching card thumbnails for MAL

`ContinueWatchingItem` has no MAL id, so the card cannot key MAL thumbnails today. Add an optional `malID` field (backward-compatible: a missing key decodes to nil), populate it where items are created, and use it in the card.

**Files:**
- Modify: `Shirox/Models/ContinueWatchingItem.swift`
- Modify: `Shirox/Views/PlayerView.swift:873`
- Modify: `Shirox/Services/ContinueWatchingManager.swift:600`
- Modify: `Shirox/Views/ContinueWatchingCard.swift:385-400`

- [ ] **Step 1: Add the malID field to the model**

In `Shirox/Models/ContinueWatchingItem.swift`, find the `aniListID` / `moduleId` fields (around lines 30-31):

```swift
    let aniListID: Int?
    let moduleId: String?
```

Add a `malID` field directly after:

```swift
    let aniListID: Int?
    let malID: Int?
    let moduleId: String?
```

- [ ] **Step 2: Populate malID where the player saves progress**

In `Shirox/Views/PlayerView.swift`, find the `ContinueWatchingItem(` construction (around line 873). It passes `aniListID:`; add `malID:` alongside it using the player context. Locate the `aniListID:` argument in that initializer call and add the line below it:

```swift
            aniListID: context.aniListID,
            malID: context.malID,
```

(Use whichever context variable is in scope at that call site — it is the same `context`/`ctx` used for `aniListID`. If the surrounding code uses `ctx`, write `malID: ctx.malID`.)

- [ ] **Step 3: Populate malID in the manager's item builder**

In `Shirox/Services/ContinueWatchingManager.swift`, find the `ContinueWatchingItem(` construction (around line 600). Add a `malID:` argument next to its `aniListID:` argument. If a MAL id is available in that scope use it; otherwise pass `nil`:

```swift
            aniListID: aniListID,
            malID: nil,
```

(If the surrounding function already has a MAL id variable in scope, pass that instead of `nil`. The construction around line 600 builds an item from already-stored fields, so `nil` is correct unless a malID is explicitly present.)

- [ ] **Step 4: Use malID for the card thumbnail**

In `Shirox/Views/ContinueWatchingCard.swift`, find the thumbnail `.task` (around lines 385-400):

```swift
        .task(id: item.id) {
            guard let aid = item.aniListID else { return }
            // 1. Use cached episode thumbnail immediately if available
            if let cached = TVDBMappingService.shared.getCachedEpisode(for: aid, episodeNumber: item.episodeNumber)?.thumbnail {
                episodeThumbnail = cached
                return
            }
            // 2. Fetch from animap episodes endpoint
            let episodes = await TVDBMappingService.shared.getEpisodes(for: aid)
            if let thumb = episodes.first(where: { $0.episode == item.episodeNumber })?.thumbnail {
                episodeThumbnail = thumb
                return
            }
            // 3. Fall back to TVDB series banner/fanart
            let artwork = await TVDBMappingService.shared.getArtwork(for: aid)
            episodeThumbnail = artwork.fanart ?? artwork.poster
```

Replace it with a version that handles a MAL-only item:

```swift
        .task(id: item.id) {
            if let aid = item.aniListID {
                // 1. Use cached episode thumbnail immediately if available
                if let cached = TVDBMappingService.shared.getCachedEpisode(for: aid, episodeNumber: item.episodeNumber)?.thumbnail {
                    episodeThumbnail = cached
                    return
                }
                // 2. Fetch from animap episodes endpoint
                let episodes = await TVDBMappingService.shared.getEpisodes(for: aid)
                if let thumb = episodes.first(where: { $0.episode == item.episodeNumber })?.thumbnail {
                    episodeThumbnail = thumb
                    return
                }
                // 3. Fall back to TVDB series banner/fanart
                let artwork = await TVDBMappingService.shared.getArtwork(for: aid)
                episodeThumbnail = artwork.fanart ?? artwork.poster
            } else if let mid = item.malID {
                let episodes = await TVDBMappingService.shared.getEpisodes(for: mid, provider: .mal)
                if let thumb = episodes.first(where: { $0.episode == item.episodeNumber })?.thumbnail {
                    episodeThumbnail = thumb
                    return
                }
                let artwork = await TVDBMappingService.shared.getArtwork(for: mid, provider: .mal)
                episodeThumbnail = artwork.fanart ?? artwork.poster
            }
```

(Keep the remaining lines of the `.task` closure — the existing closing braces — unchanged.)

- [ ] **Step 5: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**. (If the compiler flags other `ContinueWatchingItem(` initializers missing `malID:`, add `malID: nil` to each — there are two known sites, Steps 2 and 3.)

- [ ] **Step 6: Commit**

```bash
git add Shirox/Models/ContinueWatchingItem.swift Shirox/Views/PlayerView.swift Shirox/Services/ContinueWatchingManager.swift Shirox/Views/ContinueWatchingCard.swift
git commit -m "feat(mal): carry malID on continue-watching items for MAL thumbnails"
```

---

### Task 7: Manual verification

**Files:** none (verification only)

- [ ] **Step 1: MAL banner**

With MyAnimeList active, open an anime that has TVDB artwork. Confirm a banner image appears at the top of the detail screen (it falls back to the plain header when TVDB has no fanart).

- [ ] **Step 2: Richer relations**

Open a MAL anime that has a prequel or side story. Confirm those appear in the relations section, not only sequels. Confirm a series with a sequel still advances to the next season correctly.

- [ ] **Step 3: Cross-add to AniList**

Signed into both services, open a **MAL** anime. Confirm the edit (pencil) menu offers **"Edit on AniList"**, and saving from it writes to your AniList library (verify on anilist.co).

- [ ] **Step 4: Friends list**

With MAL active, open your profile → Social tab. Confirm it shows a single **Friends** list (no Followers/Following toggle, no chevrons). With AniList active, confirm Followers/Following both still work.

- [ ] **Step 5: Thumbnails**

Play or resume a MAL-tracked anime. Confirm the in-player episode list and the Continue Watching card show real episode thumbnails/titles where anira has art (still blank where it has none — that's a third-party coverage limit, not a bug).

---

## Self-Review Notes

- **Spec coverage:** banners → Task 1; richer relations → Task 2; MAL→AniList cross-add → Task 3; honest Friends → Task 4; player thumbnails → Task 5; Continue Watching thumbnails (incl. the `malID` model field the spec implied was needed) → Task 6; verification → Task 7 plus per-task builds.
- **Placeholder scan:** No TBD/"handle edge cases" placeholders; every code step shows full code. The two `malID:`-population steps note the fallback value explicitly.
- **Type consistency:** `Media.bannerImage` is `var` after Task 1; `anilistMediaId`/`isReverseDualAvailable`/`showAniListEdit`/`existingAniListCrossEntry` are defined in Task 3 before use; `ContinueWatchingItem.malID` is added in Task 6 Step 1 before being read/written in later steps; `getEpisodes(for:provider:)`, `getArtwork(for:provider:)`, `cachedAnilistId(forMALId:)`, `anilistId(forMALId:)`, and `context.malID`/`PlayerContext.malID` all match existing signatures.
- **Discovered during planning:** `ContinueWatchingItem` lacked a MAL id, so Task 6 adds one (backward-compatible optional) — this is the only model change and is required for the CW-card half of the thumbnail item.
