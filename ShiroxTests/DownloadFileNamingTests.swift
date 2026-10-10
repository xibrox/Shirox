#if os(iOS)
import XCTest
@testable import Shirox

/// What a finished download is called in the Downloads folder: one file named after the episode,
/// not a `<uuid>/` folder of segments or a `<uuid>.mp4`.
final class DownloadFileNamingTests: XCTestCase {

    func testAnEpisodeIsNamedAfterItsShowAndNumber() {
        XCTAssertEqual(DownloadManager.fileStem(mediaTitle: "Sousou no Frieren", episodeNumber: 5), "Sousou no Frieren - E05")
        XCTAssertEqual(DownloadManager.fileStem(mediaTitle: "One Piece", episodeNumber: 1100), "One Piece - E1100")
    }

    /// A title can hold what a file name can't: a slash would make a folder, a colon shows as one
    /// in Finder.
    func testCharactersAFileNameCantHoldAreTakenOut() {
        XCTAssertEqual(DownloadManager.fileStem(mediaTitle: "Re:Zero / Season 2?", episodeNumber: 3), "Re Zero Season 2 - E03")
        XCTAssertEqual(DownloadManager.sanitizedFileName("  ..hidden\nname.  "), "hidden name")
    }

    func testATitleThatIsNothingButForbiddenCharactersLeavesTheEpisode() {
        XCTAssertEqual(DownloadManager.fileStem(mediaTitle: "///", episodeNumber: 7), "E07")
    }

    /// A real episode title goes in the name; "Episode 5" says nothing the number doesn't.
    func testARealEpisodeTitleIsAddedAndAPlaceholderIsNot() {
        XCTAssertEqual(DownloadManager.fileStem(mediaTitle: "Frieren", episodeNumber: 1, episodeTitle: "The Journey's End"),
                       "Frieren - E01 - The Journey's End")
        for placeholder in ["Episode 1", "EP. 1", "1", "e01", "Frieren", "  "] {
            XCTAssertEqual(DownloadManager.fileStem(mediaTitle: "Frieren", episodeNumber: 1, episodeTitle: placeholder),
                           "Frieren - E01", placeholder)
        }
    }

    /// A show's downloads from one source share a folder; the source's name can hold a colon too.
    func testAShowsFolderIsNamedAfterItAndItsSource() {
        XCTAssertEqual(DownloadManager.folderName(mediaTitle: "Frieren", sourceName: "Re:ANIME"), "Frieren - Re ANIME")
        XCTAssertEqual(DownloadManager.folderName(mediaTitle: "Frieren", sourceName: nil), "Frieren")
        // The snapshot store's own folder sits beside the shows'.
        XCTAssertEqual(DownloadManager.folderName(mediaTitle: "Snapshots", sourceName: nil), "Snapshots (Show)")
    }

    /// A direct download kept the `.mp4` name whatever it was, so a Matroska file couldn't be
    /// told apart, or opened by its extension.
    func testADirectDownloadKeepsTheFormatItIs() {
        func ext(_ url: String, mime: String?) -> String {
            let response = URLResponse(url: URL(string: url)!, mimeType: mime, expectedContentLength: 0, textEncodingName: nil)
            return DownloadManager.fileExtension(for: response, requestURL: URL(string: url))
        }
        XCTAssertEqual(ext("https://cdn.example/v/ep1.mkv", mime: "application/octet-stream"), "mkv")
        XCTAssertEqual(ext("https://cdn.example/stream?id=1", mime: "video/webm"), "webm")
        XCTAssertEqual(ext("https://cdn.example/stream?id=1", mime: "application/octet-stream"), "mp4")
    }

    /// MP4 keeps a track's language only as a three-letter code: "ja" was written as undefined,
    /// and the player's audio menu couldn't name the languages.
    func testAudioLanguagesBecomeThreeLetterCodes() {
        XCTAssertEqual(MediaRemuxer.isoLanguage("ja"), "jpn")
        XCTAssertEqual(MediaRemuxer.isoLanguage("en-US"), "eng")
        XCTAssertEqual(MediaRemuxer.isoLanguage("deu"), "deu")
    }
}
#endif
