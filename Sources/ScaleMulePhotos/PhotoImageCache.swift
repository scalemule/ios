#if canImport(UIKit)
import Foundation
import ScaleMuleCore
import UIKit

/// Photos in memory and on disk, so a feed opens on pictures at once (as
/// Instagram and TikTok do) while it refreshes. Keys are per photo id; the
/// newest files are kept and iOS may clear Caches when space runs low.
@MainActor
public final class PhotoImageCache {
    public static let shared = PhotoImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let folder: URL

    /// `memoryBytes` bounds the decoded pictures kept in memory (default
    /// about 150 MB: some 30 screen-sized photos).
    public init(folderName: String = "scalemule-photos", memoryBytes: Int = 150 * 1024 * 1024, filesKept: Int = 150) {
        memory.totalCostLimit = memoryBytes
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = folder
        Task.detached(priority: .utility) { Self.prune(folder, keep: filesKept) }
        // iOS asks for memory back: drop decoded pictures (the disk copies stay).
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.memory.removeAllObjects() }
        }
    }

    private var memoryWarning: NSObjectProtocol?

    /// Drop every decoded picture from memory (disk copies stay).
    public func clearMemory() {
        memory.removeAllObjects()
    }

    /// The cache key for a photo (one picture per photo).
    nonisolated public static func key(for photoId: String) -> String { "\(photoId)@feed" }

    /// In memory only (instant).
    public func image(for key: String) -> UIImage? { memory.object(forKey: key as NSString) }

    /// In memory, else from disk.
    public func saved(for key: String) async -> UIImage? {
        if let image = image(for: key) { return image }
        let url = fileURL(for: key)
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)?.preparingForDisplay()
        }.value
        if let image { memory.setObject(image, forKey: key as NSString, cost: Self.cost(image)) }
        return image
    }

    /// A picture made on this phone (for example your own new post).
    public func store(_ image: UIImage, for key: String) {
        memory.setObject(image, forKey: key as NSString, cost: Self.cost(image))
        let url = fileURL(for: key)
        Task.detached(priority: .utility) {
            try? image.jpegData(compressionQuality: 0.85)?.write(to: url, options: .atomic)
        }
    }

    /// A picture as the server sent it.
    public func store(_ image: UIImage, data: Data, for key: String) {
        memory.setObject(image, forKey: key as NSString, cost: Self.cost(image))
        let url = fileURL(for: key)
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    nonisolated private static func cost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    private func fileURL(for key: String) -> URL {
        let name = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "@" ? String($0) : "_" }.joined()
        return folder.appendingPathComponent(name).appendingPathExtension("img")
    }

    nonisolated private static func prune(_ folder: URL, keep: Int) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]),
              files.count > keep else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) {
            try? manager.removeItem(at: url)
        }
    }
}

extension PhotosService {
    /// What a feed shows while a photo loads.
    public enum LoadState: Sendable {
        /// Just posted: held back for a few seconds while it is checked for unsafe content.
        case checking
    }

    /// A photo's picture for a feed: from `cache` when it has it, else from
    /// ScaleMule at `width`, waiting (about 30 s) through the safety check
    /// and brief outages. Stops early only for "you may not see this"
    /// (401/403/410). JPEG by default: decoding is fastest and every iPhone
    /// shows it.
    public func loadImage(
        id: String,
        width: Int,
        format: PhotoFormat = .jpeg,
        cache: PhotoImageCache? = nil,
        onState: (@MainActor @Sendable (LoadState) -> Void)? = nil
    ) async -> ApiResponse<UIImage> {
        let key = PhotoImageCache.key(for: id)
        // One picture per photo: a cached one smaller than asked for (a
        // thumbnail) is fetched again at this size and replaces it.
        if let cache, let saved = await cache.saved(for: key) {
            let side = max(saved.size.width * saved.scale, saved.size.height * saved.scale)
            if side >= CGFloat(width) * 0.9 { return .success(saved) }
        }
        var last = ApiError(code: .networkError, message: "The photo didn't load")
        for attempt in 0..<10 {
            if Task.isCancelled { return .failure(last) }
            switch await image(id: id, width: width, fit: .contain, format: format) {
            case .success(let data):
                // Decoded here, off the main thread, so scrolling never waits on it.
                let prepared = await Task.detached(priority: .userInitiated) {
                    UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data)
                }.value
                guard let decoded = prepared else {
                    return .failure(ApiError(code: .internalError, message: "The photo couldn't be read"))
                }
                if let cache { await cache.store(decoded, data: data, for: key) }
                return .success(decoded)
            case .failure(let error) where error.rawCode == Self.scanPendingCode:
                last = error
                await onState?(.checking)
            case .failure(let error) where [401, 403, 410].contains(error.statusCode ?? 0):
                return .failure(error)
            case .failure(let error):
                last = error
            }
            try? await Task.sleep(nanoseconds: UInt64(min(2 + attempt, 5)) * 1_000_000_000)
        }
        return .failure(last)
    }
}
#endif
