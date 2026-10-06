import Foundation

/// The audio and subtitle tracks picked for a show, so its next episode — played on from the
/// player or opened later — starts on them. Tracks are matched by name: their numbers mean
/// nothing from one file to the next.
struct TrackChoice: Codable, Equatable {
    var audio: String?
    var subtitle: SubtitleChoice?

    enum SubtitleChoice: Codable, Equatable {
        /// A track the source lists beside the video.
        case external(String)
        /// A track inside the file, which MPV draws.
        case embedded(String)
    }
}

@MainActor
enum TrackPreferences {
    private static let defaultsKey = "trackChoices"
    /// Entries kept at most (a show has up to four); the longest unplayed go first.
    private static let limit = 900

    /// Every name one show goes by: its AniList, MyAnimeList and Simkl ids, and its title. A
    /// pick is stored under all of them and found by any, since the same show is opened with
    /// different ones: a module page before it's matched to AniList has only its title, while
    /// the Continue Watching card it leaves has the AniList id.
    static func showKeys(for context: PlayerContext?) -> [String] {
        guard let context else { return [] }
        var keys: [String] = []
        if let id = context.aniListID { keys.append("al:\(id)") }
        if let id = context.malID { keys.append("mal:\(id)") }
        if let ref = context.simklTitle { keys.append("simkl:\(ref.simklID)") }
        let title = context.mediaTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !title.isEmpty { keys.append("title:\(title)") }
        return keys
    }

    /// The latest pick stored under any of the show's names.
    static func choice(for keys: [String]) -> TrackChoice? {
        let all = stored()
        return keys.compactMap { all[$0] }.max { $0.updated < $1.updated }?.choice
    }

    static func rememberAudio(_ title: String, for keys: [String]) {
        update(keys) { $0.audio = title }
    }

    /// nil forgets the subtitle pick, for the source's default.
    static func rememberSubtitle(_ subtitle: TrackChoice.SubtitleChoice?, for keys: [String]) {
        update(keys) { $0.subtitle = subtitle }
    }

    // MARK: - Matching

    /// The audio track to select: the wanted one, when it's offered under that name alone. Two
    /// tracks of one name (mpv lists each variant's own audio) say nothing about which was meant.
    ///
    /// Selected even when it reads as on already. While an item loads, AVPlayer reports the
    /// stream's default, then moves to the device's language as it turns ready unless a track
    /// was picked outright. A remembered Japanese on a stream that starts on Japanese was left
    /// be, and the episode played in English. Switching once it's ready instead wedged a
    /// downloaded episode on its loading screen.
    nonisolated static func audioToRestore(_ wanted: String?, options: [PlaybackAudioOption]) -> PlaybackAudioOption.ID? {
        guard let wanted else { return nil }
        let matches = options.filter { same($0.title, wanted) }
        guard matches.count == 1 else { return nil }
        return matches.first?.id
    }

    nonisolated static func externalTrack(_ remembered: TrackChoice.SubtitleChoice?,
                                          in tracks: [SubtitleTrack]) -> SubtitleTrack? {
        guard case .external(let title) = remembered else { return nil }
        return tracks.first { same($0.title, title) }
    }

    nonisolated static func embeddedTrack(_ remembered: TrackChoice.SubtitleChoice?,
                                          in options: [PlaybackSubtitleOption]) -> PlaybackSubtitleOption.ID? {
        guard case .embedded(let title) = remembered else { return nil }
        return options.first { same($0.title, title) }?.id
    }

    private nonisolated static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    // MARK: - Storage

    private struct Stored: Codable {
        var choice: TrackChoice
        var updated: Date
    }

    private static func stored() -> [String: Stored] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Stored].self, from: data) else { return [:] }
        return decoded
    }

    private static func update(_ keys: [String], _ change: (inout TrackChoice) -> Void) {
        guard !keys.isEmpty else { return }
        var all = stored()
        // Starting from the latest, so a name that's only now known takes the whole pick.
        var choice = keys.compactMap { all[$0] }.max { $0.updated < $1.updated }?.choice ?? TrackChoice()
        change(&choice)
        let now = Date()
        for key in keys { all[key] = Stored(choice: choice, updated: now) }
        if all.count > limit {
            for (old, _) in all.sorted(by: { $0.value.updated < $1.value.updated }).prefix(all.count - limit) {
                all.removeValue(forKey: old)
            }
        }
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
