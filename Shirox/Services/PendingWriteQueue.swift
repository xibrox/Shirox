import Foundation

/// Persisted queue of library mutations that failed transiently (rate-limit / offline). Applies
/// each edit optimistically to `LibraryCacheStore` and replays it via a `PendingWriteSink` once
/// the provider is reachable. Mirrors `LibraryCacheStore`'s persistence pattern.
@MainActor
final class PendingWriteQueue {
    static let shared = PendingWriteQueue()

    private let directory: URL
    private let cacheStore: LibraryCacheStore
    private let maxAttempts: Int
    private var sink: PendingWriteSink?
    private var queue: [PendingWrite] = []

    private var isFlushing = false
    private var retryTask: Task<Void, Never>?

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
         sink: PendingWriteSink? = nil,
         cacheStore: LibraryCacheStore = .shared,
         maxAttempts: Int = 50) {
        self.directory = directory
        self.sink = sink
        self.cacheStore = cacheStore
        self.maxAttempts = maxAttempts
        load()
    }

    var pending: [PendingWrite] { queue }

    func register(sink: PendingWriteSink) { self.sink = sink }

    // MARK: - Enqueue

    func enqueue(_ write: PendingWrite) {
        queue.removeAll { $0.dedupKey == write.dedupKey }   // last-write-wins
        queue.append(write)
        persist()
        switch write.kind {
        case .update:
            if let type = write.mediaType, let mediaId = write.mediaId {
                cacheStore.applyOptimisticUpdate(provider: write.provider, mediaType: type, mediaId: mediaId,
                                                 status: write.status, progress: write.progress, score: write.score)
            }
        case .delete:
            cacheStore.applyOptimisticDelete(provider: write.provider, mediaType: write.mediaType,
                                             mediaId: write.mediaId, entryId: write.entryId)
        }
    }

    func discardWrites(for provider: ProviderType) {
        queue.removeAll { $0.provider == provider }
        persist()
    }

    // MARK: - Flush

    /// Replay queued writes oldest-first. Success removes the item; a transient failure keeps it
    /// and increments `attempts` (dropping it at `maxAttempts`); a permanent failure drops it.
    /// Items are independent — one failure never blocks the rest. One flush in flight at a time.
    func flush() async {
        guard let sink, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        retryTask?.cancel()

        var sawTransient = false
        for write in queue {   // snapshot; mutations below touch `queue`, not this loop
            do {
                try await sink.perform(write)
                queue.removeAll { $0.id == write.id }
            } catch {
                if Self.isTransient(error) {
                    if let i = queue.firstIndex(where: { $0.id == write.id }) {
                        queue[i].attempts += 1
                        if queue[i].attempts >= maxAttempts { queue.remove(at: i) }
                        else { sawTransient = true }
                    }
                } else {
                    queue.removeAll { $0.id == write.id }   // permanent — drop
                }
            }
        }
        persist()
        if sawTransient { scheduleRetry() }
    }

    private func scheduleRetry() {
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)   // 30s
            if !Task.isCancelled { await self?.flush() }
        }
    }

    // MARK: - Classification

    nonisolated static func isTransient(_ error: Error) -> Bool {
        if ProviderManager.isOfflineError(error) { return true }
        if let e = error as? AniListError {
            switch e {
            case .rateLimited: return true
            case .httpError(let code): return code == 429 || code == 403 || code >= 500
            default: return false
            }
        }
        if let e = error as? ProviderError {
            switch e {
            case .serverError, .networkError: return true
            default: return false
            }
        }
        return false
    }

    // MARK: - Persistence

    private var fileURL: URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("pending-writes.json")
    }

    private func persist() {
        do { try JSONEncoder().encode(queue).write(to: fileURL, options: .atomic) }
        catch { assertionFailure("PendingWriteQueue: encode/write failed — \(error)") }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([PendingWrite].self, from: data) else { return }
        queue = items
    }
}
