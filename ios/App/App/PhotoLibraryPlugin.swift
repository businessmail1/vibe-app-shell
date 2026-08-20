import Foundation
import Capacitor
import Photos
import UIKit

/**
 The real in-app camera roll — what Facebook and Instagram do.

 The app asks iOS for photo permission ONCE (the system "Allow All Photos /
 Select Photos / Don't Allow" sheet), then reads the library itself with the
 Photos framework and hands thumbnails + albums to the web layer, which renders
 them in an in-app grid. No per-pick "Photo Library" action sheet — once access
 is granted the photos are simply there, and stay there across visits.

 `<input type="file">` (the action-sheet fallback) is only used in a browser,
 where an app has no library access at all.
 */
@objc(PhotoLibraryPlugin)
public class PhotoLibraryPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "PhotoLibraryPlugin"
    public let jsName = "PhotoLibrary"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "checkPermission", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestPermission", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAlbums", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPhotos", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAsset", returnType: CAPPluginReturnPromise),
    ]

    private let imageManager = PHCachingImageManager()

    // MARK: - Permission

    @objc func checkPermission(_ call: CAPPluginCall) {
        call.resolve(["status": Self.statusString(PHPhotoLibrary.authorizationStatus(for: .readWrite))])
    }

    @objc func requestPermission(_ call: CAPPluginCall) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            call.resolve(["status": Self.statusString(status)])
        }
    }

    private static func statusString(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "denied"
        }
    }

    // MARK: - Albums

    @objc func getAlbums(_ call: CAPPluginCall) {
        guard hasAccess() else { call.reject("no_permission"); return }
        var albums: [[String: Any]] = []

        // "Recents" first — the whole library, matching the Photos app.
        let all = PHAsset.fetchAssets(with: fetchOptions(nil))
        albums.append([
            "id": "recents",
            "title": "Recents",
            "count": all.count,
            "cover": all.firstObject.map { thumbnail(for: $0, size: 200) } as Any,
        ])

        func add(_ collection: PHAssetCollection) {
            let assets = PHAsset.fetchAssets(in: collection, options: self.fetchOptions(nil))
            guard assets.count > 0 else { return }
            albums.append([
                "id": collection.localIdentifier,
                "title": collection.localizedTitle ?? "Album",
                "count": assets.count,
                "cover": assets.firstObject.map { self.thumbnail(for: $0, size: 200) } as Any,
            ])
        }

        // The categories people actually look for, in the Photos app's order.
        let smartTypes: [PHAssetCollectionSubtype] = [
            .smartAlbumFavorites, .smartAlbumVideos, .smartAlbumSelfPortraits,
            .smartAlbumScreenshots, .smartAlbumLivePhotos, .smartAlbumPanoramas,
            .smartAlbumBursts, .smartAlbumSlomoVideos, .smartAlbumTimelapses,
        ]
        for subtype in smartTypes {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
                .enumerateObjects { collection, _, _ in add(collection) }
        }
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { collection, _, _ in add(collection) }
        call.resolve(["albums": albums])
    }

    // MARK: - Photos (paged grid)

    @objc func getPhotos(_ call: CAPPluginCall) {
        guard hasAccess() else { call.reject("no_permission"); return }
        let albumId = call.getString("albumId") ?? "recents"
        let page = call.getInt("page") ?? 0
        let pageSize = call.getInt("pageSize") ?? 60
        let wantVideos = call.getBool("videos") ?? true

        let assets: PHFetchResult<PHAsset>
        if albumId == "recents" {
            assets = PHAsset.fetchAssets(with: fetchOptions(wantVideos ? nil : .image))
        } else if let collection = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumId], options: nil).firstObject {
            assets = PHAsset.fetchAssets(in: collection, options: fetchOptions(wantVideos ? nil : .image))
        } else {
            call.resolve(["photos": [], "hasMore": false]); return
        }

        let start = page * pageSize
        let end = min(start + pageSize, assets.count)
        var photos: [[String: Any]] = []
        if start < end {
            for i in start..<end {
                let asset = assets.object(at: i)
                photos.append([
                    "id": asset.localIdentifier,
                    "thumb": thumbnail(for: asset, size: 300),
                    "isVideo": asset.mediaType == .video,
                    "duration": asset.duration,
                ])
            }
        }
        call.resolve(["photos": photos, "hasMore": end < assets.count])
    }

    // MARK: - Full asset for upload

    @objc func getAsset(_ call: CAPPluginCall) {
        guard hasAccess() else { call.reject("no_permission"); return }
        guard let id = call.getString("id"),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            call.reject("not_found"); return
        }

        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            imageManager.requestExportSession(forVideo: asset, options: options, exportPreset: AVAssetExportPresetHighestQuality) { session, _ in
                guard let session = session else { call.reject("export_failed"); return }
                let out = self.tempURL(ext: "mp4")
                session.outputURL = out
                session.outputFileType = .mp4
                session.exportAsynchronously {
                    if session.status == .completed {
                        let bytes = (try? Data(contentsOf: out)) ?? Data()
                    call.resolve([
                        "data": bytes.base64EncodedString(),
                        "isVideo": true,
                        "mime": "video/mp4",
                    ])
                    try? FileManager.default.removeItem(at: out)
                    } else {
                        call.reject("export_failed")
                    }
                }
            }
        } else {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard let data = data else { call.reject("read_failed"); return }
                let out = self.tempURL(ext: "jpg")
                do {
                    // Normalise to JPEG so the upload pipeline always gets a
                    // format it handles, regardless of HEIC etc.
                    if let img = UIImage(data: data), let jpeg = img.jpegData(compressionQuality: 0.92) {
                        try jpeg.write(to: out)
                    } else {
                        try data.write(to: out)
                    }
                    let bytes = (try? Data(contentsOf: out)) ?? Data()
                    call.resolve([
                        "data": bytes.base64EncodedString(),
                        "isVideo": false,
                        "mime": "image/jpeg",
                    ])
                    try? FileManager.default.removeItem(at: out)
                } catch {
                    call.reject("write_failed")
                }
            }
        }
    }

    // MARK: - Helpers

    private func hasAccess() -> Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    private func fetchOptions(_ mediaType: PHAssetMediaType?) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let mediaType = mediaType {
            options.predicate = NSPredicate(format: "mediaType == %d", mediaType.rawValue)
        }
        return options
    }

    /// Small JPEG thumbnail as a data: URI for the grid.
    private func thumbnail(for asset: PHAsset, size: CGFloat) -> String {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        var uri = ""
        let target = CGSize(width: size, height: size)
        imageManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFill, options: options) { image, _ in
            if let image = image, let jpeg = image.jpegData(compressionQuality: 0.7) {
                uri = "data:image/jpeg;base64," + jpeg.base64EncodedString()
            }
        }
        return uri
    }

    private func tempURL(ext: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString + "." + ext)
    }
}
