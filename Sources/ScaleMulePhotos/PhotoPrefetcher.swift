#if canImport(UIKit)
import Foundation
import UIKit

/// Loads the pictures of the next posts before they are on screen, so a
/// swipe lands on a ready picture (TikTok, Instagram). Pictures go into
/// `PhotoImageCache`, decoded; at most `concurrent` load at once, and a post
/// scrolled away from is cancelled.
@MainActor
public final class PhotoPrefetcher {
    private let photos: PhotosService
    private let cache: PhotoImageCache
    private let concurrent: Int
    private var running: [String: Task<Void, Never>] = [:]
    private var waiting: [(id: String, width: Int)] = []

    public init(photos: PhotosService, cache: PhotoImageCache = .shared, concurrent: Int = 3) {
        self.photos = photos
        self.cache = cache
        self.concurrent = concurrent
    }

    /// Pictures of these photos at `width`, nearest first. Earlier requests
    /// not in `ids` are cancelled.
    public func prefetch(_ ids: [String], width: Int) {
        let wanted = Set(ids)
        for (id, task) in running where !wanted.contains(id) {
            task.cancel()
            running.removeValue(forKey: id)
        }
        waiting = ids
            .filter { running[$0] == nil && cache.image(for: PhotoImageCache.key(for: $0)) == nil }
            .map { ($0, width) }
        startNext()
    }

    public func cancelAll() {
        waiting.removeAll()
        for task in running.values { task.cancel() }
        running.removeAll()
    }

    /// Being loaded or waiting (for tests and diagnostics).
    public var pending: Int { running.count + waiting.count }

    private func startNext() {
        while running.count < concurrent, !waiting.isEmpty {
            let next = waiting.removeFirst()
            running[next.id] = Task { [weak self, photos, cache] in
                _ = await photos.loadImage(id: next.id, width: next.width, cache: cache)
                self?.finished(next.id)
            }
        }
    }

    private func finished(_ id: String) {
        running.removeValue(forKey: id)
        startNext()
    }
}
#endif
