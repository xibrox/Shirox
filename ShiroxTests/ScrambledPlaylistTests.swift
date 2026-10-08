import XCTest
@testable import Shirox

/// Scrambled playlists (ReAnime-style): every playlist is base64 of its text XORed with a
/// per-session key the module hands over as `playlistKey`. Segments aren't scrambled.
final class ScrambledPlaylistTests: XCTestCase {

    static let key = Data([0x13, 0x37, 0xAB, 0xCD, 0x00, 0xFF, 0x42])
    static var keyString: String { key.base64EncodedString() }

    /// What the site serves: the site's loader run backwards.
    static func scramble(_ text: String, key: Data = key) -> Data {
        let bytes = Data(Data(text.utf8).enumerated().map { $0.element ^ key[$0.offset % key.count] })
        return Data(bytes.base64EncodedString().utf8)
    }

    private let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Japanese",DEFAULT=YES,URI="audio/index.m3u8?sig=a+b/c"
    #EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="aud"
    video/index.m3u8?sig=x
    """

    // MARK: Cipher

    func testAScrambledPlaylistIsUnscrambled() {
        XCTAssertEqual(HLSPlaylistCipher.decode(Self.scramble(master), key: Self.keyString), master)
    }

    func testAPlainPlaylistIsLeftAlone() {
        XCTAssertEqual(HLSPlaylistCipher.decode(Data(master.utf8), key: Self.keyString), master)
    }

    func testTheWrongKeyGivesNothingRatherThanGarbage() {
        XCTAssertNil(HLSPlaylistCipher.decode(Self.scramble(master), key: Data([9, 9, 9]).base64EncodedString()))
    }

    func testABodyWrappedOverLinesStillDecodes() {
        let wrapped = String(data: Self.scramble(master), encoding: .utf8)!
            .enumerated().map { $0.offset % 60 == 59 ? "\($0.element)\n" : "\($0.element)" }.joined()
        XCTAssertEqual(HLSPlaylistCipher.decode(Data(wrapped.utf8), key: Self.keyString), master)
    }

    // MARK: Disguised segments

    private let segment = Data([0x47, 0x40, 0x11, 0x10, 0x00, 0x42, 0xf0, 0x25]
                               + [UInt8](repeating: 0xff, count: 180))

    func testAWebPDisguisedSegmentIsUnwrapped() {
        XCTAssertEqual(HLSSegmentDisguise.unwrap(Self.disguise(segment)), segment)
    }

    func testAPNGDisguisedSegmentIsUnwrapped() {
        XCTAssertEqual(HLSSegmentDisguise.unwrap(Self.disguise(segment, as: .png)), segment)
    }

    func testAPlainSegmentBehindTheHeaderIsOnlyUnwrapped() {
        let header = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        XCTAssertEqual(HLSSegmentDisguise.unwrap(header + segment), segment)
    }

    func testAnUndisguisedSegmentIsLeftAlone() {
        XCTAssertEqual(HLSSegmentDisguise.unwrap(segment), segment)
        XCTAssertEqual(HLSSegmentDisguise.unwrap(Data([0x52, 0x49])), Data([0x52, 0x49]))
    }

    func testOnlyImageNamedSegmentsAreLookedAt() {
        XCTAssertTrue(HLSSegmentDisguise.mayBeDisguised(URL(string: "https://vault-1.test/s/seg-3.webp")!))
        XCTAssertTrue(HLSSegmentDisguise.mayBeDisguised(URL(string: "https://vault-1.test/s/seg-3.PNG?t=1")!))
        XCTAssertFalse(HLSSegmentDisguise.mayBeDisguised(URL(string: "https://cdn.test/s/seg-3.ts")!))
    }

    enum ImageHeader { case webp, png }

    /// What HD-2 serves: an image header, then the segment XORed with the site's key.
    static func disguise(_ segment: Data, as header: ImageHeader = .webp) -> Data {
        let key: [UInt8] = [0x9d, 0x2a, 0xf1, 0x47, 0xb3, 0x8e, 0x5c, 0x70,
                            0xa6, 0x19, 0xe4, 0x3b, 0xd8, 0x62, 0x0f, 0xc5]
        let body = Data(segment.enumerated().map { $0.element ^ key[$0.offset % key.count] })
        switch header {
        case .webp:
            let size = UInt32(body.count + 4).littleEndian
            return Data("RIFF".utf8) + withUnsafeBytes(of: size) { Data($0) } + Data("WEBP".utf8) + body
        case .png:
            return Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + body
        }
    }

    // MARK: Rewriting

    func testOnlyPlaylistsAreMarkedAsPlaylists() {
        var marked: [String: Bool] = [:]
        _ = CastManifestRewriter.rewrite(master, baseURL: URL(string: "https://cdn.test/m/master.m3u8")!) { url, isPlaylist in
            marked[url.lastPathComponent] = isPlaylist
            return url
        }
        XCTAssertEqual(marked["index.m3u8"], true)
        XCTAssertEqual(marked.count, 1, "both renditions are named index.m3u8")

        let media = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        seg0.m4s
        """
        var seen: [String: Bool] = [:]
        _ = CastManifestRewriter.rewrite(media, baseURL: URL(string: "https://cdn.test/v/index.m3u8")!) { url, isPlaylist in
            seen[url.lastPathComponent] = isPlaylist
            return url
        }
        XCTAssertEqual(seen, ["key.bin": false, "init.mp4": false, "seg0.m4s": false])
    }

    func testTheOldSingleArgumentRewriteStillWorks() {
        let out = CastManifestRewriter.rewrite("#EXTM3U\nseg.ts", baseURL: URL(string: "https://a.test/x.m3u8")!) {
            URL(string: "http://p/?u=\($0.absoluteString)")
        }
        XCTAssertEqual(out, "#EXTM3U\nhttp://p/?u=https://a.test/seg.ts")
    }

    // MARK: Module result

    func testAKeyIsReadPerStreamOrForAll() {
        let perStream = parseStreamResults(from: ["streams": [
            ["title": "1080p", "streamUrl": "https://a.test/1.m3u8", "playlistKey": "AAA="],
            ["title": "720p", "streamUrl": "https://a.test/2.m3u8"],
        ]])
        XCTAssertEqual(perStream.map(\.playlistKey), ["AAA=", nil])

        let shared = parseStreamResults(from: ["playlistKey": "BBB=", "streams": [
            ["title": "1080p", "streamUrl": "https://a.test/1.m3u8"],
            ["title": "720p", "streamUrl": "https://a.test/2.m3u8", "playlistKey": "CCC="],
        ]])
        XCTAssertEqual(shared.map(\.playlistKey), ["BBB=", "CCC="])

        let none = parseStreamResults(from: ["stream": "https://a.test/1.m3u8"])
        XCTAssertNil(none.first?.playlistKey)
    }

    func testAnEmptyKeyMeansNoKey() {
        XCTAssertNil(StreamResult(title: "x", url: URL(string: "https://a.test")!, headers: [:], playlistKey: "").playlistKey)
    }

    // MARK: AirPlay

    func testAScrambledStreamGoesThroughTheProxyForAirPlayEvenWithoutHeaders() {
        let url = URL(string: "https://cdn.test/master")!
        XCTAssertTrue(AirPlayRouting.needsProxy(url: url, headers: [:], isAirPlayActive: true, hasScrambledPlaylists: true))
        XCTAssertFalse(AirPlayRouting.needsProxy(url: url, headers: [:], isAirPlayActive: true))
        XCTAssertFalse(AirPlayRouting.needsProxy(url: url, headers: [:], isAirPlayActive: false, hasScrambledPlaylists: true))
    }

    // MARK: Quality menu

    func testTheQualityMenuReadsAScrambledMaster() async {
        ScrambledPlaylistProtocol.body = Self.scramble("""
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        720.m3u8
        """)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScrambledPlaylistProtocol.self]
        let session = URLSession(configuration: config)
        let url = URL(string: "https://cdn.invalid/master")!
        let levels = await HLSQualityParser.parse(url: url, headers: [:], playlistKey: Self.keyString, session: session)
        XCTAssertEqual(levels.map(\.label), ["1080p", "720p"])
        let without = await HLSQualityParser.parse(url: url, headers: [:], session: session)
        XCTAssertTrue(without.isEmpty, "without the key the body isn't a playlist")
    }

    // MARK: Downloads

    func testADownloadSavedBeforeKeysExistedStillDecodes() throws {
        let item = DownloadItem(id: UUID(), mediaTitle: "T", episodeNumber: 1, episodeTitle: nil, imageUrl: "",
                                aniListID: nil, moduleId: nil, detailHref: nil, episodeHref: "h", streamTitle: nil,
                                streamURL: URL(string: "https://a.test/m.m3u8"), headers: [:],
                                state: .pending, progress: 0, createdAt: Date(), playlistKey: "KEY=")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        XCTAssertEqual(json["playlistKey"] as? String, "KEY=")
        json.removeValue(forKey: "playlistKey")
        let old = try JSONDecoder().decode(DownloadItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.playlistKey)
    }

    func testTheBestVariantComesWithItsAudioRendition() throws {
        let base = URL(string: "https://cdn.test/m/master.m3u8")!
        let choice = try XCTUnwrap(HLSManifestParser.selectBestVariantChoice("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="hi",NAME="English",URI="en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="hi",NAME="Japanese",DEFAULT=YES,URI="ja.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="lo",NAME="Japanese",DEFAULT=YES,URI="ja-lo.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=500000,AUDIO="lo"
        lo.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,AUDIO="hi",CODECS="avc1.640028,mp4a.40.2"
        hi.m3u8
        """, baseURL: base))
        XCTAssertEqual(choice.video.absoluteString, "https://cdn.test/m/hi.m3u8")
        XCTAssertEqual(choice.audio?.absoluteString, "https://cdn.test/m/ja.m3u8")
        // Every language of the variant's group, for the download to keep; not the other group's.
        XCTAssertEqual(choice.audioRenditions, [
            HLSAudioRendition(url: URL(string: "https://cdn.test/m/en.m3u8")!, name: "English", language: nil, isDefault: false),
            HLSAudioRendition(url: URL(string: "https://cdn.test/m/ja.m3u8")!, name: "Japanese", language: nil, isDefault: true),
        ])
        XCTAssertEqual(choice.bandwidth, 3_000_000)
        XCTAssertEqual(choice.codecs, "avc1.640028,mp4a.40.2")
    }

    func testAudioMuxedIntoTheVideoNeedsNothingSeparate() throws {
        let base = URL(string: "https://cdn.test/master.m3u8")!
        let muxed = try XCTUnwrap(HLSManifestParser.selectBestVariantChoice("""
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Main",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="a"
        v.m3u8
        """, baseURL: base))
        XCTAssertNil(muxed.audio)
        XCTAssertTrue(muxed.audioRenditions.isEmpty)
        let plain = try XCTUnwrap(HLSManifestParser.selectBestVariantChoice("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nv.m3u8", baseURL: base))
        XCTAssertNil(plain.audio)
        XCTAssertNil(HLSManifestParser.selectBestVariantChoice("#EXTM3U\n#EXTINF:4,\nseg.ts", baseURL: base))
    }

    func testTheLocalMasterNamesEveryPlaylist() {
        let master = HLSManifestParser.localMasterManifest(
            videoPlaylist: "video.m3u8",
            audio: [HLSLocalAudio(playlist: "audio.m3u8", name: "Hindi", language: "hi", isDefault: false),
                    HLSLocalAudio(playlist: "audio_1.m3u8", name: "Japanese", language: "ja", isDefault: true)],
            bandwidth: 900_000, codecs: "avc1.42e01e,mp4a.40.2")
        XCTAssertTrue(master.contains(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Hindi",LANGUAGE="hi",DEFAULT=NO,AUTOSELECT=YES,URI="audio.m3u8""#))
        XCTAssertTrue(master.contains(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Japanese",LANGUAGE="ja",DEFAULT=YES,AUTOSELECT=YES,URI="audio_1.m3u8""#))
        XCTAssertTrue(master.contains("#EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO=\"audio\",CODECS=\"avc1.42e01e,mp4a.40.2\"\nvideo.m3u8"))
        let audio = HLSManifestParser.localManifest(durations: [4, 2], segmentExtension: "aac", initFileName: nil,
                                                    segmentPrefix: "a_seg_")
        XCTAssertTrue(audio.contains("a_seg_0.aac\n#EXTINF:2.0,\na_seg_1.aac"))
    }
}

/// Answers every request with `body`.
private final class ScrambledPlaylistProtocol: URLProtocol {
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
