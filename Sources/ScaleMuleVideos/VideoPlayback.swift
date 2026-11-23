#if canImport(UIKit)
import AVFoundation
import Combine
import SwiftUI
import UIKit
import ScaleMuleCore

/// An AVPlayer on a layer, sized by SwiftUI.
public struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    var gravity: AVLayerVideoGravity

    public init(player: AVPlayer?, gravity: AVLayerVideoGravity = .resizeAspect) {
        self.player = player
        self.gravity = gravity
    }

    public func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.videoGravity = gravity
        view.playerLayer.player = player
        view.backgroundColor = .clear
        return view
    }

    public func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = gravity
    }

    public final class PlayerUIView: UIView {
        override public class var layerClass: AnyClass { AVPlayerLayer.self }
        public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Plays one item over and over.
@MainActor
public final class LoopingPlayer {
    public let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    public init() {}

    public func load(_ url: URL) {
        load(AVPlayerItem(url: url))
    }

    /// Loop `item`, only `timeRange` of it when given (a trimmed preview).
    public func load(_ item: AVPlayerItem, timeRange: CMTimeRange? = nil) {
        looper?.disableLooping()
        player.removeAllItems()
        if let timeRange {
            looper = AVPlayerLooper(player: player, templateItem: item, timeRange: timeRange)
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
    }

    public func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

/// Files of videos posted from this phone, by video id: your own new video
/// plays at once while ScaleMule Video makes its streaming copies.
public enum VideoFileCache {
    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("scalemule-videos", isDirectory: true)
    }
    private static let filesKept = 12

    public static func keep(_ file: URL, for videoId: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = url(videoId)
        try? manager.removeItem(at: target)
        try? manager.copyItem(at: file, to: target)
        prune()
    }

    public static func file(for videoId: String) -> URL? {
        let target = url(videoId)
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }

    private static func url(_ videoId: String) -> URL {
        let safe = videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return folder.appendingPathComponent(safe).appendingPathExtension("mp4")
    }

    private static func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > filesKept else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(filesKept) {
            try? manager.removeItem(at: file)
        }
    }
}

/// Playback links (with their short-lived token), reused until near expiry.
@MainActor
public final class VideoLinkCache {
    public static let shared = VideoLinkCache()
    private var links: [String: (url: URL, until: Date)] = [:]

    public init() {}

    public func url(for videoId: String, videos: VideosService) async -> URL? {
        if let link = links[videoId], link.until > Date() { return link.url }
        guard case .success(let url) = await videos.playbackURL(id: videoId, validFor: 3600) else { return nil }
        links[videoId] = (url, Date().addingTimeInterval(50 * 60))
        return url
    }
}

/// One video in a feed, TikTok style: poster first, plays (looping) while
/// it is the post on screen, waits while a new video is converted, pauses on
/// demand. Bind a `PlayerLayerView` to `player`.
@MainActor
public final class VideoPlaybackModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle, loading, processing, playing, failed
    }

    public let videoId: String
    @Published public private(set) var poster: UIImage?
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var isPaused = false
    @Published public var isMuted = false {
        didSet {
            looping.player.isMuted = isMuted
            // Sound turned on while playing: be heard (silent switch too).
            if phase == .playing, !isPaused, oldValue != isMuted { Self.useAudio(muted: isMuted, category: nil) }
        }
    }

    public var player: AVPlayer { looping.player }

    private let videos: VideosService
    private var looping = LoopingPlayer()
    private var startTask: Task<Void, Never>?
    private static let posters = NSCache<NSString, UIImage>()

    public init(videoId: String, videos: VideosService, poster: UIImage? = nil) {
        self.videoId = videoId
        self.videos = videos
        self.poster = poster ?? Self.posters.object(forKey: videoId as NSString)
    }

    /// A poster known on this phone (your own new post).
    public func setPoster(_ image: UIImage) {
        poster = image
        Self.posters.setObject(image, forKey: videoId as NSString)
    }

    /// Video's poster image, unless one is set.
    public func loadPoster() async {
        guard poster == nil,
              case .success(let info) = await videos.get(id: videoId),
              let link = info.thumbnailUrl,
              let url = URL(string: link, relativeTo: videos.client.configuration.baseURL),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        setPoster(image)
    }

    /// Play: this phone's copy if it has one, else the stream once ready
    /// (waiting up to about three minutes for conversion).
    public func play(audioCategory: AVAudioSession.Category = .ambient) {
        isPaused = false
        try? AVAudioSession.sharedInstance().setCategory(audioCategory, mode: .moviePlayback)
        if phase == .playing {
            looping.player.play()
            return
        }
        startTask?.cancel()
        startTask = Task { await start() }
    }

    /// The audio session for playing with sound or muted.
    static func useAudio(muted: Bool, category: AVAudioSession.Category?) {
        let session = AVAudioSession.sharedInstance()
        let chosen = category ?? audioCategory(muted: muted)
        try? session.setCategory(chosen, mode: .moviePlayback, options: chosen == .ambient ? [.mixWithOthers] : [])
        try? session.setActive(true)
    }

    static func audioCategory(muted: Bool) -> AVAudioSession.Category {
        muted ? .ambient : .playback
    }

    public func pause() {
        startTask?.cancel()
        looping.player.pause()
    }

    public func togglePause() {
        guard phase == .playing else { return }
        isPaused.toggle()
        if isPaused { looping.player.pause() } else { looping.player.play() }
    }

    /// Release the player (off screen).
    public func stop() {
        startTask?.cancel()
        looping.stop()
        phase = .idle
    }

    /// Play a known file (a preview, or a fixture).
    public func play(file: URL) {
        looping.load(file)
        looping.player.isMuted = isMuted
        looping.player.play()
        phase = .playing
    }

    private func start() async {
        if let local = VideoFileCache.file(for: videoId) {
            play(file: local)
            return
        }
        // Buffered while the previous post was on screen: starts at once.
        if let ready = VideoPreloader.shared.take(videoId) {
            objectWillChange.send()
            looping = ready
            looping.player.isMuted = isMuted
            looping.player.play()
            phase = .playing
            return
        }
        phase = .loading
        for _ in 0..<36 {
            if Task.isCancelled { return }
            switch await videos.get(id: videoId) {
            case .success(let info) where info.isReady:
                guard let url = await VideoLinkCache.shared.url(for: videoId, videos: videos) else {
                    phase = .failed
                    return
                }
                if Task.isCancelled { return }
                play(file: url)
                return
            case .success(let info) where info.status == "failed":
                phase = .failed
                return
            case .success:
                phase = .processing
            case .failure(let error) where error.statusCode == 404:
                phase = .failed
                return
            case .failure:
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        if !Task.isCancelled { phase = .failed }
    }
}
/// Buffers the next videos of a feed while the current one plays, so a
/// swipe starts the next video at once (TikTok preloads the same way). Each
/// is a muted, paused player that `VideoPlaybackModel` takes over; at most
/// `capacity` are kept, the furthest dropped first, and all go on a memory
/// warning.
@MainActor
public final class VideoPreloader {
    public static let shared = VideoPreloader()

    /// Players kept buffered (each holds a few seconds of video).
    public var capacity = 2
    private var ready: [(id: String, player: LoopingPlayer)] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var memoryWarning: NSObjectProtocol?

    public init() {
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    /// Keep these videos buffered, nearest first; others are released.
    public func preload(_ videoIds: [String], videos: VideosService) {
        let wanted = Array(videoIds.prefix(capacity))
        for (id, task) in tasks where !wanted.contains(id) {
            task.cancel()
            tasks.removeValue(forKey: id)
        }
        for entry in ready where !wanted.contains(entry.id) { entry.player.stop() }
        ready.removeAll { !wanted.contains($0.id) }
        for id in wanted where tasks[id] == nil && !ready.contains(where: { $0.id == id }) {
            guard VideoFileCache.file(for: id) == nil else { continue }
            tasks[id] = Task { [weak self] in
                guard case .success(let info) = await videos.get(id: id), info.isReady,
                      let url = await VideoLinkCache.shared.url(for: id, videos: videos),
                      !Task.isCancelled else {
                    self?.tasks.removeValue(forKey: id)
                    return
                }
                self?.buffer(id, url: url)
            }
        }
    }

    /// The buffered player for `videoId`, handed over (no longer kept here).
    public func take(_ videoId: String) -> LoopingPlayer? {
        guard let index = ready.firstIndex(where: { $0.id == videoId }) else { return nil }
        return ready.remove(at: index).player
    }

    /// Videos buffered right now (for tests and diagnostics).
    public var bufferedIds: [String] { ready.map(\.id) }

    public func clear() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        for entry in ready { entry.player.stop() }
        ready.removeAll()
    }

    func buffer(_ id: String, url: URL) {
        tasks.removeValue(forKey: id)
        let looping = LoopingPlayer()
        looping.player.isMuted = true
        looping.player.automaticallyWaitsToMinimizeStalling = true
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 4
        looping.load(item)
        looping.player.pause()
        ready.append((id, looping))
        while ready.count > capacity { ready.removeFirst().player.stop() }
    }
}
#endif
