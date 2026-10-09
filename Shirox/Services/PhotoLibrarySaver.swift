#if os(iOS)
import Photos
import UIKit

/// Saves images to Photos — into a "Shirox" album when the user granted full access, else
/// straight to the library (add-only or limited access can't create or fill albums).
enum PhotoLibrarySaver {
    enum Outcome {
        case savedToAlbum
        case savedToLibrary
        case denied
        case failed(Error)
    }

    private static let queue = DispatchQueue(label: "com.shirox.photoSaves")
    private static let albumTitle = "Shirox"

    /// `completion` runs on the main queue.
    static func save(_ image: UIImage, completion: @escaping (Outcome) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            queue.async {
                let outcome = save(image, status: status)
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }

    private static func save(_ image: UIImage, status: PHAuthorizationStatus) -> Outcome {
        let canUseAlbum = status == .authorized
        let canSave = canUseAlbum || status == .limited ||
            PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
        guard canSave else { return .denied }

        let album: PHAssetCollection? = canUseAlbum ? {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title = %@", albumTitle)
            return PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: options).firstObject
        }() : nil
        do {
            do {
                try add(album: album, canUseAlbum: canUseAlbum) {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
            } catch let error as NSError where error.domain == PHPhotosErrorDomain
                        && error.code == PHPhotosError.invalidResource.rawValue {
                // Photos keeps an image in the format it was decoded from and refuses some, WebP
                // among them, which is what many manga sites serve. The share sheet's copy went
                // through, as it's re-encoded; so is this one.
                guard let png = image.pngData() else { throw error }
                try add(album: album, canUseAlbum: canUseAlbum) {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: png, options: nil)
                    return request
                }
            }
            return canUseAlbum ? .savedToAlbum : .savedToLibrary
        } catch {
            return .failed(error)
        }
    }

    private static func add(album: PHAssetCollection?, canUseAlbum: Bool,
                            asset makeAsset: @escaping () -> PHAssetChangeRequest) throws {
        try PHPhotoLibrary.shared().performChangesAndWait {
            let asset = makeAsset()
            guard canUseAlbum else { return }
            let albumRequest = album.flatMap { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            if let placeholder = asset.placeholderForCreatedAsset {
                albumRequest.addAssets([placeholder] as NSArray)
            }
        }
    }
}
#endif
