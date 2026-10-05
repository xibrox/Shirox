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
    /// Shows remembered at most; the longest unplayed go first.
    private static let limit = 300

    /// One show, however it's played: AniList, MyAnimeList or Simkl id, else its title.
    static func showKey(for context: PlayerContext?) -> String? {
        guard let context else { return nil }
        if let id = context.aniListID { return "al:\(id)" }
        if let id = context.malID { return "mal:\(id)" }
        if let ref = context.simklTitle { return "simkl:\(ref.simklID)" }
        let title = context.mediaTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title.isEmpty ? nil : "title:\(title)"
    }

    static func choice(for key: String?) -> TrackChoice? {
        guard let key else { return nil }
        return stored()[key]?.choice
    }

    static func rememberAudio(_ title: String, for key: String?) {
        update(key) { $0.audio = title }
    }

    /// nil forgets the subtitle pick, for the source's default.
    static func rememberSubtitle(_ subtitle: TrackChoice.SubtitleChoice?, for key: String?) {
        update(key) { $0.subtitle = subtitle }
    }

    // MARK: - Matching

    /// The audio track to switch to: the remembered one, when it's offered and not already on.
    nonisolated static func audioToRestore(_ remembered: String?, options: [PlaybackAudioOption],
                                           selected: PlaybackAudioOption.ID?) -> PlaybackAudioOption.ID? {
        guard let remembered, let match = options.first(where: { same($0.title, remembered) }),
              match.id != selected else { return nil }
        return match.id
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

    private static func update(_ key: String?, _ change: (inout TrackChoice) -> Void) {
        guard let key else { return }
        var all = stored()
        var choice = all[key]?.choice ?? TrackChoice()
        change(&choice)
        all[key] = Stored(choice: choice, updated: Date())
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
