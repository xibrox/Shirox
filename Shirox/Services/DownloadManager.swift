#if os(iOS)
import Foundation
import Combine
import AVFoundation

struct DownloadContext {
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let aniListID: Int?
    let moduleId: String?
    let detailHref: String?
    let episodeHref: String
    let streamTitle: String?
    let totalEpisodes: Int?
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    
    @Published private(set) var items: [DownloadItem] = []
    
    private let downloadDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    private let hlsDownloader = HLSDownloader()
    private var hlsTasks: [UUID: Task<Void, Never>] = [:]
    
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.shirox.downloads.v2")
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {
        super.init()
        load()
    }
    
    // MARK: - Public API
    
    func download(stream: StreamResult, episodeHref: String, context: DownloadContext) {
        let id = UUID()
        let isHLS = stream.url.absoluteString.contains(".m3u8")
        
        let item = DownloadItem(
            id: id,
            mediaTitle: context.mediaTitle,
            episodeNumber: context.episodeNumber,
            episodeTitle: context.episodeTitle,
            imageUrl: context.imageUrl,
            aniListID: context.aniListID,
            moduleId: context.moduleId,
            detailHref: context.detailHref,
            episodeHref: episodeHref,
            streamTitle: context.streamTitle,
            state: .pending,
            progress: 0,
            createdAt: Date()
        )
        
        items.append(item)
        persist()
        
        if isHLS {
            startHLS(item, stream: stream)
        } else {
            startMP4(item, stream: stream)
        }
    }
    
    func remove(_ item: DownloadItem) {
        hlsTasks[item.id]?.cancel()
        hlsTasks.removeValue(forKey: item.id)
        
        if let taskID = item.taskIdentifier {
            urlSession.getAllTasks { tasks in
                tasks.first { $0.taskIdentifier == taskID }?.cancel()
            }
        }
        
        if let fileName = item.fileName {
            // Delete the file or the folder (for Local HLS)
            let path = downloadDir.appendingPathComponent(fileName)
            let folder = path.deletingLastPathComponent()
            
            if item.isHLS {
                try? FileManager.default.removeItem(at: folder)
            } else {
                try? FileManager.default.removeItem(at: path)
            }
        }
        
        items.removeAll { $0.id == item.id }
        persist()
    }
    
    func getStream(for item: DownloadItem) -> StreamResult? {
        guard item.state == .completed, let fileName = item.fileName else { return nil }
        let fileURL = downloadDir.appendingPathComponent(fileName)
        
        let playURL: URL
        if item.isHLS {
            // Local HLS manifest MUST be served through proxy to work in AVPlayer
            HLSProxyServer.shared.start(headers: ["User-Agent": URLSession.randomUserAgent])
            playURL = HLSProxyServer.shared.proxyURL(for: fileURL) ?? fileURL
            print("[Downloads] Routing Local HLS through proxy: \(playURL)")
        } else {
            // Standard MP4 is direct
            playURL = fileURL
            print("[Downloads] Playing direct MP4: \(playURL)")
        }
        
        return StreamResult(
            title: item.episodeTitle ?? "Episode \(item.episodeNumber)",
            url: playURL,
            headers: [:],
            subtitle: nil
        )
    }

    func item(for episodeHref: String, streamTitle: String?) -> DownloadItem? {
        let matchStreamTitle = streamTitle == nil
        return items.first { item in
            item.episodeHref == episodeHref && (matchStreamTitle || item.streamTitle == streamTitle)
        }
    }

    func reconnectPendingTasks() {
        for (idx, item) in items.enumerated() where item.state == .downloading {
            if item.isHLS || item.fileName == nil {
                items[idx].state = .failed
                items[idx].error = "Interrupted"
            }
        }
        persist()
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
    
    // MARK: - Private
    
    private func startHLS(_ item: DownloadItem, stream: StreamResult) {
        let id = item.id
        updateState(id, .downloading)
        
        let task = Task {
            do {
                let manifestPath = try await hlsDownloader.download(
                    id: id,
                    url: stream.url,
                    headers: stream.headers,
                    downloadDir: downloadDir,
                    onProgress: { [weak self] p in
                        Task { @MainActor in self?.updateProgress(id, p) }
                    }
                )
                updateCompletion(id, fileName: manifestPath)
            } catch {
                updateError(id, error.localizedDescription)
            }
            hlsTasks.removeValue(forKey: id)
        }
        hlsTasks[id] = task
    }
    
    private func startMP4(_ item: DownloadItem, stream: StreamResult) {
        var req = URLRequest(url: stream.url)
        stream.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        
        let task = urlSession.downloadTask(with: req)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].taskIdentifier = task.taskIdentifier
            items[idx].state = .downloading
        }
        task.resume()
        persist()
    }
    
    private func updateState(_ id: UUID, _ state: DownloadState) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].state = state
            persist()
        }
    }
    
    private func updateProgress(_ id: UUID, _ progress: Double) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].progress = progress
            objectWillChange.send()
        }
    }
    
    private func updateCompletion(_ id: UUID, fileName: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].state = .completed
            items[idx].progress = 1.0
            items[idx].fileName = fileName
            items[idx].completedAt = Date()
            persist()
        }
    }
    
    private func updateError(_ id: UUID, _ message: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].state = .failed
            items[idx].error = message
            persist()
        }
    }
    
    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: "shirox_downloads_v3")
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: "shirox_downloads_v3"),
           let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = decoded
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            if let idx = items.firstIndex(where: { $0.taskIdentifier == downloadTask.taskIdentifier }) {
                let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                items[idx].progress = p
                objectWillChange.send()
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        Task { @MainActor in
            guard let idx = items.firstIndex(where: { $0.taskIdentifier == downloadTask.taskIdentifier }) else { return }
            let id = items[idx].id
            let finalName = "\(id.uuidString).mp4"
            let destination = downloadDir.appendingPathComponent(finalName)
            
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: location, to: destination)
            
            updateCompletion(id, fileName: finalName)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error = error,
               let idx = items.firstIndex(where: { $0.taskIdentifier == task.taskIdentifier }) {
                updateError(items[idx].id, error.localizedDescription)
            }
        }
    }
}
#endif
