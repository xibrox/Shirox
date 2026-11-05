# Shirox: notes for working on the code

Shirox is a SwiftUI app for iPhone, iPad, Mac (native and Catalyst) and Apple TV: an anime and manga
library with tracking (AniList, MyAnimeList, Simkl), Jellyfin, and playback/reading from modules.

## Targets and building

- Four schemes: `Shirox_iOS`, `Shirox_macOS`, `Shirox_tvOS`, `Shirox_MacCatalyst`. Deployment targets
  are iOS 15, macOS 14 and tvOS 18.6, so newer API needs `#available` and older systems a fallback.
- A change is done when all four build with no errors and no warnings:
  ```bash
  xcodebuild -scheme Shirox_iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DDMacDbg build
  ```
  (and `Shirox_macOS` with `platform=macOS`, `Shirox_tvOS` with `generic/platform=tvOS Simulator`,
  `Shirox_MacCatalyst` with `platform=macOS,variant=Mac Catalyst`). See BUILDING.txt for the release
  scripts. `buildipa.sh` makes the release IPA (no coverage, stripped, dSYMs kept in `build/dSYMs`).
- Don't boot simulators; changes are tested on real devices.
- The project has no synchronized folders: a new file must be added to `Shirox.xcodeproj` with
  `ruby scripts/xcode_register.rb source <path>` (or `resource`, `test`), removed with
  `scripts/xcode_unregister.rb`.
- Shared build settings live in `Configurations/Shirox.xcconfig`; your own team and bundle id go in
  `Configurations/Shirox.local.xcconfig` (gitignored, from the `.template`).
- Versions: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project (all configurations),
  and a new entry at the top of `apps.json` with the release notes. The nightly workflow fills in
  the size and date.

## Localization

- Every user-facing string is a key in `Shirox/Localizable.xcstrings`, never hardcoded text:
  `Text("settings.general")`, `String(localized: "library.no_matching \(noun) \(query)")`.
- Keys are `area.up_to_five_words`, lowercase with underscores. Areas: app, common, settings, player,
  reader, downloads, library, profile, onboarding, simkl, home, search, jellyfin, modules, detail,
  shared. Text used across areas goes under `common.`.
- Arguments stay in the key as interpolations, and the catalog holds the whole sentence with
  specifiers (`"Download %lld Episodes"`). Never glue a sentence together from pieces (`verb + noun`,
  `"Watch" + " Movie"`): write one key per whole sentence so it can be translated.
- Counts use plural variations in the catalog. A ternary between two keys needs
  `LocalizedStringKey(…)` or `String(localized:)` on each side, or SwiftUI shows the key itself.
- 14 languages ship: en, de, es, pt-BR, fr, it, id, tr, vi, pl, ru, zh-Hans, ja, th. A new key needs all
  of them (German uses informal "du"). No right-to-left languages yet.
- Tooling, all in `scripts/i18n/i18n.py` (its header explains each): `check` (no hardcoded text,
  every key has English), `extract`, `sync`, `dedupe`, `rename`, `import LANG FILE`, `loose`.
  `scripts/i18n/add_strings.py FILE.json` adds hand-written keys in several languages at once.
- Don't localize API values, identifiers, UserDefaults keys, log messages or proper names
  (AniList, Simkl, TMDB…). Never compare a localized string with data from a server.

## Icons and icon packs

- Icons go through the icon pack in use: `IconView("house.fill")` in the app's own views (sized by
  the font like the symbol), `Image(icon:)` where an `Image` is needed (tab bars, menus,
  `Text(Image(...))`), `Label("key", icon:)` for labels. Don't use `Image(systemName:)` directly.
- Write SF Symbol names out as literals, never built at runtime (`"gobackward.\(n)"`), so the icon
  list sees them.
- `scripts/icons/icons.py update` regenerates `iconpacks/icons.json` (and `IconManifest.swift`);
  its version goes up whenever the set of icons changes. A pack loads only for the version it was
  made for. After a change, update the packs in `iconpacks/` (their `svg/` sources), run
  `icons.py build <pack>`, and check them with `icons.py packs`.
- Pack format and update flow are described at the top of `scripts/icons/icons.py`.

## Settings, accounts, backups

- A new setting stored in UserDefaults that should travel with a backup goes into the allowlists
  in `Services/BackupSections.swift`. Device-local state stays out.
- A new Keychain item goes into `FreshInstallKeychainPurge.accounts` (it also drives profile
  switching). Sign-ins with rotating refresh tokens (Simkl, Discord) aren't put in backups.
- Settings pages use `SettingsList`, `.switchTint()` on toggles, `.appTint()` for tint, and a short
  explanation as a section footer or a caption row under its toggle.

## Git hooks, CI and commits

- `scripts/install-hooks.sh` points git at `.githooks`. pre-commit blocks hidden Unicode, runs the
  i18n and icon checks on staged Swift files, and Semgrep when installed; commit-msg runs
  `scripts/check-commit-msg.sh`.
- Commit messages: no em dashes, no emoji, no hidden characters, no Co-Authored-By or "Generated
  with" lines. A short subject ("Area: what changed"), then why in plain sentences.
- CI: commit messages, Semgrep, Strings and icons (`i18n.py check`, `icons.py check`), SwiftLint
  (fails on any finding, or when `swiftlint --fix` would still change something), and the nightly
  build that publishes the IPA and updates `apps.json`.

## Code style

- Match the surrounding code: comments say why, in plain sentences; `#if os(…)` per platform;
  no new warnings, and fix the ones you come across.
- SwiftLint (`.swiftlint.yml`) reports nothing: run `swiftlint --fix`, then `swiftlint lint`, before
  committing, and keep it at zero. `identifier_name` and the length and size rules are off for now.
- Concurrency: shared services are `@MainActor` singletons; constants read off the main actor are
  `nonisolated`; don't hold an `NSLock` across `await`.
