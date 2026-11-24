#if canImport(UIKit)
import UIKit

/// Small posters for grids of videos (a profile's posts): scaled down to the
/// tile, kept in memory, one download per video however many tiles ask.
@MainActor
final class VideoThumbnailStore {
    static let shared = VideoThumbnailStore()
    private let images = NSCache<NSString, UIImage>()
    private var jobs: [String: Task<UIImage?, Never>] = [:]

    init() {
        images.countLimit = 200
        images.totalCostLimit = 48 * 1_024 * 1_024
    }

    func load(_ id: String, maxSide: CGFloat, videos: VideosService, session: URLSession) async -> UIImage? {
        let key = "\(id)@\(Int(maxSide))" as NSString
        if let image = images.object(forKey: key) { return image }
        if let poster = VideoPosterStore.shared.cached(id) {
            let small = await Self.scaled(poster, maxSide: maxSide)
            if let small { keep(small, key) }
            return small
        }
        let name = key as String
        if let running = jobs[name] { return await running.value }
        let task = Task<UIImage?, Never> {
            guard case .success(let info) = await videos.get(id: id), let link = info.thumbnailUrl,
                  let url = URL(string: link, relativeTo: videos.client.configuration.baseURL) else { return nil }
            guard let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 12)),
                  let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let image = UIImage(data: data) else { return nil }
            return await Self.scaled(image, maxSide: maxSide)
        }
        jobs[name] = task
        let image = await task.value
        jobs[name] = nil
        if let image { keep(image, key) }
        return image
    }

    private func keep(_ image: UIImage, _ key: NSString) {
        let bytes = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        images.setObject(image, forKey: key, cost: bytes)
    }

    nonisolated static func scaled(_ image: UIImage, maxSide: CGFloat) async -> UIImage? {
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest > maxSide, longest > 0 else { return image }
        let ratio = maxSide / longest
        let size = CGSize(width: image.size.width * image.scale * ratio, height: image.size.height * image.scale * ratio)
        return await image.byPreparingThumbnail(ofSize: size) ?? image
    }
}

extension VideosService {
    /// The video's poster scaled down so its longer side is at most
    /// `maxSide` pixels, for a grid tile. Nil when the video has no poster
    /// yet or it could not be fetched.
    @MainActor
    public func thumbnail(id: String, maxSide: CGFloat = 480, session: URLSession = .shared) async -> UIImage? {
        await VideoThumbnailStore.shared.load(id, maxSide: maxSide, videos: self, session: session)
    }
}
#endif
