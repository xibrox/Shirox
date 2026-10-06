import XCTest
@testable import Shirox

/// Evening out an audio segment's timestamps, and which segments the proxy does it to.
final class TSAudioTimestampsTests: XCTestCase {

    // MARK: - Building segments

    /// One ADTS frame at 44.1 kHz with `body` bytes after its 7-byte header.
    private func adtsFrame(body: Int = 200) -> [UInt8] {
        let length = 7 + body
        var header: [UInt8] = [0xFF, 0xF1, 0x50, 0x80, 0, 0, 0xFC]   // rate index 4 = 44.1 kHz
        header[3] |= UInt8((length >> 11) & 0x03)
        header[4] = UInt8((length >> 3) & 0xFF)
        header[5] = UInt8((length & 0x07) << 5) | 0x1F
        return header + [UInt8](repeating: 0x5A, count: body)
    }

    private func timestamp(_ value: Int64, prefix: UInt8) -> [UInt8] {
        [prefix << 4 | UInt8((value >> 30) & 0x07) << 1 | 1,
         UInt8((value >> 22) & 0xFF),
         UInt8((value >> 15) & 0x7F) << 1 | 1,
         UInt8((value >> 7) & 0xFF),
         UInt8(value & 0x7F) << 1 | 1]
    }

    /// An audio-only MPEG-TS segment: one PES per entry of `pts`, each holding `frames` frames,
    /// split into 188-byte packets on PID 0x100 with stuffing in the last one.
    private func segment(pts: [Int64], frames: Int = 2) -> Data {
        var out: [UInt8] = []
        var counter: UInt8 = 0
        for value in pts {
            let payload = (0..<frames).flatMap { _ in adtsFrame() }
            let pes: [UInt8] = [0, 0, 1, 0xC0, 0, 0, 0x80, 0x80, 5] + timestamp(value, prefix: 0x2) + payload
            var offset = 0
            while offset < pes.count {
                let room = 184
                let chunk = Array(pes[offset..<min(offset + room, pes.count)])
                var packet: [UInt8] = [0x47, (offset == 0 ? 0x40 : 0x00) | 0x01, 0x00]
                if chunk.count < room {
                    // Adaptation field of stuffing to fill the packet.
                    let fieldLength = room - chunk.count - 1
                    packet.append(0x30 | counter)
                    packet.append(UInt8(fieldLength))
                    if fieldLength > 0 { packet += [0x00] + [UInt8](repeating: 0xFF, count: fieldLength - 1) }
                } else {
                    packet.append(0x10 | counter)
                }
                packet += chunk
                XCTAssertEqual(packet.count, 188)
                out += packet
                counter = (counter + 1) & 0x0F
                offset += chunk.count
            }
        }
        return Data(out)
    }

    /// The PTS of every audio PES in `data`, in order.
    private func timestamps(_ data: Data) -> [Int64] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 188).compactMap { base in
            guard bytes[base + 1] & 0x40 != 0 else { return nil }
            var start = base + 4
            if (bytes[base + 3] >> 4) & 0x2 != 0 { start += 1 + Int(bytes[base + 4]) }
            return TSAudioTimestamps.readTimestamp(bytes, at: start + 9)
        }
    }

    /// Two 44.1 kHz frames: 2048 samples, 4179.59 ticks of 90 kHz.
    private let step = 2 * 1024 * 90_000 / 44_100

    // MARK: - Repair

    /// The reported crackle: gaps of about 2 ms (180 ticks) inside a segment.
    func testGapsBetweenFramesAreClosed() throws {
        let start: Int64 = 126_000
        let stamps = (0..<6).map { start + Int64($0 * step) + ($0 >= 3 ? 180 : 0) + ($0 >= 5 ? 160 : 0) }
        let fixed = try XCTUnwrap(TSAudioTimestamps.repair(segment(pts: stamps)))
        XCTAssertEqual(timestamps(fixed), (0..<6).map { start + Int64($0 * 2 * 1024) * 90_000 / 44_100 })
        XCTAssertEqual(fixed.count, segment(pts: stamps).count, "same size, only stamps change")
    }

    func testAnEvenSegmentIsLeftAlone() {
        let stamps = (0..<6).map { 90_000 + Int64($0 * 2 * 1024) * 90_000 / 44_100 }
        XCTAssertNil(TSAudioTimestamps.repair(segment(pts: stamps)))
    }

    /// A real break, past the tolerance, is the stream's own: the segment stays as it came.
    func testABigJumpIsLeftAlone() {
        let stamps = (0..<4).map { 90_000 + Int64($0 * step) + ($0 >= 2 ? 9_000 : 0) }   // 100 ms
        XCTAssertNil(TSAudioTimestamps.repair(segment(pts: stamps)))
    }

    func testAnythingButTransportStreamIsLeftAlone() {
        XCTAssertNil(TSAudioTimestamps.repair(Data(repeating: 0, count: 188 * 4)))
        XCTAssertNil(TSAudioTimestamps.repair(Data("#EXTM3U".utf8)))
        // A frame header that isn't one: the frames can't be counted, so nothing is changed.
        var broken = [UInt8](segment(pts: [90_000, 94_400, 98_600]))
        broken[4 + 14] = 0x00   // the first frame's sync byte, after the packet and PES headers
        XCTAssertNil(TSAudioTimestamps.repair(Data(broken)))
    }

    /// The timestamp counter wraps after 2^33 ticks (about 26.5 hours).
    func testTheCounterWrapping() throws {
        let start: Int64 = (1 << 33) - 3_000
        let stamps = (0..<3).map { (start + Int64($0 * step) + ($0 == 2 ? 150 : 0)) % (1 << 33) }
        let fixed = try XCTUnwrap(TSAudioTimestamps.repair(segment(pts: stamps)))
        XCTAssertEqual(timestamps(fixed).last, (start + Int64(2 * 2 * 1024) * 90_000 / 44_100) % (1 << 33))
    }

    // MARK: - Encrypted segments

    func testAnEncryptedSegmentIsRepairedAndEncryptedAgain() throws {
        let key = Data((0..<16).map { UInt8($0) }), iv = Data(repeating: 7, count: 16)
        let stamps = (0..<4).map { 90_000 + Int64($0 * step) + ($0 >= 2 ? 200 : 0) }
        let clear = segment(pts: stamps)
        let encrypted = try XCTUnwrap(HLSManifestParser.encryptAES128CBC(clear, key: key, iv: iv))
        let crypto = AudioSegmentRepair.Crypto(key: URL(string: "https://cdn.test/key.bin")!, iv: iv)
        let out = try XCTUnwrap(AudioSegmentRepair.repaired(encrypted, crypto: crypto, key: key))
        let decrypted = try XCTUnwrap(HLSManifestParser.decryptAES128CBC(out, key: key, iv: iv))
        XCTAssertEqual(timestamps(decrypted).last, 90_000 + Int64(3 * 2 * 1024) * 90_000 / 44_100)
        XCTAssertNil(AudioSegmentRepair.repaired(encrypted, crypto: crypto, key: nil), "no key: as it came")
    }

    // MARK: - Which playlists

    func testAnAudioPlaylistsSegmentsAreRepairedWithTheirKeys() throws {
        let base = URL(string: "https://cdn.test/a/audio.m3u8")!
        let plan = try XCTUnwrap(AudioSegmentRepair.plan(mediaPlaylist: """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:5
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x000102030405060708090a0b0c0d0e0f
        #EXTINF:6.0,
        s0.ts
        #EXT-X-KEY:METHOD=AES-128,URI="key2.bin"
        #EXTINF:6.0,
        s1.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:6.0,
        s2.ts
        """, baseURL: base))
        XCTAssertEqual(plan[URL(string: "https://cdn.test/a/s0.ts")!],
                       .some(.init(key: URL(string: "https://cdn.test/a/key.bin")!, iv: Data((0..<16).map { UInt8($0) }))))
        // No IV: the segment's sequence number, big-endian.
        XCTAssertEqual(plan[URL(string: "https://cdn.test/a/s1.ts")!]??.iv.last, 6)
        XCTAssertEqual(plan[URL(string: "https://cdn.test/a/s2.ts")!], .some(nil))
    }

    func testPlaylistsItCantRewriteWholeAreLeftAlone() {
        let base = URL(string: "https://cdn.test/a/audio.m3u8")!
        XCTAssertNil(AudioSegmentRepair.plan(mediaPlaylist: "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\ns.m4s", baseURL: base))
        XCTAssertNil(AudioSegmentRepair.plan(mediaPlaylist: "#EXTM3U\n#EXT-X-BYTERANGE:1000@0\n#EXTINF:6,\nall.ts", baseURL: base))
        XCTAssertNil(AudioSegmentRepair.plan(mediaPlaylist: "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n#EXTINF:6,\ns.ts", baseURL: base))
    }

    /// Only an `#EXT-X-MEDIA:TYPE=AUDIO` rendition is marked; a subtitle one, a variant, and a
    /// name merely containing the words aren't.
    func testTheRewriterTellsAnAudioRenditionApart() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Japanese",URI="ja.m3u8"
        #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="TYPE=AUDIO",URI="subs.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1,AUDIO="a"
        v.m3u8
        """
        var kinds: [String: CastManifestRewriter.Resource] = [:]
        _ = CastManifestRewriter.rewrite(master, baseURL: URL(string: "https://cdn.test/m.m3u8")!,
                                         resource: { url, resource in kinds[url.lastPathComponent] = resource; return url })
        XCTAssertEqual(kinds, ["ja.m3u8": .audioPlaylist, "subs.m3u8": .playlist, "v.m3u8": .playlist])
    }
}
