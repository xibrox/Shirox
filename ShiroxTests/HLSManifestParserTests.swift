import XCTest
@testable import Shirox

/// Tests for HLS download manifest parsing + segment decryption.
///
/// The reported bug: a downloaded 1080p movie crashed the player ~2s in while the
/// 720p copy played fine. Root cause: the downloader assumed every stream was plain,
/// unencrypted MPEG-TS and silently dropped `#EXT-X-MAP` (fMP4 init segment),
/// `#EXT-X-KEY` (AES-128 encryption) and `#EXT-X-BYTERANGE` — producing a "completed"
/// download that can't be decoded and can hard-crash the media stack. These tests pin
/// the parsing/decryption behaviour the downloader now relies on.
final class HLSManifestParserTests: XCTestCase {

    private let base = URL(string: "https://cdn.example/video/index.m3u8")!

    private func hex(_ s: String) -> Data {
        var data = Data()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            data.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return data
    }

    // MARK: - Plain TS (the path that already works — must stay identical)

    func testPlainTSMediaPlaylistParsesSegmentsAndDurations() {
        let m = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:9.009,
        https://cdn.example/video/seg0.ts
        #EXTINF:9.009,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let plan = HLSManifestParser.parseMediaPlaylist(m, baseURL: base)
        XCTAssertNil(plan.initSegment, "plain TS has no init segment")
        XCTAssertFalse(plan.isFMP4)
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments.map { $0.duration }, [9.009, 9.009])
        XCTAssertEqual(plan.segments[0].url.absoluteString, "https://cdn.example/video/seg0.ts")
        XCTAssertEqual(plan.segments[1].url.absoluteString, "https://cdn.example/video/seg1.ts")
        XCTAssertNil(plan.segments[0].key)
        XCTAssertNil(plan.segments[0].byteRange)
    }

    // MARK: - fMP4 / CMAF (EXT-X-MAP)

    func testFMP4PlaylistCapturesInitSegment() {
        let m = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.000,
        seg0.m4s
        #EXTINF:6.000,
        seg1.m4s
        #EXT-X-ENDLIST
        """
        let plan = HLSManifestParser.parseMediaPlaylist(m, baseURL: base)
        XCTAssertTrue(plan.isFMP4)
        XCTAssertEqual(plan.initSegment?.url.absoluteString, "https://cdn.example/video/init.mp4")
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[1].url.absoluteString, "https://cdn.example/video/seg1.m4s")
    }

    // MARK: - AES-128 encryption (EXT-X-KEY)

    func testAES128KeyAppliesToFollowingSegmentsWithExplicitIV() {
        let m = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-KEY:METHOD=AES-128,URI="https://k.example/key.bin",IV=0x00000000000000000000000000000001
        #EXTINF:10.0,
        seg0.ts
        #EXTINF:10.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let plan = HLSManifestParser.parseMediaPlaylist(m, baseURL: base)
        XCTAssertEqual(plan.segments.count, 2)
        for seg in plan.segments {
            XCTAssertEqual(seg.key?.method, .aes128)
            XCTAssertEqual(seg.key?.url?.absoluteString, "https://k.example/key.bin")
        }
        var expectedIV = [UInt8](repeating: 0, count: 16); expectedIV[15] = 1
        XCTAssertEqual(plan.segments[0].key?.iv, expectedIV)
    }

    func testAES128WithoutIVDerivesFromMediaSequence() {
        let m = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:5
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:10.0,
        seg0.ts
        #EXT-X-ENDLIST
        """
        let plan = HLSManifestParser.parseMediaPlaylist(m, baseURL: base)
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertNil(plan.segments[0].key?.iv, "no explicit IV in the tag")
        XCTAssertEqual(plan.segments[0].mediaSequence, 5)

        var expected = [UInt8](repeating: 0, count: 16); expected[15] = 5
        XCTAssertEqual(HLSManifestParser.defaultIV(forMediaSequence: 5), expected)
    }

    func testKeyMethodNoneClearsEncryption() {
        let m = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:10,
        a.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:10,
        b.ts
        #EXT-X-ENDLIST
        """
        let plan = HLSManifestParser.parseMediaPlaylist(m, baseURL: base)
        XCTAssertEqual(plan.segments[0].key?.method, .aes128)
        XCTAssertNil(plan.segments[1].key, "METHOD=NONE means the segment is cleartext")
    }

    // MARK: - Byte ranges (EXT-X-BYTERANGE)

    func testByteRangeContinuationOffset() {
        let m = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXTINF:10.0,
        #EXT-X-BYTERANGE:75232@0
        main.ts
        #EXTINF:10.0,
        #EXT-X-BYTERANGE:82112
        main.ts
        #EXT-X-ENDLIST
        """
        let plan = HLSManifestParser.parseMediaPlaylist(m, baseURL: base)
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0].byteRange, HLSByteRange(length: 75232, offset: 0))
        XCTAssertEqual(plan.segments[1].byteRange, HLSByteRange(length: 82112, offset: 75232),
                       "absent offset continues from the previous range of the same resource")
    }

    // MARK: - Master playlist variant selection

    func testSelectBestVariantPicksHighestBandwidth() {
        let m = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720
        720.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080
        1080.m3u8
        """
        let url = HLSManifestParser.selectBestVariant(m, baseURL: base)
        XCTAssertEqual(url?.absoluteString, "https://cdn.example/video/1080.m3u8")
    }

    func testSelectBestVariantReturnsNilForMediaPlaylist() {
        let m = """
        #EXTM3U
        #EXTINF:10.0,
        seg0.ts
        #EXT-X-ENDLIST
        """
        XCTAssertNil(HLSManifestParser.selectBestVariant(m, baseURL: base))
    }

    // MARK: - Local manifest generation

    func testLocalManifestTSHasNoMapOrKey() {
        let out = HLSManifestParser.localManifest(durations: [9.009, 9.009],
                                                  segmentExtension: "ts",
                                                  initFileName: nil)
        XCTAssertTrue(out.contains("#EXTM3U"))
        XCTAssertTrue(out.contains("#EXT-X-VERSION:3"))
        XCTAssertTrue(out.contains("seg_0.ts"))
        XCTAssertTrue(out.contains("seg_1.ts"))
        XCTAssertTrue(out.contains("#EXT-X-ENDLIST"))
        XCTAssertFalse(out.contains("#EXT-X-MAP"))
        XCTAssertFalse(out.contains("#EXT-X-KEY"), "downloaded segments are stored decrypted")
    }

    func testLocalManifestFMP4EmitsMapAndVersion7() {
        let out = HLSManifestParser.localManifest(durations: [6.0, 6.0],
                                                  segmentExtension: "m4s",
                                                  initFileName: "init.mp4")
        XCTAssertTrue(out.contains("#EXT-X-VERSION:7"))
        XCTAssertTrue(out.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(out.contains("seg_0.m4s"))
        XCTAssertTrue(out.contains("seg_1.m4s"))
        XCTAssertFalse(out.contains("#EXT-X-KEY"))
    }

    // MARK: - AES-128-CBC decryption (independent openssl-generated vector)

    func testDecryptAES128CBCMatchesOpenSSLVector() {
        // openssl enc -aes-128-cbc -K 000102...0f -iv 101112...1f
        let key = hex("000102030405060708090a0b0c0d0e0f")
        let iv = hex("101112131415161718191a1b1c1d1e1f")
        let cipher = hex("3f619c6faefed52c801aa3d5ffd7997860d9b12a37c6847cd0c17b79579ad0b2509aee17fe8ab6c6e5f5adec88d47bfd")

        let plain = HLSManifestParser.decryptAES128CBC(cipher, key: key, iv: iv)
        XCTAssertEqual(plain.flatMap { String(data: $0, encoding: .utf8) },
                       "The quick brown fox jumps over the lazy dog!!!",
                       "PKCS7 padding must be stripped to recover the exact 46-byte plaintext")
    }
}
