import XCTest
@testable import Shirox

/// What a download left mid-way by a closed app becomes at the next launch.
@MainActor
final class DownloadLaunchStateTests: XCTestCase {

    private func item(_ url: String, state: DownloadState = .downloading, task: Int? = nil,
                      fileName: String? = nil) -> DownloadItem {
        var item = DownloadItem(id: UUID(), mediaTitle: "T", episodeNumber: 1, episodeTitle: nil, imageUrl: "",
                                aniListID: nil, moduleId: nil, detailHref: nil, episodeHref: "h", streamTitle: nil,
                                streamURL: URL(string: url), headers: [:],
                                state: state, progress: 0.3, createdAt: Date())
        item.taskIdentifier = task
        item.fileName = fileName
        return item
    }

    /// Reported in testing: an HLS download interrupted half-way sat at "downloading, 0%"
    /// forever, as it was only recognised as HLS by the name of the file it hadn't finished.
    func testAnInterruptedHLSDownloadIsParkedToRetry() {
        let stuck = item("https://cdn.test/ep1/master.m3u8")
        XCTAssertEqual(DownloadManager.launchState(of: stuck, autoResume: false)?.0, .failed)
        XCTAssertEqual(DownloadManager.launchState(of: stuck, autoResume: false)?.1, "Interrupted when the app closed")
        XCTAssertEqual(DownloadManager.launchState(of: stuck, autoResume: true)?.0, .pending)
    }

    /// A file download the system's background session runs carries on by itself.
    func testABackgroundFileDownloadIsLeftToTheSystem() {
        XCTAssertNil(DownloadManager.launchState(of: item("https://cdn.test/ep1.mp4", task: 7), autoResume: false))
    }

    func testOnlyDownloadsInFlightAreTouched() {
        XCTAssertNil(DownloadManager.launchState(of: item("https://cdn.test/a.m3u8", state: .completed,
                                                          fileName: "x/playlist.m3u8"), autoResume: false))
        XCTAssertNil(DownloadManager.launchState(of: item("https://cdn.test/a.m3u8", state: .paused), autoResume: false))
    }
}
