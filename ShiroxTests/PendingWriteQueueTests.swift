import XCTest
@testable import Shirox

@MainActor
final class FakePendingWriteSink: PendingWriteSink {
    enum Behavior { case succeed, transientFail, permanentFail }
    var behavior: Behavior = .succeed
    private(set) var performed: [PendingWrite] = []
    func perform(_ write: PendingWrite) async throws {
        performed.append(write)
        switch behavior {
        case .succeed: return
        case .transientFail: throw URLError(.notConnectedToInternet)
        case .permanentFail: throw ProviderError.notFound
        }
    }
}

@MainActor
final class PendingWriteQueueTests: XCTestCase {

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeQueue(_ dir: URL, sink: PendingWriteSink? = nil, maxAttempts: Int = 50) -> PendingWriteQueue {
        PendingWriteQueue(directory: dir, sink: sink,
                          cacheStore: LibraryCacheStore(directory: dir), maxAttempts: maxAttempts)
    }

    private func update(_ provider: ProviderType, _ mediaId: Int, progress: Int) -> PendingWrite {
        PendingWrite(id: UUID(), provider: provider, mediaType: .anime, kind: .update,
                     mediaId: mediaId, entryId: nil, status: .current, progress: progress,
                     score: 0, repeatCount: nil, updatedAt: Date(), attempts: 0)
    }

    func testEnqueueDedupsSameTargetLastWriteWins() {
        let q = makeQueue(tempDir())
        q.enqueue(update(.anilist, 1, progress: 3))
        q.enqueue(update(.anilist, 1, progress: 7))   // same dedupKey → replaces
        q.enqueue(update(.anilist, 2, progress: 1))   // different media → coexists
        XCTAssertEqual(q.pending.count, 2)
        XCTAssertEqual(q.pending.first(where: { $0.mediaId == 1 })?.progress, 7)
    }

    func testPersistenceRoundTrips() {
        let dir = tempDir()
        makeQueue(dir).enqueue(update(.mal, 9, progress: 4))
        let reopened = makeQueue(dir)
        XCTAssertEqual(reopened.pending.map(\.mediaId), [9])
    }

    func testDiscardWritesForProvider() {
        let q = makeQueue(tempDir())
        q.enqueue(update(.anilist, 1, progress: 1))
        q.enqueue(update(.mal, 2, progress: 1))
        q.discardWrites(for: .anilist)
        XCTAssertEqual(q.pending.map(\.provider), [.mal])
    }

    func testIsTransientClassification() {
        XCTAssertTrue(PendingWriteQueue.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertTrue(PendingWriteQueue.isTransient(AniListError.rateLimited))
        XCTAssertTrue(PendingWriteQueue.isTransient(AniListError.httpError(403)))
        XCTAssertTrue(PendingWriteQueue.isTransient(ProviderError.serverError(503)))
        XCTAssertFalse(PendingWriteQueue.isTransient(AniListError.httpError(400)))
        XCTAssertFalse(PendingWriteQueue.isTransient(ProviderError.notFound))
    }

    /// An error the service explained in its body must be classified by its status, exactly as
    /// a bare one is. AniList reports "the API has been temporarily disabled" as a 403; treating
    /// that as permanent would discard a write made during the outage instead of retrying it.
    func testServiceMessagesAreClassifiedByStatus() {
        XCTAssertTrue(PendingWriteQueue.isTransient(
            AniListError.serviceMessage(code: 403, message: "The AniList API has been temporarily disabled.")))
        XCTAssertTrue(PendingWriteQueue.isTransient(
            AniListError.serviceMessage(code: 503, message: "Down for maintenance")))
        XCTAssertTrue(PendingWriteQueue.isTransient(
            AniListError.serviceMessage(code: 429, message: "Too many requests")))
        XCTAssertFalse(PendingWriteQueue.isTransient(
            AniListError.serviceMessage(code: 400, message: "Bad query")))
    }

    /// The message is what the reader sees — not a status code they can't act on.
    func testServiceMessageIsSurfacedVerbatim() {
        let text = "The AniList API has been temporarily disabled due to severe stability issues."
        XCTAssertEqual(AniListError.serviceMessage(code: 403, message: text).errorDescription, text)
    }

    func testFlushSuccessRemovesItems() async {
        let sink = FakePendingWriteSink(); sink.behavior = .succeed
        let q = makeQueue(tempDir(), sink: sink)
        q.enqueue(update(.anilist, 1, progress: 1))
        await q.flush()
        XCTAssertTrue(q.pending.isEmpty)
        XCTAssertEqual(sink.performed.count, 1)
    }

    func testFlushTransientKeepsAndIncrementsAttempts() async {
        let sink = FakePendingWriteSink(); sink.behavior = .transientFail
        let q = makeQueue(tempDir(), sink: sink)
        q.enqueue(update(.anilist, 1, progress: 1))
        await q.flush()
        XCTAssertEqual(q.pending.count, 1)
        XCTAssertEqual(q.pending.first?.attempts, 1)
    }

    func testFlushPermanentDropsItem() async {
        let sink = FakePendingWriteSink(); sink.behavior = .permanentFail
        let q = makeQueue(tempDir(), sink: sink)
        q.enqueue(update(.anilist, 1, progress: 1))
        await q.flush()
        XCTAssertTrue(q.pending.isEmpty)
    }

    func testPoisonItemDroppedAtCap() async {
        let sink = FakePendingWriteSink(); sink.behavior = .transientFail
        let q = makeQueue(tempDir(), sink: sink, maxAttempts: 3)
        q.enqueue(update(.anilist, 1, progress: 1))
        for _ in 0..<3 { await q.flush() }
        XCTAssertTrue(q.pending.isEmpty)   // dropped once attempts reached the cap
    }
}
