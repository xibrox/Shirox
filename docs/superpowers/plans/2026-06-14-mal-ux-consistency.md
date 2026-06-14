# MAL UX Consistency & Provider Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make switching between the AniList and MAL libraries obvious via a global segmented switcher, and give MAL users a real profile screen, so MAL no longer feels second-class.

**Architecture:** Add one reusable `ProviderSwitcher` SwiftUI view that drives `ProviderManager.selectProvider(_:)` (the single source of truth that Home/Search/Library already observe). Mount it on Home and Library headers and add a "Make Primary" affordance in Settings. Separately, route the Library avatar to the existing provider-aware `ProfileView` for both providers, and make `ProfileView`'s tabs identity-based so the Favourites tab can be hidden for MAL.

**Tech Stack:** SwiftUI, Combine (`ObservableObject` singletons: `ProviderManager`, `AniListAuthManager`, `MALAuthManager`).

**Note on placement of `ProviderSwitcher`:** The spec called for a new file `Shirox/Views/Shared/ProviderSwitcher.swift`. This project has no Xcode synchronized file groups, so a new file requires manual `project.pbxproj` registration across 3 targets — fragile. Instead we add the `ProviderSwitcher` struct to the existing, already-registered `Shirox/Views/Shared/ProviderStatusBanner.swift` (same folder, same provider-UI cohesion). Functionally identical; no pbxproj changes.

**Note on testing:** No unit-test target exists. The gate for each code task is a successful iOS build, plus a final manual pass. Build command used throughout:

```
xcodebuild -project Shirox.xcodeproj -scheme Shirox_iOS -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

---

### Task 1: Add the ProviderSwitcher view

**Files:**
- Modify: `Shirox/Views/Shared/ProviderStatusBanner.swift`

- [ ] **Step 1: Append the ProviderSwitcher struct**

Add the following to the end of `Shirox/Views/Shared/ProviderStatusBanner.swift` (after the closing brace of `ProviderStatusBanner`):

```swift

/// Segmented control that switches the global primary provider.
/// Shown only when BOTH AniList and MyAnimeList are signed in — with a single
/// provider there is nothing to switch, so it renders nothing.
struct ProviderSwitcher: View {
    @ObservedObject private var manager = ProviderManager.shared
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared

    private var bothSignedIn: Bool {
        anilistAuth.isLoggedIn && malAuth.isLoggedIn
    }

    private var selection: Binding<ProviderType> {
        Binding(
            get: { manager.primary?.providerType ?? .anilist },
            set: { manager.selectProvider($0) }
        )
    }

    var body: some View {
        if bothSignedIn {
            // Iterate a STABLE order (allCases) so the segments don't reorder when
            // selectProvider moves the chosen provider to the front of orderedProviders.
            Picker("Provider", selection: selection) {
                ForEach(ProviderType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**. (The macOS scheme has a known pre-existing failure; use the iOS scheme.)

- [ ] **Step 3: Commit**

```bash
git add Shirox/Views/Shared/ProviderStatusBanner.swift
git commit -m "feat(provider): add ProviderSwitcher segmented control"
```

---

### Task 2: Mount the switcher on Home

**Files:**
- Modify: `Shirox/Views/HomeView.swift`

- [ ] **Step 1: Insert ProviderSwitcher at the top of the Home content**

In `Shirox/Views/HomeView.swift`, find the `ScrollView`/`VStack` content (around lines 35-39):

```swift
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if !vm.trending.isEmpty {
                                FeaturedCarousel(items: vm.trending)
                            }
```

Insert `ProviderSwitcher()` as the first child of the `VStack`:

```swift
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            ProviderSwitcher()
                            if !vm.trending.isEmpty {
                                FeaturedCarousel(items: vm.trending)
                            }
```

- [ ] **Step 2: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Commit**

```bash
git add Shirox/Views/HomeView.swift
git commit -m "feat(home): show provider switcher when both services are signed in"
```

---

### Task 3: Mount the switcher on Library

**Files:**
- Modify: `Shirox/Views/LibraryView.swift`

- [ ] **Step 1: Insert ProviderSwitcher at the top of libraryContent**

In `Shirox/Views/LibraryView.swift`, find the start of `libraryContent` (around lines 226-228):

```swift
    private var libraryContent: some View {
        VStack(spacing: 0) {
            // Combined row: Status on left, Genres on right
            HStack {
```

Insert `ProviderSwitcher()` as the first child of the `VStack`:

```swift
    private var libraryContent: some View {
        VStack(spacing: 0) {
            ProviderSwitcher()
            // Combined row: Status on left, Genres on right
            HStack {
```

- [ ] **Step 2: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 3: Commit**

```bash
git add Shirox/Views/LibraryView.swift
git commit -m "feat(library): show provider switcher when both services are signed in"
```

---

### Task 4: Route the Library avatar to ProfileView for both providers

**Files:**
- Modify: `Shirox/Views/LibraryView.swift`

- [ ] **Step 1: Make the avatar button always open the profile**

In `Shirox/Views/LibraryView.swift`, find the avatar button action (around lines 423-428):

```swift
                        Button {
                            if activeProviderType == .mal {
                                showMALLogoutConfirm = true
                            } else {
                                showProfile = true
                            }
                        } label: {
```

Replace the action body so both providers open the profile:

```swift
                        Button {
                            showProfile = true
                        } label: {
```

- [ ] **Step 2: Present the correct provider's profile**

Find the `showProfile` sheet (around lines 587-591):

```swift
        .adaptiveSheet(isPresented: $showProfile) {
            if let uid = anilistAuth.userId, let username = anilistAuth.username {
                ProfileView(userId: uid, username: username, avatarURL: anilistAuth.avatarURL)
            }
        }
```

Replace it to branch on the active provider:

```swift
        .adaptiveSheet(isPresented: $showProfile) {
            if activeProviderType == .mal, let uid = malAuth.userId {
                ProfileView(userId: uid, username: malAuth.username ?? "Profile", avatarURL: malAuth.avatarURL)
            } else if let uid = anilistAuth.userId, let username = anilistAuth.username {
                ProfileView(userId: uid, username: username, avatarURL: anilistAuth.avatarURL)
            }
        }
```

- [ ] **Step 3: Remove the now-unused MAL logout confirmation dialog**

Find and delete the MAL logout confirmation dialog (around lines 592-595):

```swift
        .confirmationDialog("Log out of MyAnimeList?", isPresented: $showMALLogoutConfirm, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) { malAuth.logout() }
            Button("Cancel", role: .cancel) { }
        }
```

Delete those four lines entirely. (MAL logout is reachable from `ProfileView`'s toolbar, which already calls `MALAuthManager.shared.logout()` for own MAL profiles.)

- [ ] **Step 4: Remove the now-unused state property**

Find the declaration (around line 18):

```swift
    @State private var showMALLogoutConfirm = false
```

Delete that line.

- [ ] **Step 5: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**. (If the compiler reports `showMALLogoutConfirm` still referenced, you missed a usage — search the file for it and remove the remaining reference.)

- [ ] **Step 6: Commit**

```bash
git add Shirox/Views/LibraryView.swift
git commit -m "feat(library): open profile for MAL avatar instead of logout-only dialog"
```

---

### Task 5: Identity-based ProfileView tabs; hide Favourites for MAL

**Files:**
- Modify: `Shirox/Views/Profile/ProfileView.swift`

- [ ] **Step 1: Add a ProfileTab enum**

In `Shirox/Views/Profile/ProfileView.swift`, add this enum above `struct ProfileView` (after the imports):

```swift
enum ProfileTab: CaseIterable {
    case activity, favourites, stats, social

    var title: String {
        switch self {
        case .activity:   return "Activity"
        case .favourites: return "Favourites"
        case .stats:      return "Stats"
        case .social:     return "Social"
        }
    }

    var icon: String {
        switch self {
        case .activity:   return "bubble.left.and.bubble.right"
        case .favourites: return "heart"
        case .stats:      return "chart.bar"
        case .social:     return "person.2"
        }
    }
}
```

- [ ] **Step 2: Change selectedTab to the enum and add availableTabs**

Find the state declaration (line 9):

```swift
    @State private var selectedTab = 0
```

Replace it with:

```swift
    @State private var selectedTab: ProfileTab = .activity
```

Then, directly after the `isOwnProfile` computed property (around lines 23-27), add:

```swift
    /// Tabs available for the active provider. MAL has no favourites data source,
    /// so that tab is omitted under MAL.
    private var availableTabs: [ProfileTab] {
        activeProviderType == .mal
            ? ProfileTab.allCases.filter { $0 != .favourites }
            : ProfileTab.allCases
    }
```

- [ ] **Step 3: Switch the content body on the enum**

Find the content switch (around lines 45-62):

```swift
                if selectedTab == 0 {
                    ProfileActivityView(vm: vm, userId: userId, topContent: scrollableHeader)
                } else if selectedTab == 1 {
                    ScrollView {
                        scrollableHeader
                        ProfileFavouritesView(favourites: vm.user?.favourites)
                    }
                } else if selectedTab == 2 {
                    ScrollView {
                        scrollableHeader
                        ProfileStatsView(
                            stats: vm.user?.statistics?.anime,
                            scoreFormat: activeProviderType == .anilist ? anilistAuth.scoreFormat : .point10
                        )
                    }
                } else if selectedTab == 3 {
                    ProfileSocialView(vm: vm, userId: userId, topContent: scrollableHeader)
                }
```

Replace it with:

```swift
                switch selectedTab {
                case .activity:
                    ProfileActivityView(vm: vm, userId: userId, topContent: scrollableHeader)
                case .favourites:
                    ScrollView {
                        scrollableHeader
                        ProfileFavouritesView(favourites: vm.user?.favourites)
                    }
                case .stats:
                    ScrollView {
                        scrollableHeader
                        ProfileStatsView(
                            stats: vm.user?.statistics?.anime,
                            scoreFormat: activeProviderType == .anilist ? anilistAuth.scoreFormat : .point10
                        )
                    }
                case .social:
                    ProfileSocialView(vm: vm, userId: userId, topContent: scrollableHeader)
                }
```

- [ ] **Step 4: Drive the tab bar from availableTabs**

Find the `tabBar` view (around lines 200-221):

```swift
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { idx, tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = idx }
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon).font(.caption)
                            Text(tab.title).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(selectedTab == idx ? Color.primary : .secondary)
                        Rectangle()
                            .fill(selectedTab == idx ? Color.primary : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }
```

Replace it with:

```swift
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(availableTabs, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon).font(.caption)
                            Text(tab.title).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(selectedTab == tab ? Color.primary : .secondary)
                        Rectangle()
                            .fill(selectedTab == tab ? Color.primary : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }
```

- [ ] **Step 5: Delete the now-unused `tabs` array**

Find and delete the old `tabs` computed property (around lines 223-230):

```swift
    private var tabs: [(title: String, icon: String)] {
        [
            ("Activity", "bubble.left.and.bubble.right"),
            ("Favourites", "heart"),
            ("Stats", "chart.bar"),
            ("Social", "person.2")
        ]
    }
```

Delete that entire property (its data now lives on `ProfileTab`).

- [ ] **Step 6: Reset to a valid tab if the provider changes while open**

Find the `.task { ... }` modifier on the body (around line 81). Immediately after it, add an `.onChangeOf` guard so a stale selection can't persist if the active provider flips:

```swift
        .onChangeOf(activeProviderType) { _ in
            if !availableTabs.contains(selectedTab) { selectedTab = .activity }
        }
```

(The project uses the custom `.onChangeOf(_:)` helper rather than SwiftUI's `.onChange`; match the surrounding code which already uses `.onChangeOf`.)

- [ ] **Step 7: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 8: Commit**

```bash
git add Shirox/Views/Profile/ProfileView.swift
git commit -m "feat(profile): identity-based tabs; hide Favourites under MAL"
```

---

### Task 6: Add "Make Primary" to Settings → Providers

**Files:**
- Modify: `Shirox/Views/SettingsView.swift`

- [ ] **Step 1: Add a Make Primary button to non-primary signed-in rows**

In `Shirox/Views/SettingsView.swift`, find the trailing `HStack` inside the provider row (around lines 890-901):

```swift
                    HStack(spacing: 8) {
                        if manager.orderedProviders.first?.providerType == provider.providerType {
                            Text("Primary")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.primary.opacity(0.1), in: Capsule())
                        }
                        #if os(iOS)
                        providerAuthButton(for: provider.providerType)
                        #endif
                    }
```

Replace it with a version that shows a "Make Primary" button on non-primary rows (only when that provider is signed in, so switching to it is meaningful):

```swift
                    HStack(spacing: 8) {
                        if manager.orderedProviders.first?.providerType == provider.providerType {
                            Text("Primary")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.primary.opacity(0.1), in: Capsule())
                        } else if isSignedIn(provider.providerType) {
                            Button("Make Primary") {
                                manager.selectProvider(provider.providerType)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .buttonStyle(.plain)
                        }
                        #if os(iOS)
                        providerAuthButton(for: provider.providerType)
                        #endif
                    }
```

- [ ] **Step 2: Add the isSignedIn helper**

In the same `ProvidersSettingsSection` struct, add this helper next to `providerStatus(_:)` (around line 949):

```swift
    private func isSignedIn(_ type: ProviderType) -> Bool {
        switch type {
        case .anilist: return aniListAuth.isLoggedIn
        case .mal:     return malAuth.isLoggedIn
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run the build command.
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 4: Commit**

```bash
git add Shirox/Views/SettingsView.swift
git commit -m "feat(settings): add Make Primary action to provider rows"
```

---

### Task 7: Manual verification

**Files:** none (verification only)

- [ ] **Step 1: Both services signed in — switcher behavior**

Sign into both AniList and MyAnimeList. Confirm:
- A segmented `AniList | MAL` control appears at the top of **Home** and **Library**.
- Tapping the other segment flips the active provider: Home content, Search results, and the Library list all reload to the selected service.
- **Settings → Providers** shows the same provider as "Primary," and a "Make Primary" button on the other (signed-in) row switches it.

- [ ] **Step 2: Single service — switcher hidden**

Sign out of one service. Confirm the segmented switcher no longer appears on Home or Library (nothing to switch).

- [ ] **Step 3: MAL profile**

With MAL active, tap your avatar in the Library toolbar. Confirm:
- The full `ProfileView` opens (not a logout dialog).
- Tabs shown are **Activity, Stats, Social** — **no Favourites tab**.
- Activity/Stats/Social populate with MAL data.
- Logout is available from the profile's toolbar (top-left), and logging out works.

- [ ] **Step 4: AniList profile unchanged**

With AniList active, tap your avatar. Confirm the profile still shows all four tabs (Activity, Favourites, Stats, Social) and behaves as before.

---

## Self-Review Notes

- **Spec coverage:** Global switcher component → Task 1; Home + Library placement → Tasks 2 & 3; Settings primary clarity + tap-to-select → Task 6; MAL avatar → ProfileView → Task 4; hide Favourites for MAL + keep write affordances gated (the follow button is already gated at ProfileView ~line 150; no new write affordances are introduced) → Task 5; notifications already MAL-hidden (no task needed, verified in Step-less audit) ; verification → Task 7 plus per-task builds.
- **Placeholder scan:** No TBD/TODO/"handle edge cases" placeholders; every code step shows full code.
- **Type consistency:** `ProviderSwitcher`, `ProviderType.allCases`/`.displayName`, `ProfileTab` (`.activity/.favourites/.stats/.social`, `.title`, `.icon`), `availableTabs`, `isSignedIn(_:)`, and `manager.selectProvider(_:)` are used consistently across tasks. `selectedTab` is `ProfileTab` everywhere after Task 5.
- **Deviation noted:** `ProviderSwitcher` lives in `ProviderStatusBanner.swift` (not a new file) to avoid manual pbxproj registration; same folder and cohesion.
