import XCTest
@testable import Shirox

/// The audio and subtitle tracks picked on one episode, found again on the next.
@MainActor
final class TrackPreferencesTests: XCTestCase {

    private let audio = [PlaybackAudioOption(id: 1, title: "Japanese"),
                         PlaybackAudioOption(id: 2, title: "English (US)")]

    /// Track numbers differ from file to file; names don't.
    func testTheRememberedAudioIsFoundByName() {
        XCTAssertEqual(TrackPreferences.audioToRestore("english (us)", options: audio, selected: 1), 2)
    }

    func testAudioAlreadyOnOrMissingIsLeftAlone() {
        XCTAssertNil(TrackPreferences.audioToRestore("English (US)", options: audio, selected: 2))
        XCTAssertNil(TrackPreferences.audioToRestore("German", options: audio, selected: 1))
        XCTAssertNil(TrackPreferences.audioToRestore(nil, options: audio, selected: 1))
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

    /// The same show by any route: its ids first, its title when it has none.
    func testAShowIsKeyedByItsIdsBeforeItsTitle() {
        func context(aniList: Int? = nil, mal: Int? = nil, title: String) -> PlayerContext {
            PlayerContext(mediaTitle: title, episodeNumber: 1, episodeTitle: nil, imageUrl: "",
                          aniListID: aniList, malID: mal, moduleId: nil, totalEpisodes: nil,
                          availableEpisodes: nil, isAiring: nil, resumeFrom: nil, detailHref: nil,
                          episodeHref: nil, streamTitle: nil, workingDetailHref: nil, thumbnailUrl: nil)
        }
        XCTAssertEqual(TrackPreferences.showKey(for: context(aniList: 5, mal: 6, title: "A")), "al:5")
        XCTAssertEqual(TrackPreferences.showKey(for: context(mal: 6, title: "A")), "mal:6")
        XCTAssertEqual(TrackPreferences.showKey(for: context(title: " Frieren ")), "title:frieren")
        XCTAssertNil(TrackPreferences.showKey(for: nil))
    }
}
