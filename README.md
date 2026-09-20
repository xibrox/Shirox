<div align="center">

# 白 Shirox

**Your anime and manga library, entirely yours.**

A free, source-available library manager for iPhone, iPad and Mac. Track what you watch and read,
keep it in sync with AniList and MyAnimeList, and play it from the sources *you* connect.

<p align="center">
  <a href="https://github.com/xibrox/Shirox/releases"><img src="https://img.shields.io/badge/platform-iOS%2015%2B%20%7C%20iPadOS%20%7C%20macOS-black?style=flat-square&logo=apple&logoColor=white" alt="Platform" /></a>
  <a href="https://github.com/xibrox/Shirox/releases"><img src="https://img.shields.io/badge/version-1.0.4-ef4444?style=flat-square" alt="Version" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-PolyForm%20NC%201.0.0-blue?style=flat-square" alt="License" /></a>
  <a href="https://discord.com/invite/b9tZSuJj73"><img src="https://img.shields.io/badge/discord-join-5865F2?style=flat-square&logo=discord&logoColor=white" alt="Discord" /></a>
</p>

<p align="center">
  <a href="#features">Features</a> · <a href="#on-ipad-and-mac">iPad & Mac</a> · <a href="#modules">Modules</a> · <a href="#build-from-source">Build from source</a>
</p>

<br />

<p align="center">
  <img src="docs/screenshots/home.png" width="23%" alt="Home" />
  <img src="docs/screenshots/library.png" width="23%" alt="Library" />
  <img src="docs/screenshots/detail.png" width="23%" alt="Detail" />
  <img src="docs/screenshots/player.png" width="23%" alt="Player" />
</p>

</div>

---

## What it is

Shirox ships with no content of its own. It's a native SwiftUI shell around three things you bring:
your **tracker account** (AniList or MyAnimeList), your **sources** (modules, a Jellyfin
server, or files on your device), and your **library**. Everything else — progress, downloads,
playback, reading — happens on your device.

> [!NOTE]
> Shirox does not host, provide or endorse any content.

---

## Features

### Tracking
- AniList and MyAnimeList side by side, with per-provider toggles for what gets written where
- Anime and manga in one library, with season-aware progress across multi-season and continuous releases
- Continue Watching and Continue Reading pick up mid-episode and mid-chapter
- Writes queue on disk when you're offline or rate-limited, and flush on the next launch
- Social: profiles, activity feeds, likes, replies, follows and notifications

### Sources
- Modules — JavaScript content providers you install from a URL
- Jellyfin: connect your own server and browse it as a native library
- Local files: play media stored on your device, organized into your own collections

### Player
- Picture-in-Picture, AirPlay and Chromecast
- Subtitles with adjustable size, color, shadow, position and timing offset
- Source, quality, audio track and playback speed from menus in the player bar
- Skip intro and outro where timestamps exist, plus auto-advance into the next episode or sequel
- The next episode's stream is resolved before you need it

### Offline
- HLS episode downloads on a background session, so they keep running once you leave the app
- Manga chapter downloads, single or batched by range
- Downloaded titles browse, play and read with no network at all

### On every screen
- Native SwiftUI throughout, in light and dark
- Home Screen quick actions straight into Search, Downloads or Library
- Adult titles filtered out of module search results by default
- Image and library caches you can inspect and clear from Settings

---

## On iPad and Mac

The same app, not a stretched phone layout: a top bar and a Mac sidebar in place of the tab bar,
wider grids, and full-screen playback.

<br />

<div align="center">
  <img src="docs/screenshots/ipad-home.png" width="32%" alt="Home on iPad" />
  <img src="docs/screenshots/ipad-library.png" width="32%" alt="Library on iPad" />
  <img src="docs/screenshots/ipad-player.png" width="32%" alt="Player on iPad" />
</div>

---

## Modules

Modules are small JSON manifests pointing at a JavaScript file that knows how to search a site and
resolve streams or chapters. Add one under **Settings → Modules** by pasting its manifest URL.

Two first-party modules cover the sources that aren't websites:

| Module | Manifest |
| :--- | :--- |
| **Local files** | `https://raw.githubusercontent.com/xibrox/local-files-module/refs/heads/main/local.json` |
| **Jellyfin** | `https://raw.githubusercontent.com/xibrox/jellyfin-module/refs/heads/main/jellyfin.json` |

---

## Build from source

Requires macOS with Xcode 16 or newer. There is no CocoaPods step — dependencies are Swift
Packages and Xcode resolves them on first open.

```bash
git clone https://github.com/xibrox/Shirox.git
cd Shirox
open Shirox.xcodeproj
```

Pick a scheme and run:

| Scheme | Target | Notes |
| :--- | :--- | :--- |
| `Shirox_iOS` | iPhone and iPad | iOS 15+ |
| `Shirox_MacCatalyst` | Mac | macOS 14+ |
| `Shirox_macOS` | Mac | native macOS, in progress |
| `Shirox_tvOS` | Apple TV | tvOS, in progress |

Or use the release scripts directly:

```bash
./buildipa.sh       # IPA
./buildcatalyst.sh  # Catalyst DMG
./builddmg.sh       # native macOS DMG
```

### Dependencies

| Dependency | Purpose |
| :--- | :--- |
| [Kingfisher](https://github.com/onevcat/Kingfisher) | Image caching |
| [google-cast-spm](https://github.com/castlabs/google-cast-spm) | Chromecast |
| [FakeWebKit](https://github.com/undeaDD/FakeWebKit) | Sources behind Cloudflare |

---

## Contributing

Issues and pull requests are welcome — bugs, features, modules, docs. Branch off `main`, keep
[SwiftLint](.swiftlint.yml) happy, and open a PR describing what changed and how you tested it.

---

## Community and support

Join the [Discord](https://discord.com/invite/b9tZSuJj73) for help and build
announcements. If Shirox is useful to you, you can support it on [Ko-fi](https://ko-fi.com/xibrox).

<br />

<p align="center">
  <a href="https://discord.com/invite/b9tZSuJj73"><img src="https://img.shields.io/badge/Discord-Join%20Server-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Discord" /></a>
  &nbsp;&nbsp;
  <a href="https://ko-fi.com/xibrox"><img src="https://img.shields.io/badge/Ko--fi-Support%20Author-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white" alt="Ko-fi" /></a>
</p>

---

## License

[PolyForm Noncommercial License 1.0.0](LICENSE). Free to use, modify and share for any purpose
other than commercial use.

---

<div align="center">

Built by [xibrox](https://github.com/xibrox)

</div>
