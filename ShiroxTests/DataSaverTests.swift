import XCTest
@testable import Shirox

/// Tests for which artwork the app requests.
///
/// The report was that scrolling the Home screen cost hundreds of megabytes. It did: posters
/// were fetched at their largest size to be drawn in grid cells a fraction as wide. Measured on
/// MyAnimeList's CDN, one poster is 177,509 bytes at the large size against 56,653 at the small
/// one — roughly a third — and the Home screen carries dozens of them plus a full-width banner
/// per hero card.
final class DataSaverTests: XCTestCase {

    private let small = "https://cdn.example/poster.jpg"
    private let big = "https://cdn.example/posterl.jpg"

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        // An isolated suite: reading the app's shared defaults made these tests depend on
        // whatever the setting happened to be left at on the device running them.
        suite = UserDefaults(suiteName: "DataSaverTests-\(UUID().uuidString)")
        DataSaver.defaults = suite
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suite.description)
        DataSaver.defaults = .standard
        super.tearDown()
    }

    private func setDataSaver(_ on: Bool) {
        suite.set(on, forKey: DataSaver.key)
    }

    // MARK: - Off (the default)

    func testDefaultsToOff() {
        XCTAssertFalse(DataSaver.isEnabled, "saving detail must be opt-in")
    }

    func testThumbnailPrefersTheLargerArtWhenOff() {
        setDataSaver(false)
        let art = MediaCoverImage(large: small, extraLarge: big)
        XCTAssertEqual(art.thumb, big)
    }

    // MARK: - On

    func testThumbnailPrefersTheSmallerArtWhenOn() {
        setDataSaver(true)
        let art = MediaCoverImage(large: small, extraLarge: big)
        XCTAssertEqual(art.thumb, small, "this is the whole saving")
    }

    /// Heroes and the full-screen poster viewer keep full quality either way — the setting is
    /// about the dozens of small cells, not the one image someone chose to look at.
    func testBestIsUnaffectedBySaving() {
        setDataSaver(true)
        let art = MediaCoverImage(large: small, extraLarge: big)
        XCTAssertEqual(art.best, big)
    }

    // MARK: - Missing sizes

    /// A provider that only supplies one size must still render something.
    func testFallsBackWhenOnlyLargeExists() {
        let art = MediaCoverImage(large: small, extraLarge: nil)
        setDataSaver(true)
        XCTAssertEqual(art.thumb, small)
        setDataSaver(false)
        XCTAssertEqual(art.thumb, small)
    }

    func testFallsBackWhenOnlyExtraLargeExists() {
        let art = MediaCoverImage(large: nil, extraLarge: big)
        setDataSaver(true)
        XCTAssertEqual(art.thumb, big, "a smaller size that doesn't exist can't be preferred")
        setDataSaver(false)
        XCTAssertEqual(art.thumb, big)
    }

    func testNoArtworkResolvesToNil() {
        setDataSaver(true)
        XCTAssertNil(MediaCoverImage(large: nil, extraLarge: nil).thumb)
    }
}

/// Tests for how many titles a Home row asks for under Data Saver.
///
/// Once the correct-sized poster is being requested, image size has nothing left to give: the
/// next tier down on MyAnimeList's CDN is 42×59, a blur rather than a picture. So the remaining
/// saving is wanting fewer images, and a shorter row is a trade someone can see and understand.
final class DataSaverRowLengthTests: XCTestCase {

    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        // An isolated suite: reading the app's shared defaults made these tests depend on
        // whatever the setting happened to be left at on the device running them.
        suite = UserDefaults(suiteName: "DataSaverTests-\(UUID().uuidString)")
        DataSaver.defaults = suite
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suite.description)
        DataSaver.defaults = .standard
        super.tearDown()
    }

    private func setDataSaver(_ on: Bool) {
        suite.set(on, forKey: DataSaver.key)
    }

    func testRowsAreUnchangedWhenOff() {
        setDataSaver(false)
        XCTAssertEqual(DataSaver.rowLength(25), 25)
        XCTAssertEqual(DataSaver.rowLength(20), 20)
    }

    func testRowsAreHalvedWhenOn() {
        setDataSaver(true)
        XCTAssertEqual(DataSaver.rowLength(25), 12)
        XCTAssertEqual(DataSaver.rowLength(20), 10)
    }

    /// A row still has to look like a row. Halving a short one to two or three entries would
    /// read as a broken screen rather than a considerate one.
    func testShortRowsKeepAFloor() {
        setDataSaver(true)
        XCTAssertEqual(DataSaver.rowLength(8), 6)
        XCTAssertEqual(DataSaver.rowLength(4), 6)
        XCTAssertEqual(DataSaver.rowLength(1), 6)
    }

    /// Never longer than asked for — that would cost more, not less.
    func testNeverExceedsTheStandardLength() {
        setDataSaver(true)
        for standard in [6, 10, 12, 20, 25, 30] {
            XCTAssertLessThanOrEqual(DataSaver.rowLength(standard), max(standard, 6))
        }
    }
}
