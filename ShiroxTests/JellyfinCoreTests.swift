import XCTest
@testable import Shirox

final class JellyfinCoreTests: XCTestCase {

    func testTicksRoundTrip() {
        XCTAssertEqual(JellyfinTicks.seconds(fromTicks: 10_000_000), 1.0, accuracy: 0.0001)
        XCTAssertEqual(JellyfinTicks.ticks(fromSeconds: 1.0), 10_000_000)
        XCTAssertEqual(JellyfinTicks.ticks(fromSeconds: 90.5), 905_000_000)
    }

    func testAuthHeaderOmitsTokenWhenNil() {
        let h = JellyfinAuthHeader.value(client: "Shirox", device: "iPhone",
                                         deviceId: "abc", version: "1.0", token: nil)
        XCTAssertEqual(h, #"MediaBrowser Client="Shirox", Device="iPhone", DeviceId="abc", Version="1.0""#)
    }

    func testAuthHeaderIncludesToken() {
        let h = JellyfinAuthHeader.value(client: "Shirox", device: "iPhone",
                                         deviceId: "abc", version: "1.0", token: "tok")
        XCTAssertTrue(h.hasSuffix(#"Token="tok""#))
    }

    func testDirectPlayContainers() {
        XCTAssertTrue(JellyfinStreamDecision.shouldDirectPlay(container: "mp4"))
        XCTAssertTrue(JellyfinStreamDecision.shouldDirectPlay(container: "mov,mp4,m4a"))
        XCTAssertFalse(JellyfinStreamDecision.shouldDirectPlay(container: "mkv"))
        XCTAssertFalse(JellyfinStreamDecision.shouldDirectPlay(container: nil))
    }

    func testImageURL() {
        let base = URL(string: "https://jf.example.com")!
        let url = JellyfinURLBuilder.imageURL(base: base, itemId: "ID1", type: "Primary",
                                              tag: "TAG1", maxHeight: 480)
        XCTAssertEqual(url?.absoluteString,
            "https://jf.example.com/Items/ID1/Images/Primary?maxHeight=480&tag=TAG1")
    }

    func testDirectStreamURL() {
        let base = URL(string: "https://jf.example.com")!
        let url = JellyfinURLBuilder.directStreamURL(base: base, itemId: "ID1",
                                                     container: "mp4", apiKey: "K", deviceId: "D")
        let s = url!.absoluteString
        XCTAssertTrue(s.hasPrefix("https://jf.example.com/Videos/ID1/stream.mp4?"))
        XCTAssertTrue(s.contains("static=true"))
        XCTAssertTrue(s.contains("api_key=K"))
        XCTAssertTrue(s.contains("deviceId=D"))
    }

    func testTranscodeURLJoinsPath() {
        let base = URL(string: "https://jf.example.com")!
        let url = JellyfinURLBuilder.transcodeURL(base: base,
                                                  transcodingPath: "/Videos/ID1/master.m3u8?api_key=K")
        XCTAssertEqual(url?.absoluteString, "https://jf.example.com/Videos/ID1/master.m3u8?api_key=K")
    }

    func testHlsMasterURL() {
        let base = URL(string: "https://jf.example.com")!
        let url = JellyfinURLBuilder.hlsMasterURL(base: base, itemId: "ID1", mediaSourceId: "MS1",
                                                  apiKey: "K", deviceId: "D")
        let s = url!.absoluteString
        XCTAssertTrue(s.hasPrefix("https://jf.example.com/Videos/ID1/master.m3u8?"))
        XCTAssertTrue(s.contains("videoCodec=h264"))
        XCTAssertTrue(s.contains("mediaSourceId=MS1"))
        XCTAssertTrue(s.contains("api_key=K"))
    }

    // MARK: - Stream resolution (the mkv playback bug)

    func testResolutionPrefersTranscodingUrl() {
        let base = URL(string: "https://jf.example.com")!
        let url = JellyfinStreamResolution.streamURL(
            base: base, itemId: "ID1", mediaSourceId: "ID1",
            container: "mkv", transcodingUrl: "/Videos/ID1/master.m3u8?api_key=K",
            apiKey: "K", deviceId: "D")
        XCTAssertEqual(url?.absoluteString, "https://jf.example.com/Videos/ID1/master.m3u8?api_key=K")
    }

    func testResolutionMkvWithoutTranscodeFallsBackToHls() {
        // THE BUG: mkv with no server transcode URL must NOT become a static .mp4 (unplayable);
        // it must resolve to an HLS master URL AVPlayer can remux/transcode.
        let base = URL(string: "https://jf.example.com")!
        let url = JellyfinStreamResolution.streamURL(
            base: base, itemId: "ID1", mediaSourceId: "MS1",
            container: "mkv", transcodingUrl: nil, apiKey: "K", deviceId: "D")
        let s = url!.absoluteString
        XCTAssertTrue(s.hasPrefix("https://jf.example.com/Videos/ID1/master.m3u8?"))
        XCTAssertFalse(s.contains("static=true"))
    }

    func testResolutionMp4WithoutTranscodeUsesDirect() {
        let base = URL(string: "https://jf.example.com")!
        let url = JellyfinStreamResolution.streamURL(
            base: base, itemId: "ID1", mediaSourceId: "ID1",
            container: "mp4", transcodingUrl: nil, apiKey: "K", deviceId: "D")
        let s = url!.absoluteString
        XCTAssertTrue(s.hasPrefix("https://jf.example.com/Videos/ID1/stream.mp4?"))
        XCTAssertTrue(s.contains("static=true"))
    }

    // MARK: - Item id from stream URL (next-episode progress targeting)

    func testItemIdFromDirectStreamURL() {
        let url = URL(string: "https://jf.example.com/Videos/X/stream.mp4?static=true&mediaSourceId=ABC&api_key=K")!
        XCTAssertEqual(JellyfinURLParser.itemId(fromStreamURL: url, serverHost: "jf.example.com"), "ABC")
    }

    func testItemIdFromTranscodeURLCapitalParam() {
        let url = URL(string: "https://jf.example.com/videos/X/master.m3u8?MediaSourceId=DEF&api_key=K")!
        XCTAssertEqual(JellyfinURLParser.itemId(fromStreamURL: url, serverHost: "jf.example.com"), "DEF")
    }

    func testItemIdIgnoresNonJellyfinHost() {
        let url = URL(string: "https://other.cdn.com/video.m3u8?mediaSourceId=ABC")!
        XCTAssertNil(JellyfinURLParser.itemId(fromStreamURL: url, serverHost: "jf.example.com"))
    }

    func testDecodeItemsResponse() throws {
        let json = """
        {"Items":[{"Id":"e1","Name":"Episode 1","Type":"Episode","IndexNumber":1,
          "ParentIndexNumber":2,"SeriesName":"Show","SeriesId":"s1","RunTimeTicks":12000000000,
          "ImageTags":{"Primary":"tagA"},
          "UserData":{"PlaybackPositionTicks":6000000000,"Played":false,"PlayedPercentage":50.0}}]}
        """
        let resp = try JSONDecoder().decode(JellyfinItemsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(resp.items.count, 1)
        let item = resp.items[0]
        XCTAssertEqual(item.id, "e1")
        XCTAssertEqual(item.indexNumber, 1)
        XCTAssertEqual(item.primaryImageTag, "tagA")
        XCTAssertEqual(item.userData?.playbackPositionTicks, 6_000_000_000)
    }

    func testDecodePlaybackInfo() throws {
        let json = """
        {"MediaSources":[{"Id":"m1","Container":"mkv","SupportsDirectPlay":false,
          "TranscodingUrl":"/Videos/x/master.m3u8?api_key=K"}]}
        """
        let info = try JSONDecoder().decode(JellyfinPlaybackInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.mediaSources.first?.container, "mkv")
        XCTAssertEqual(info.mediaSources.first?.transcodingUrl, "/Videos/x/master.m3u8?api_key=K")
    }
}
