import SwiftUI
import ImageIO
import CryptoKit
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// Public catalogue artwork only. Small decoded thumbnails stay in memory;
/// bounded, expiring disk copies survive reopening and relaunch. No feed prefetch.
@MainActor
final class GiftArtworkCache {
    static let shared = GiftArtworkCache()
    private final class Entry {
        let image: CGImage
        let expires: Date
        init(_ image: CGImage, expires: Date) { self.image = image; self.expires = expires }
    }
    private struct Loaded: @unchecked Sendable {
        let image: CGImage
        let expires: Date
    }
    private let memory = NSCache<NSString, Entry>()
    private var pending: [String: Task<Loaded?, Never>] = [:]
    private let folder: URL
    private let session: URLSession
    private let now: () -> Date
    private var memoryWarning: NSObjectProtocol?
    private static let loader = GiftArtworkLoader()
    nonisolated private static let lifetime: TimeInterval = 24 * 60 * 60

    init(folder: URL? = nil, session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("scalemule-gift-artwork", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 3
        self.session = session ?? URLSession(configuration: config)
        self.now = now
        memory.totalCostLimit = 16 * 1024 * 1024
        memory.countLimit = 64
        #if canImport(UIKit)
        memoryWarning = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearMemory() }
        }
        #endif
    }
    deinit { if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) } }

    private func key(_ url: URL, _ pixels: Int) -> String {
        SHA256.hash(data: Data("\(url.absoluteString)#\(pixels)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func image(url: URL, pixels: Int = 320) -> CGImage? {
        let key = key(url, pixels) as NSString
        guard let entry = memory.object(forKey: key) else { return nil }
        guard entry.expires > now() else { memory.removeObject(forKey: key); return nil }
        return entry.image
    }
    func clearMemory() { memory.removeAllObjects() }

    func load(url: URL, pixels: Int = 320) async -> CGImage? {
        if let saved = image(url: url, pixels: pixels) { return saved }
        let key = key(url, pixels)
        if let running = pending[key] { return await running.value?.image }
        let folder = folder, session = session, current = now()
        let file = folder.appendingPathComponent(key).appendingPathExtension("png")
        let task = Task.detached(priority: .utility) { () -> Loaded? in
            await Self.loader.run {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               current.timeIntervalSince(date) < Self.lifetime,
               let data = try? Data(contentsOf: file), let image = Self.decode(data, pixels: pixels) { return Loaded(image: image, expires: date.addingTimeInterval(Self.lifetime)) }
            guard !Task.isCancelled else { return nil }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      data.count <= 8 * 1024 * 1024, let image = Self.decode(data, pixels: pixels) else { return nil }
                // These are public gift pictures, not account data. Keep a
                // thumbnail, preserving alpha, instead of a full-size bitmap.
                let cacheControl = http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() ?? ""
                let maxAge = cacheControl.split(separator: ",").compactMap { part -> TimeInterval? in
                    let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                    return pair.count == 2 && pair[0] == "max-age" ? TimeInterval(pair[1].replacingOccurrences(of: "\"", with: "")) : nil
                }.first ?? Self.lifetime
                let duration = cacheControl.contains("no-store") || cacheControl.contains("no-cache") ? 0 : max(0, min(maxAge, Self.lifetime))
                let expires = current.addingTimeInterval(duration)
                if duration > 0 {
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let encoded = NSMutableData()
                    if let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, nil)
                        if CGImageDestinationFinalize(destination) {
                            try? (encoded as Data).write(to: file, options: .atomic)
                            // Store the effective expiry even when the CDN specifies a shorter lifetime.
                            try? FileManager.default.setAttributes([.modificationDate: expires.addingTimeInterval(-Self.lifetime)], ofItemAtPath: file.path)
                            Self.prune(folder, now: current)
                        }
                    }
                }
                return Loaded(image: image, expires: expires)
            } catch {
                let failure = error as NSError
                Logger(subsystem: "com.scalemule.sdk", category: "Commerce").debug("Gift artwork load failed domain=\(failure.domain, privacy: .public) code=\(failure.code)")
                return nil // The view shows its failure placeholder; a later open retries.
            }
            }
        }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        if let result, result.expires > now() {
            memory.setObject(Entry(result.image, expires: result.expires), forKey: key as NSString,
                             cost: result.image.bytesPerRow * result.image.height)
        }
        return result?.image
    }

    nonisolated static func decode(_ data: Data, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    nonisolated private static func prune(_ folder: URL, now: Date) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate, let size = values.fileSize else { return nil }
            return (url, date, size)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.2
            if index >= 64 || bytes > 32 * 1024 * 1024 || now.timeIntervalSince(entry.1) >= lifetime {
                try? fm.removeItem(at: entry.0)
            }
        }
    }
}

/// Bound downloads and decoding together, including HTTP/2 streams. A closed
/// tray can finish its small cache fill without launching unbounded work.
private actor GiftArtworkLoader {
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func run<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        if active < 3 { active += 1 }
        else { await withCheckedContinuation { waiting.append($0) } }
        defer {
            if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
        }
        return await operation()
    }
}

struct GiftArtwork: View {
    let url: URL
    let pixels: Int
    @State private var loaded: CGImage?
    @State private var loadedURL: URL?
    @State private var failed = false
    init(url: URL, pixels: Int = 320) { self.url = url; self.pixels = pixels }
    var body: some View {
        Group {
            if let image = (loadedURL == url ? loaded : nil) ?? GiftArtworkCache.shared.image(url: url, pixels: pixels) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "gift").resizable().scaledToFit().padding(28).foregroundStyle(.secondary)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: url) {
            failed = false
            let result = await GiftArtworkCache.shared.load(url: url, pixels: pixels)
            guard !Task.isCancelled else { return }
            loadedURL = url; loaded = result; failed = result == nil
        }.accessibilityHidden(true)
    }
}
