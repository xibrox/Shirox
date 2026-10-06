import XCTest
@testable import Shirox

/// "Download Next": which download goes first, and which running one makes room for it.
@MainActor
final class DownloadPriorityTests: XCTestCase {

    private func item(_ title: String, state: DownloadState = .pending, progress: Double = 0) -> DownloadItem {
        DownloadItem(id: UUID(), mediaTitle: title, episodeNumber: 1, episodeTitle: nil, imageUrl: "",
                     aniListID: nil, moduleId: nil, detailHref: nil, episodeHref: title, streamTitle: nil,
                     streamURL: URL(string: "https://cdn.test/\(title).m3u8"), headers: [:],
                     state: state, progress: progress, createdAt: Date())
    }

    /// The queue starts waiting downloads in list order, so the one picked goes first.
    func testThePickedDownloadGoesToTheFront() {
        let a = item("a"), b = item("b"), c = item("c")
        XCTAssertEqual(DownloadManager.movingToFront(c.id, in: [a, b, c]).map(\.mediaTitle), ["c", "a", "b"])
        XCTAssertEqual(DownloadManager.movingToFront(UUID(), in: [a, b]).map(\.mediaTitle), ["a", "b"])
    }

    /// Requested: episodes picked to go next shouldn't wait for a whole movie. The running
    /// download with the most left makes room.
    func testTheDownloadFurthestFromDoneMakesRoom() {
        let movie = item("movie", state: .downloading, progress: 0.1)
        let episode = item("ep", state: .downloading, progress: 0.8)
        XCTAssertEqual(DownloadManager.downloadToYield(running: [episode, movie], keeping: [])?.id, movie.id)
    }

    /// Picking a second one doesn't stop the first one picked.
    func testAPickedDownloadIsNeverStoppedForAnother() {
        let picked = item("picked", state: .downloading, progress: 0)
        let other = item("other", state: .downloading, progress: 0.9)
        XCTAssertEqual(DownloadManager.downloadToYield(running: [picked, other], keeping: [picked.id])?.id, other.id)
        XCTAssertNil(DownloadManager.downloadToYield(running: [picked], keeping: [picked.id]))
    }
}
