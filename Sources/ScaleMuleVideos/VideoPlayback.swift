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
        didSet { looping.player.isMuted = isMuted }
    }

    public var player: AVPlayer { looping.player }

    private let videos: VideosService
    private let looping = LoopingPlayer()
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
#endif
