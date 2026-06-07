import Foundation

enum DownloadState: String, Codable {
    case pending
    case downloading
    case completed
    case failed
}

struct DownloadItem: Identifiable, Codable {
    let id: UUID
    
    // Media Identity
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let aniListID: Int?
    
    // Module Integration
    let moduleId: String?
    let detailHref: String?
    let episodeHref: String
    let streamTitle: String?
    /// nil while the batch-download pipeline is still extracting the stream URL for this
    /// item. processQueue() ignores items where this is nil; a separate task is responsible
    /// for filling it in and then re-triggering the queue.
    var streamURL: URL?
    var headers: [String: String]

    // Subtitles
    var subtitleURL: URL?
    var subtitleHeaders: [String: String]?

    // Status
    var state: DownloadState
    var progress: Double
    var error: String?

    // File Info
    var fileName: String? // Points to the .mp4 or .m3u8 file
    var relativeSubtitlePath: String?
    
    // Timing
    let createdAt: Date
    var completedAt: Date?
    
    // Task Tracking
    var taskIdentifier: Int?
    var retryCount: Int = 0
    
    // Helper to determine if we should use HLS playback
    var isHLS: Bool {
        fileName?.lowercased().hasSuffix(".m3u8") ?? false
    }
}
