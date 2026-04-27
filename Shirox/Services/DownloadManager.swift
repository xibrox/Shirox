#if os(iOS)
import Foundation
import Combine
import AVFoundation
import SwiftUI
import UserNotifications

enum ToastType {
    case info
    case success
    case error
    case warning
    
    var color: Color {
        switch self {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        case .warning: return .orange
        }
    }
    
    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let type: ToastType
    var duration: Double = 3.0
}

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()
    
    @Published var toasts: [Toast] = []
    
    private init() {}
    
    func show(message: String, type: ToastType = .info, duration: Double = 3.0) {
        let toast = Toast(message: message, type: type, duration: duration)
        withAnimation(.spring()) {
            toasts.append(toast)
        }
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self.remove(toast)
        }
    }
    
    func remove(_ toast: Toast) {
        withAnimation(.spring()) {
            toasts.removeAll { $0.id == toast.id }
        }
    }
}

struct ToastView: View {
    @ObservedObject var manager = ToastManager.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(manager.toasts) { toast in
                HStack(spacing: 10) {
                    Image(systemName: toast.type.icon)
                        .foregroundStyle(toast.type.color)
                        .font(.system(size: 15, weight: .semibold))
                    Text(toast.message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { manager.remove(toast) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 88)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: manager.toasts.map(\.id))
    }
}

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
    
    @AppStorage("maxConcurrentDownloads") var maxConcurrentDownloads: Int = 3 {
        didSet {
            processQueue()
        }
    }
    
    private let downloadDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    
    private let hlsDownloader = HLSDownloader()
    private var hlsTasks: [UUID: Task<Void, Never>] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundCompletionHandler: (() -> Void)?

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.shirox.downloads.v2")
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        _ = downloadDir
        load()
        reconnectBackgroundTasks()
        processQueue()
        requestNotificationPermission()
        observeAppLifecycle()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleEnterBackground()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleEnterForeground()
        }
    }

    private func handleEnterBackground() {
        guard !hlsTasks.isEmpty else { return }
        // Request extra background time so in-flight HLS downloads can finish or at least
        // make progress. iOS typically grants ~30 seconds.
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "HLSDownload") { [weak self] in
            // Time is nearly up — pause downloads cleanly so they resume on return.
            self?.pauseAllHLSTasks()
            UIApplication.shared.endBackgroundTask(self?.backgroundTaskID ?? .invalid)
            self?.backgroundTaskID = .invalid
        }
    }

    private func handleEnterForeground() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        processQueue()
    }

    private func pauseAllHLSTasks() {
        for (id, task) in hlsTasks {
            task.cancel()
            if let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx].state = .pending
                items[idx].error = nil
            }
        }
        hlsTasks.removeAll()
        persist()
    }
    
    // MARK: - Public API
    
    func download(stream: StreamResult, episodeHref: String, context: DownloadContext) {
        // Prevent duplicates
        if let existing = items.first(where: { $0.episodeNumber == context.episodeNumber && $0.episodeHref == episodeHref && $0.streamTitle == context.streamTitle }) {
            let status = existing.state == .completed ? "already downloaded" : "already in queue"
            ToastManager.shared.show(message: "\(context.mediaTitle) - \(context.episodeNumber) is \(status)", type: .warning)
            return
        }
        
        let id = UUID()
        
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
            streamURL: stream.url,
            headers: stream.headers,
            state: .pending,
            progress: 0,
            createdAt: Date()
        )
        
        items.append(item)
        persist()
        
        ToastManager.shared.show(message: "Download added: \(context.mediaTitle) - \(context.episodeNumber)", type: .info)
        
        processQueue()
    }

    func batchDownload(
        mediaTitle: String,
        imageUrl: String,
        aniListID: Int?,
        moduleId: String?,
        detailHref: String?,
        episodes: [EpisodeLink],
        episodeNumbers: [Int],
        streamTitle: String
    ) {
        ToastManager.shared.show(message: "Starting batch download for \(episodeNumbers.count) episodes...", type: .info)
        
        Task {
            let runner = ModuleJSRunner()
            if let module = ModuleManager.shared.modules.first(where: { $0.id == moduleId }) {
                try? await runner.load(module: module)
            }
            
            for epNum in episodeNumbers {
                guard let episode = episodes.first(where: { Int($0.number) == epNum }) else { continue }
                
                // Check duplicate before even fetching streams to be faster
                if items.contains(where: { $0.episodeNumber == epNum && $0.episodeHref == episode.href && $0.streamTitle == streamTitle }) {
                    continue
                }

                do {
                    let fetchedStreams = try await runner.fetchStreams(episodeUrl: episode.href)
                    guard !fetchedStreams.isEmpty else {
                        ToastManager.shared.show(message: "No streams found for Ep \(epNum)", type: .warning)
                        continue
                    }
                    
                    let stream = fetchedStreams.first(where: { $0.title == streamTitle }) ?? fetchedStreams[0]
                    
                    let ctx = DownloadContext(
                        mediaTitle: mediaTitle,
                        episodeNumber: epNum,
                        episodeTitle: nil,
                        imageUrl: imageUrl,
                        aniListID: aniListID,
                        moduleId: moduleId,
                        detailHref: detailHref,
                        episodeHref: episode.href,
                        streamTitle: stream.title,
                        totalEpisodes: episodes.count
                    )
                    
                    await MainActor.run {
                        self.download(stream: stream, episodeHref: episode.href, context: ctx)
                    }
                } catch {
                    ToastManager.shared.show(message: "Failed to fetch Ep \(epNum): \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    func retry(_ item: DownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        hlsTasks[item.id]?.cancel()
        hlsTasks.removeValue(forKey: item.id)
        // Clean up partial HLS folder so the re-download starts fresh
        let folder = downloadDir.appendingPathComponent(item.id.uuidString)
        try? FileManager.default.removeItem(at: folder)
        items[idx].state = .pending
        items[idx].error = nil
        items[idx].retryCount = 0
        persist()
        processQueue()
    }

    func remove(_ item: DownloadItem) {
        hlsTasks[item.id]?.cancel()
        hlsTasks.removeValue(forKey: item.id)
        if let taskID = item.taskIdentifier {
            urlSession.getAllTasks { tasks in tasks.first { $0.taskIdentifier == taskID }?.cancel() }
        }
        if let fileName = item.fileName {
            let path = downloadDir.appendingPathComponent(fileName)
            if item.isHLS {
                try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
            } else {
                try? FileManager.default.removeItem(at: path)
            }
        }
        items.removeAll { $0.id == item.id }
        persist()
        ToastManager.shared.show(message: "Download removed: \(item.mediaTitle) - \(item.episodeNumber)", type: .info)
        processQueue()
    }

    func getStream(for item: DownloadItem) async -> StreamResult? {
        guard item.state == .completed, let fileName = item.fileName else { return nil }
        let fileURL = downloadDir.appendingPathComponent(fileName)
        let playURL: URL
        if item.isHLS {
            HLSProxyServer.shared.start(headers: ["User-Agent": URLSession.randomUserAgent])
            playURL = HLSProxyServer.shared.proxyURL(for: fileURL) ?? fileURL
            Logger.shared.log("[Downloads] Routing HLS through proxy: \(playURL)", type: "Download")
        } else {
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
        // HLS Swift Tasks don't survive app kill — reset them to pending so they restart.
        for (idx, item) in items.enumerated() where item.state == .downloading && item.isHLS {
            items[idx].state = .pending
        }
        persist()
        processQueue()
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
                self.processQueue()
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
    
    // MARK: - Queue Processing
    
    private func processQueue() {
        let activeCount = items.filter { $0.state == .downloading }.count
        let availableSlots = maxConcurrentDownloads - activeCount
        
        guard availableSlots > 0 else { return }
        
        let pendingItems = items.filter { $0.state == .pending }
        for i in 0..<min(pendingItems.count, availableSlots) {
            let item = pendingItems[i]
            startDownload(item)
        }
    }
    
    private func startDownload(_ item: DownloadItem) {
        let isHLS = item.streamURL.absoluteString.contains(".m3u8")
        if isHLS {
            startHLS(item)
        } else {
            startMP4(item)
        }
    }
    
    private func startHLS(_ item: DownloadItem) {
        let id = item.id
        updateState(id, .downloading)
        let task = Task {
            do {
                let manifestPath = try await hlsDownloader.download(
                    id: id,
                    url: item.streamURL,
                    headers: item.headers,
                    downloadDir: downloadDir,
                    onProgress: { [weak self] p in
                        Task { @MainActor in self?.updateProgress(id, p) }
                    }
                )
                updateCompletion(id, fileName: manifestPath)
            } catch {
                updateError(id, error)
            }
            hlsTasks.removeValue(forKey: id)
        }
        hlsTasks[id] = task
    }
    
    private func startMP4(_ item: DownloadItem) {
        var req = URLRequest(url: item.streamURL)
        item.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        
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
            let item = items[idx]
            items[idx].state = .completed
            items[idx].progress = 1.0
            items[idx].fileName = fileName
            items[idx].completedAt = Date()
            persist()

            let appState = UIApplication.shared.applicationState
            if appState == .background || appState == .inactive {
                sendCompletionNotification(item: item)
            } else {
                ToastManager.shared.show(message: "Download finished: \(item.mediaTitle) - Ep \(item.episodeNumber)", type: .success)
            }
            processQueue()
        }
    }

    private func sendCompletionNotification(item: DownloadItem) {
        let content = UNMutableNotificationContent()
        content.title = item.mediaTitle
        content.body = "Episode \(item.episodeNumber) finished downloading"
        content.sound = .default
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    private func updateError(_ id: UUID, _ error: Error) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let item = items[idx]
            
            if shouldAutoRetry(error: error, item: item) {
                items[idx].state = .pending
                items[idx].retryCount += 1
                persist()
                processQueue()
            } else {
                items[idx].state = .failed
                items[idx].error = error.localizedDescription
                persist()
                
                ToastManager.shared.show(message: "Download failed: \(item.mediaTitle) - \(item.episodeNumber)", type: .error)
                processQueue()
            }
        }
    }
    
    private func shouldAutoRetry(error: Error, item: DownloadItem) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        
        let transientCodes: [Int] = [
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorBackgroundSessionWasDisconnected
        ]
        
        return transientCodes.contains(nsError.code) && item.retryCount < 5
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
        guard let uuidString = downloadTask.taskDescription,
              let id = UUID(uuidString: uuidString) else {
            let taskIdentifier = downloadTask.taskIdentifier
            Task { @MainActor in
                if let idx = self.items.firstIndex(where: { $0.taskIdentifier == taskIdentifier }) {
                    self.updateError(self.items[idx].id, NSError(domain: "DownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download task lost context"]))
                }
            }
            return
        }
        let finalName = "\(id.uuidString).mp4"
        let destination = downloadDir.appendingPathComponent(finalName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in self.updateCompletion(id, fileName: finalName) }
        } catch {
            Task { @MainActor in self.updateError(id, error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor in
            if let idx = self.items.firstIndex(where: { $0.taskIdentifier == taskID }) {
                self.updateError(self.items[idx].id, error)
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
