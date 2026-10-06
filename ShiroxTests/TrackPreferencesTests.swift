import XCTest
@testable import Shirox

/// The audio and subtitle tracks picked on one episode, found again on the next.
@MainActor
final class TrackPreferencesTests: XCTestCase {

    private let audio = [PlaybackAudioOption(id: 1, title: "Japanese"),
                         PlaybackAudioOption(id: 2, title: "English (US)")]

    /// Track numbers differ from file to file; names don't.
    func testTheRememberedAudioIsFoundByName() {
        XCTAssertEqual(TrackPreferences.audioToRestore("english (us)", options: audio), 2)
    }

    /// One that reads as on already is still picked: AVPlayer moves off a track it only chose
    /// by default.
    func testAudioThatLooksOnIsStillPicked() {
        XCTAssertEqual(TrackPreferences.audioToRestore("Japanese", options: audio), 1)
    }

    func testMissingAudioIsLeftAlone() {
        XCTAssertNil(TrackPreferences.audioToRestore("German", options: audio))
        XCTAssertNil(TrackPreferences.audioToRestore(nil, options: audio))
    }

    func testASubtitleIsFoundOnlyWhereItWasPicked() {
        let url = URL(string: "https://cdn.example/en.ass")!
        let tracks = [SubtitleTrack(title: "English", url: url, headers: [:]),
                      SubtitleTrack(title: "Signs & Songs", url: url, headers: [:])]
        let embedded = [PlaybackSubtitleOption(id: 3, title: "English"),
                        PlaybackSubtitleOption(id: 4, title: "Signs & Songs")]

        XCTAssertEqual(TrackPreferences.externalTrack(.external("Signs & Songs"), in: tracks)?.title, "Signs & Songs")
        XCTAssertNil(TrackPreferences.externalTrack(.embedded("English"), in: tracks))
        XCTAssertNil(TrackPreferences.externalTrack(.external("French"), in: tracks))

        XCTAssertEqual(TrackPreferences.embeddedTrack(.embedded("signs & songs"), in: embedded), 4)
        XCTAssertNil(TrackPreferences.embeddedTrack(.external("English"), in: embedded))
    }

    private func context(aniList: Int? = nil, mal: Int? = nil, title: String) -> PlayerContext {
        PlayerContext(mediaTitle: title, episodeNumber: 1, episodeTitle: nil, imageUrl: "",
                      aniListID: aniList, malID: mal, moduleId: nil, totalEpisodes: nil,
                      availableEpisodes: nil, isAiring: nil, resumeFrom: nil, detailHref: nil,
                      episodeHref: nil, streamTitle: nil, workingDetailHref: nil, thumbnailUrl: nil)
    }

    /// A show goes by its ids and its title, whichever it was opened with.
    func testAShowGoesByEveryIdItHasAndItsTitle() {
        XCTAssertEqual(TrackPreferences.showKeys(for: context(aniList: 5, mal: 6, title: "A")),
                       ["al:5", "mal:6", "title:a"])
        XCTAssertEqual(TrackPreferences.showKeys(for: context(mal: 6, title: "A")), ["mal:6", "title:a"])
        XCTAssertEqual(TrackPreferences.showKeys(for: context(title: " Frieren ")), ["title:frieren"])
        XCTAssertEqual(TrackPreferences.showKeys(for: nil), [])
    }

    /// Reported: the audio picked while streaming wasn't there when the show was opened again
    /// from Continue Watching. The module page it was first played from hadn't matched AniList
    /// yet; the card it left had. A pick under the title is found under the id too.
    func testAPickMadeUnderTheTitleIsFoundWithTheId() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "trackChoices")
        defer { defaults.set(saved, forKey: "trackChoices") }
        defaults.removeObject(forKey: "trackChoices")

        let title = "Track Memory Test \(UUID().uuidString)"
        TrackPreferences.rememberAudio("English", for: TrackPreferences.showKeys(for: context(title: title)))
        // Played again with its id known: the pick is found and kept under both.
        let matched = TrackPreferences.showKeys(for: context(aniList: 99_999_001, title: title))
        XCTAssertEqual(TrackPreferences.choice(for: matched)?.audio, "English")
        TrackPreferences.rememberSubtitle(.external("English"), for: matched)
        // Then opened from a card that has only the id.
        let card = TrackPreferences.showKeys(for: context(aniList: 99_999_001, title: "Another Title"))
        XCTAssertEqual(TrackPreferences.choice(for: card), TrackChoice(audio: "English", subtitle: .external("English")))
    }

    /// The latest pick wins wherever the show's names disagree.
    func testTheLatestPickWins() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "trackChoices")
        defer { defaults.set(saved, forKey: "trackChoices") }
        defaults.removeObject(forKey: "trackChoices")

        TrackPreferences.rememberAudio("Japanese", for: ["title:x"])
        TrackPreferences.rememberAudio("English", for: ["al:1"])
        XCTAssertEqual(TrackPreferences.choice(for: ["al:1", "title:x"])?.audio, "English")
    }

    /// mpv lists each variant's own audio beside the renditions; a name two tracks share
    /// doesn't say which one was meant.
    func testANameTwoTracksShareIsLeftAlone() {
        let options = [PlaybackAudioOption(id: 1, title: "Japanese"),
                       PlaybackAudioOption(id: 2, title: "Japanese"),
                       PlaybackAudioOption(id: 3, title: "English")]
        XCTAssertNil(TrackPreferences.audioToRestore("Japanese", options: options))
        XCTAssertEqual(TrackPreferences.audioToRestore("English", options: options), 3)
    }
}
