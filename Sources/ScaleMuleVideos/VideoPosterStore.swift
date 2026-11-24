#if canImport(UIKit)
import UIKit
import os.log

/// Decoded posters shared by speculative preparation and visible cells.
/// Requests are coalesced and bounded, including during a fast fling.
@MainActor
final class VideoPosterStore {
    static let shared = VideoPosterStore()
    private let images = NSCache<NSString, UIImage>()
    private struct Job { let token: UUID; let task: Task<UIImage?, Never> }
    private var jobs: [String: Job] = [:]
    private var order: [String] = []
    private let logger = Logger(subsystem: "com.scalemule.sdk", category: "VideoPoster")
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        images.countLimit = 32
        images.totalCostLimit = 40 * 1_024 * 1_024
    }

    func cached(_ id: String) -> UIImage? { images.object(forKey: id as NSString) }
    func store(_ image: UIImage, for id: String) {
        let bytes = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
        images.setObject(image, forKey: id as NSString, cost: bytes)
    }
    func forget(_ id: String) {
        images.removeObject(forKey: id as NSString)
        jobs.removeValue(forKey: id)?.task.cancel()
        order.removeAll { $0 == id }
    }
    func trim() {
        images.removeAllObjects()
        for job in jobs.values { job.task.cancel() }
        jobs.removeAll()
        order.removeAll()
    }

    func load(_ id: String, videos: VideosService, info: VideoInfo? = nil) async -> UIImage? {
        if let image = cached(id) { return image }
        let job: Job
        if let existing = jobs[id] { job = existing }
        else {
            while order.count >= 8 {
                let old = order.removeFirst()
                jobs.removeValue(forKey: old)?.task.cancel()
            }
            let task = Task { [logger, session] () -> UIImage? in
                let details: VideoInfo
                if let info { details = info }
                else if case .success(let fetched) = await videos.get(id: id) { details = fetched }
                else { return nil }
                guard !Task.isCancelled, let link = details.thumbnailUrl,
                      let url = URL(string: link, relativeTo: videos.client.configuration.baseURL) else { return nil }
                do {
                    let request = URLRequest(url: url, timeoutInterval: 8)
                    let (data, response) = try await session.data(for: request)
                    guard !Task.isCancelled, let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else { return nil }
                    return await Task.detached(priority: .userInitiated) {
                        UIImage(data: data)?.preparingForDisplay()
                    }.value
                } catch {
                    if !Task.isCancelled { logger.warning("Video poster download failed") }
                    return nil
                }
            }
            job = Job(token: UUID(), task: task)
            jobs[id] = job
            order.append(id)
        }
        let image = await job.task.value
        let current = jobs[id]?.token == job.token
        if current { jobs.removeValue(forKey: id); order.removeAll { $0 == id } }
        if let cached = cached(id) { return cached }
        guard current, let image else { return nil }
        store(image, for: id)
        return image
    }
}
#endif
