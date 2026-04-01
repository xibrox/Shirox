import Foundation
import SwiftUI
#if canImport(GoogleCast)
import GoogleCast
#endif

@MainActor
final class CastManager: NSObject, ObservableObject {
    static let shared = CastManager()
    
    @Published var isConnected = false
    @Published var currentDeviceName: String?
    
    private override init() {
        super.init()
        #if canImport(GoogleCast)
        setupCast()
        #endif
    }
    
    private func setupCast() {
        #if canImport(GoogleCast)
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        GCKCastContext.setSharedInstanceWith(options)
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(castSessionDidChange),
            name: .gckCastSessionDidStart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(castSessionDidChange),
            name: .gckCastSessionDidEnd,
            object: nil
        )
        #endif
    }
    
    @objc private func castSessionDidChange() {
        #if canImport(GoogleCast)
        let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession
        isConnected = session != nil
        currentDeviceName = session?.device.friendlyName
        #endif
    }
    
    func castMedia(url: URL, title: String, posterUrl: String?) {
        #if canImport(GoogleCast)
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else { return }
        
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(title, forKey: kGCKMetadataKeyTitle)
        if let posterUrl = posterUrl, let url = URL(string: posterUrl) {
            metadata.addImage(GCKImage(url: url, width: 480, height: 720))
        }
        
        let mediaInfoBuilder = GCKMediaInformationBuilder(contentURL: url)
        mediaInfoBuilder.streamType = .buffered
        mediaInfoBuilder.contentType = "video/mp4" // or application/x-mpegurl for HLS
        mediaInfoBuilder.metadata = metadata
        
        let mediaInfo = mediaInfoBuilder.build()
        
        if let remoteMediaClient = session.remoteMediaClient {
            let request = remoteMediaClient.loadMedia(mediaInfo)
            request.delegate = self
        }
        #endif
    }
}

#if canImport(GoogleCast)
extension CastManager: GCKRequestDelegate {
    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        print("[Cast] Request failed: \(error.localizedDescription)")
    }
}
#endif
