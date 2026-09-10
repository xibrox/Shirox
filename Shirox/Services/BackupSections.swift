import Foundation
import SwiftUI

// MARK: - Progress

struct ProgressBackupPayload: Codable {
    /// `ContinueWatchingManager`'s schema version. A backup from a different one is
    /// refused: the stored item shape differs, and `load()` wipes mismatched data.
    var dataVersion: Int
    var continueWatching: [ContinueWatchingItem]
    var watchedKeys: Set<String>
    var watchedHrefKeys: Set<String>
    var continueReading: [MangaReadingItem]
    var readChapters: [String: Set<String>]
    var watchHistory: [WatchProgress]
}

/// Continue Watching, Continue Reading, and watch history — the data users would be most
/// upset to lose.
struct ProgressBackupSection: BackupSection {
    typealias Payload = ProgressBackupPayload
    static var id: String { BackupSectionID.progress }

    @MainActor func export() throws -> ProgressBackupPayload? {
        let cw = ContinueWatchingManager.shared
        let manga = MangaProgressManager.shared
        return ProgressBackupPayload(
            dataVersion: ContinueWatchingManager.currentDataVersion,
            continueWatching: cw.items,
            watchedKeys: cw.watchedKeys,
            watchedHrefKeys: cw.watchedHrefKeys,
            continueReading: manga.items,
            readChapters: manga.readChapters,
            watchHistory: WatchHistoryService.shared.history)
    }

    @MainActor func apply(_ payload: ProgressBackupPayload) async throws -> [String] {
        guard payload.dataVersion == ContinueWatchingManager.currentDataVersion else {
            throw BackupSectionError.incompatibleDataVersion(
                found: payload.dataVersion,
                expected: ContinueWatchingManager.currentDataVersion)
        }
        ContinueWatchingManager.shared.restore(items: payload.continueWatching,
                                               watchedKeys: payload.watchedKeys,
                                               watchedHrefKeys: payload.watchedHrefKeys)
        MangaProgressManager.shared.restore(items: payload.continueReading,
                                            readChapters: payload.readChapters)
        WatchHistoryService.shared.restore(history: payload.watchHistory)
        return []
    }
}

// MARK: - Local Library

struct LocalLibraryBackupPayload: Codable {
    var entries: [LibraryEntry]
    var collections: [LocalCollection]
    var customListNames: [String]
    var individualSortPreferences: [String: Bool]
    /// Optional so a key the user never set stays unset on restore rather than being
    /// pinned to a default.
    var localScoreFormat: String?
    var localAutoTrackEnabled: Bool?
}

/// The user's own account-free library. For anyone not tracking through AniList or MAL
/// this is the only copy that exists.
struct LocalLibraryBackupSection: BackupSection {
    typealias Payload = LocalLibraryBackupPayload
    static var id: String { BackupSectionID.localLibrary }

    private enum Keys {
        static let customListNames = "libraryCustomListNames"
        static let sortPreferences = "individualSortPreferences"
        static let scoreFormat = "localScoreFormat"
        static let autoTrack = "localAutoTrackEnabled"
    }

    @MainActor func export() throws -> LocalLibraryBackupPayload? {
        let defaults = UserDefaults.standard
        let manager = LocalLibraryManager.shared
        return LocalLibraryBackupPayload(
            entries: manager.entries,
            collections: manager.collections,
            customListNames: defaults.stringArray(forKey: Keys.customListNames) ?? [],
            individualSortPreferences: defaults.dictionary(forKey: Keys.sortPreferences) as? [String: Bool] ?? [:],
            localScoreFormat: defaults.string(forKey: Keys.scoreFormat),
            localAutoTrackEnabled: defaults.object(forKey: Keys.autoTrack) == nil
                ? nil
                : defaults.bool(forKey: Keys.autoTrack))
    }

    @MainActor func apply(_ payload: LocalLibraryBackupPayload) async throws -> [String] {
        let defaults = UserDefaults.standard
        LocalLibraryManager.shared.restore(entries: payload.entries,
                                           collections: payload.collections)
        defaults.set(payload.customListNames, forKey: Keys.customListNames)
        defaults.set(payload.individualSortPreferences, forKey: Keys.sortPreferences)
        // These two are read straight from UserDefaults (or via @AppStorage, which observes
        // it) at each use, so writing the key is enough — no published state to refresh.
        if let format = payload.localScoreFormat { defaults.set(format, forKey: Keys.scoreFormat) }
        if let autoTrack = payload.localAutoTrackEnabled { defaults.set(autoTrack, forKey: Keys.autoTrack) }
        return []
    }
}

// MARK: - Settings

struct SubtitleBackupPayload: Codable {
    var enabled: Bool
    var fontSize: Double
    var shadowRadius: Double
    var backgroundEnabled: Bool
    var bottomPadding: Double
    var delaySeconds: Double
    /// r, g, b, a. Nil when the user never picked a colour.
    var colorRGBA: [Double]?
}

struct SettingsBackupPayload: Codable {
    var bools: [String: Bool]
    var ints: [String: Int]
    var doubles: [String: Double]
    var strings: [String: String]
    var subtitles: SubtitleBackupPayload?
}

/// Preferences, as an explicit allowlist rather than a dump of the UserDefaults domain —
/// a backup may be restored on different hardware, so device-local state stays out.
struct SettingsBackupSection: BackupSection {
    typealias Payload = SettingsBackupPayload
    static var id: String { BackupSectionID.settings }

    /// Deliberately excluded: `hasCompletedOnboarding` (a backup must not push a device
    /// back through onboarding, or skip it on one that never saw it),
    /// `hasRequestedDownloadNotifications` (a per-device permission prompt),
    /// `lastLandscapeOrientation`, `orientation`, `drawsBackground` (device/window local).
    /// `localScoreFormat` and `localAutoTrackEnabled` belong to the localLibrary section.
    static let boolKeys = [
        "aniListTrackingEnabled", "malTrackingEnabled", "dualSync",
        "autoDeleteWatched", "autoNextEpisode", "autoPickLastSearchResult",
        "autoPickLastStream", "autoResumeDownloads", "autoSkipSegments",
        "backgroundDownloadsEnabled", "defaultReverseSort", "forceLandscape",
        "librarySortAscending", "playerLiquidGlass", "rateOnFinish",
        "readerLiquidGlass", "skipReWatchTracking", "useDefaultExtension",
        "dataSaverEnabled"
    ]

    static let intKeys = [
        "maxConcurrentDownloads", "playerSkipLong", "playerSkipShort", "speedBoostTolerance"
    ]

    static let doubleKeys = ["mangaAutoScrollSpeed", "watchedPercentage"]

    static let stringKeys = [
        "librarySortOrder", "libraryStatusOrder", "mangaReadingMode",
        "preferredQuality", "titleLanguagePriority"
    ]

    private enum SubtitleKeys {
        static let colorR = "subtitle.color.r"
        static let colorG = "subtitle.color.g"
        static let colorB = "subtitle.color.b"
        static let colorA = "subtitle.color.a"
    }

    @MainActor func export() throws -> SettingsBackupPayload? {
        let d = UserDefaults.standard
        // `object(forKey:)` gates each read so a key the user never set is omitted, and a
        // restore then leaves it unset instead of pinning it to a default.
        var bools: [String: Bool] = [:]
        for key in Self.boolKeys where d.object(forKey: key) != nil { bools[key] = d.bool(forKey: key) }
        var ints: [String: Int] = [:]
        for key in Self.intKeys where d.object(forKey: key) != nil { ints[key] = d.integer(forKey: key) }
        var doubles: [String: Double] = [:]
        for key in Self.doubleKeys where d.object(forKey: key) != nil { doubles[key] = d.double(forKey: key) }
        var strings: [String: String] = [:]
        for key in Self.stringKeys {
            if let value = d.string(forKey: key) { strings[key] = value }
        }

        let subtitles = SubtitleSettingsManager.shared
        let color: [Double]? = d.object(forKey: SubtitleKeys.colorR) == nil ? nil : [
            d.double(forKey: SubtitleKeys.colorR), d.double(forKey: SubtitleKeys.colorG),
            d.double(forKey: SubtitleKeys.colorB), d.double(forKey: SubtitleKeys.colorA)
        ]

        return SettingsBackupPayload(
            bools: bools,
            ints: ints,
            doubles: doubles,
            strings: strings,
            subtitles: SubtitleBackupPayload(
                enabled: subtitles.enabled,
                fontSize: subtitles.fontSize,
                shadowRadius: subtitles.shadowRadius,
                backgroundEnabled: subtitles.backgroundEnabled,
                bottomPadding: subtitles.bottomPadding,
                delaySeconds: subtitles.delaySeconds,
                colorRGBA: color))
    }

    @MainActor func apply(_ payload: SettingsBackupPayload) async throws -> [String] {
        let d = UserDefaults.standard
        for (key, value) in payload.bools where Self.boolKeys.contains(key) { d.set(value, forKey: key) }
        for (key, value) in payload.ints where Self.intKeys.contains(key) { d.set(value, forKey: key) }
        for (key, value) in payload.doubles where Self.doubleKeys.contains(key) { d.set(value, forKey: key) }
        for (key, value) in payload.strings where Self.stringKeys.contains(key) { d.set(value, forKey: key) }

        // SubtitleSettingsManager persists through `didSet` on each published property, so
        // assigning the properties is both the refresh and the write. Writing its
        // UserDefaults keys directly would leave the published values stale — the same bug
        // BackupSection exists to avoid, in reverse.
        if let s = payload.subtitles {
            let manager = SubtitleSettingsManager.shared
            manager.enabled = s.enabled
            manager.fontSize = s.fontSize
            manager.shadowRadius = s.shadowRadius
            manager.backgroundEnabled = s.backgroundEnabled
            manager.bottomPadding = s.bottomPadding
            manager.delaySeconds = s.delaySeconds
            if let c = s.colorRGBA, c.count == 4 {
                manager.foregroundColor = Color(red: c[0], green: c[1], blue: c[2], opacity: c[3])
            }
        }
        return []
    }
}
