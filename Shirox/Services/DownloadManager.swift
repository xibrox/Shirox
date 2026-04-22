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
    
    private var backgroundCompletionHandler: (() -> Void)?

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.shirox.downloads.v2")
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    private override init() {
        super.init()
        // Ensure download directory exists so it shows up in Files app
        _ = downloadDir
        load()
        reconnectBackgroundTasks()
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
            
            if item.isHLS {
                let folder = path.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: folder)
            } else {
                try? FileManager.default.removeItem(at: path)
            }
        }
        
        items.removeAll { $0.id == item.id }
        persist()
    }
    
    func getStream(for item: DownloadItem) async -> StreamResult? {
        guard item.state == .completed, let fileName = item.fileName else { return nil }
        let fileURL = downloadDir.appendingPathComponent(fileName)

        let playURL: URL
        if item.isHLS {
            // Local HLS manifest MUST be served through proxy to work in AVPlayer
            HLSProxyServer.shared.start(headers: ["User-Agent": URLSession.randomUserAgent])
            playURL = HLSProxyServer.shared.proxyURL(for: fileURL) ?? fileURL
            Logger.shared.log("[Downloads] Routing Local HLS through proxy: \(playURL)", type: "Download")
        } else {
            // Standard MP4 is direct
            playURL = fileURL
            Logger.shared.log("[Downloads] Playing direct MP4: \(playURL)", type: "Download")
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
        // This is called on app launch. MP4 tasks are handled by reconnectBackgroundTasks.
        // HLS tasks cannot be resumed automatically if the app was killed.
        for (idx, item) in items.enumerated() where item.state == .downloading {
            if item.isHLS {
                items[idx].state = .failed
                items[idx].error = "Interrupted"
            }
        }
        persist()
    }

    private func reconnectBackgroundTasks() {
        urlSession.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    if let downloadTask = task as? URLSessionDownloadTask,
                       let idx = self.items.firstIndex(where: { 
                           $0.state == .downloading && 
                           ($0.taskIdentifier == downloadTask.taskIdentifier || $0.taskIdentifier == nil)
                       }) {
                        self.items[idx].taskIdentifier = downloadTask.taskIdentifier
                        self.items[idx].state = .downloading
                    }
                }
                self.persist()
            }
        }
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == "com.shirox.downloads.v2" {
            self.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
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
        task.taskDescription = item.id.uuidString
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
                if totalBytesExpectedToWrite > 0 {
                    let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                    items[idx].progress = p
                    objectWillChange.send()
                }
            }
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // We MUST move the file synchronously here because the temp file at 'location' 
        // will be deleted as soon as this delegate method returns.
        
        guard let uuidString = downloadTask.taskDescription,
              let id = UUID(uuidString: uuidString) else {
            // Fallback: try to find by task identifier if description is missing
            let taskIdentifier = downloadTask.taskIdentifier
            Task { @MainActor in
                if let idx = self.items.firstIndex(where: { $0.taskIdentifier == taskIdentifier }) {
                    self.updateError(self.items[idx].id, "Internal error: Download task lost context")
                }
            }
            return
        }
        
        let finalName = "\(id.uuidString).mp4"
        let destination = downloadDir.appendingPathComponent(finalName)
        
        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            // Ignore if file doesn't exist
        }
        
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in
                self.updateCompletion(id, fileName: finalName)
            }
        } catch {
            Task { @MainActor in
                self.updateError(id, "Failed to save file: \(error.localizedDescription)")
            }
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskIdentifier = task.taskIdentifier
        Task { @MainActor in
            if let error = error,
               let idx = items.firstIndex(where: { $0.taskIdentifier == taskIdentifier }) {
                let nsError = error as NSError
                // Don't mark as error if it was manually cancelled
                if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled {
                    updateError(items[idx].id, error.localizedDescription)
                }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
#endif
