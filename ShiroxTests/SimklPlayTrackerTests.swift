import XCTest
@testable import Shirox

final class SimklPlayTrackerTests: XCTestCase {

    private func ep(_ season: Int, _ number: Int) -> SimklEpisode {
        SimklEpisode(season: season, episode: number, title: nil, aired: true, img: nil, date: nil,
                     isSpecial: false, simklID: season * 100 + number)
    }

    private lazy var catalog = [ep(1, 1), ep(1, 2), ep(1, 3), ep(2, 1), ep(2, 2)]

    private func show(status: MediaListStatus, watched: [SimklSeasonWatch]) -> LibraryEntry {
        var entry = SimklTitleCopy.entry(simklID: 7, kind: .tv, title: "S", posterURL: nil, year: nil,
                                         runtime: nil, totalEpisodes: 5, status: status)
        entry.watchedEpisodes = watched
        return entry
    }

    private let season2 = SimklPlayRef(simklID: 7, kind: .tv, season: 2)

    func testFinishingAnEpisodeTicksIt() {
        let change = SimklPlayTracker.change(
            for: season2, number: 1,
            entry: show(status: .current, watched: [SimklSeasonWatch(season: 1, episodes: [1, 2, 3])]),
            episodes: catalog)
        XCTAssertEqual(change?.status, .current)
        XCTAssertEqual(change?.plan?.marks, [SimklSeasonMark(number: 2, episodes: [1])])
        XCTAssertEqual(change?.plan?.watched.contains(SimklEpisodeRef(season: 2, episode: 1)), true)
    }

    func testAPlanToWatchShowBecomesWatching() {
        XCTAssertEqual(SimklPlayTracker.change(for: season2, number: 1, entry: show(status: .planning, watched: []),
                                               episodes: catalog)?.status, .current)
        XCTAssertEqual(SimklPlayTracker.change(for: season2, number: 1, entry: nil, episodes: catalog)?.status, .current)
    }

    /// Up Next on a page listing every season runs past season 1's end.
    func testUpNextPastASeasonsEndTicksTheNextSeason() {
        let change = SimklPlayTracker.change(for: SimklPlayRef(simklID: 7, kind: .tv, season: 1), number: 4,
                                             entry: nil, episodes: catalog)
        XCTAssertEqual(change?.plan?.marks, [SimklSeasonMark(number: 2, episodes: [1])])
    }

    func testNothingIsSentTwiceOrBlind() {
        XCTAssertNil(SimklPlayTracker.change(
            for: season2, number: 1,
            entry: show(status: .current, watched: [SimklSeasonWatch(season: 2, episodes: [1])]), episodes: catalog),
            "already ticked")
        XCTAssertNil(SimklPlayTracker.change(for: season2, number: 9, entry: nil, episodes: catalog),
                     "not in the catalog")
        let movie = SimklPlayRef(simklID: 9, kind: .movie, season: nil)
        XCTAssertEqual(SimklPlayTracker.change(for: movie, number: 1, entry: nil, episodes: []),
                       SimklPlayTracker.Change(status: .completed, plan: nil))
        let watchedMovie = SimklTitleCopy.entry(simklID: 9, kind: .movie, title: "M", posterURL: nil, year: nil,
                                                runtime: nil, totalEpisodes: nil, status: .completed)
        XCTAssertNil(SimklPlayTracker.change(for: movie, number: 1, entry: watchedMovie, episodes: []))
    }

    /// A rating is asked for at the end of a film, or of a show that has finished airing.
    func testOnlyAFilmOrAFinishedShowsLastEpisodeFinishesTheTitle() {
        XCTAssertTrue(SimklPlayTracker.finishesTitle(SimklPlayRef(simklID: 9, kind: .movie, season: nil),
                                                     number: 1, episodes: []))
        XCTAssertTrue(SimklPlayTracker.finishesTitle(season2, number: 2, episodes: catalog))
        XCTAssertFalse(SimklPlayTracker.finishesTitle(season2, number: 1, episodes: catalog))
        XCTAssertFalse(SimklPlayTracker.finishesTitle(SimklPlayRef(simklID: 7, kind: .tv, season: 1),
                                                      number: 3, episodes: catalog), "a season's end")
        var airing = catalog
        airing.append(SimklEpisode(season: 2, episode: 3, title: nil, aired: false, img: nil, date: nil,
                                   isSpecial: false, simklID: 203))
        XCTAssertFalse(SimklPlayTracker.finishesTitle(season2, number: 2, episodes: airing), "more to come")
    }
}
