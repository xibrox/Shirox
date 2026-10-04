import XCTest
@testable import Shirox

/// What a subtitle file turns out to be: plain cues, or an ASS script kept whole.
final class SubtitleLoaderTests: XCTestCase {

    private let ass = """
    [Script Info]
    ScriptType: v4.00+

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\an8}Hello
    """

    private func parse(_ text: String) throws -> LoadedSubtitles {
        try VTTSubtitlesLoader.parse(Data(text.utf8))
    }

    func testWebVTTIsCues() throws {
        guard case .cues(let cues) = try parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHi\n") else { return XCTFail() }
        XCTAssertEqual(cues.map(\.text), ["Hi"])
    }

    func testSRTIsCues() throws {
        guard case .cues(let cues) = try parse("1\n00:00:01,000 --> 00:00:02,000\nHi\n") else { return XCTFail() }
        XCTAssertEqual(cues.map(\.text), ["Hi"])
    }

    /// Kept whole: its styles, positions and override tags are libass's to draw.
    func testAnASSScriptIsKeptWhole() throws {
        guard case .ass(let script) = try parse(ass) else { return XCTFail("not recognised as ASS") }
        XCTAssertEqual(script, ass)
    }

    func testASSIsRecognisedAfterAByteOrderMarkAndBlankLines() throws {
        guard case .ass = try parse("\u{FEFF}\n\n" + ass) else { return XCTFail() }
    }

    /// Older fansub scripts are often saved as UTF-16.
    func testAUTF16ScriptIsRead() throws {
        var data = Data([0xFF, 0xFE])
        data.append(ass.data(using: .utf16LittleEndian)!)
        guard case .ass(let script) = try VTTSubtitlesLoader.parse(data) else { return XCTFail() }
        XCTAssertTrue(script.contains("Dialogue: 0,0:00:01.00"))
    }

    /// Windows editors save SRT with a UTF-8 byte-order mark. It sat in front of the first
    /// index, the file wasn't recognised, and an imported track silently didn't replace the
    /// stream's own.
    func testSRTAfterAByteOrderMarkIsCues() throws {
        guard case .cues(let cues) = try parse("\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nمرحبا\r\n") else {
            return XCTFail()
        }
        XCTAssertEqual(cues.map(\.text), ["مرحبا"])
    }

    /// Some tools leave out the cue numbers.
    func testSRTWithoutIndexesIsCues() throws {
        guard case .cues(let cues) = try parse("00:00:01,000 --> 00:00:02,000\nOne\n\n00:00:03,000 --> 00:00:04,000\nTwo\n") else {
            return XCTFail()
        }
        XCTAssertEqual(cues.map(\.text), ["One", "Two"])
    }

    /// Arabic subtitles are often Windows-1256, which isn't UTF-8.
    func testWindowsArabicSRTIsRead() throws {
        let cp1256 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))
        let text = "1\r\n00:00:01,000 --> 00:00:02,000\r\nمرحبا بكم في البيت\r\n"
        let data = try XCTUnwrap(text.data(using: cp1256))
        guard case .cues(let cues) = try VTTSubtitlesLoader.parse(data) else { return XCTFail() }
        XCTAssertEqual(cues.map(\.text), ["مرحبا بكم في البيت"])
    }

    func testSomethingElseIsRefused() {
        XCTAssertThrowsError(try parse("<html>nope</html>"))
    }
}
