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
///
/// A streamed (HLS) video is fetched again on every loop by AVPlayerLooper:
/// a 5 s clip looped for a minute downloads it a dozen times, keeping the
/// radio and decoder busy and the phone hot. `replaceAtNextLoop` moves the
/// loop to a copy on the phone at the next loop boundary.
@MainActor
public final class LoopingPlayer {
    public let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var loopObservation: NSKeyValueObservation?
    private var pendingFile: URL?
    private var willReplace: (() -> Void)?
    /// Where the loop plays from (a stream link or a file on the phone).
    public private(set) var source: URL?
    /// Called on the main actor each time a loop ends.
    public var onLoop: (() -> Void)?

    public init() {}

    public func load(_ url: URL) {
        load(AVPlayerItem(url: url))
    }

    /// Loop `item`, only `timeRange` of it when given (a trimmed preview).
    public func load(_ item: AVPlayerItem, timeRange: CMTimeRange? = nil) {
        loopObservation = nil
        looper?.disableLooping()
        player.removeAllItems()
        source = (item.asset as? AVURLAsset)?.url
        let looper: AVPlayerLooper
        if let timeRange {
            looper = AVPlayerLooper(player: player, templateItem: item, timeRange: timeRange)
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
        self.looper = looper
        loopObservation = looper.observe(\.loopCount, options: [.new]) { [weak self] _, _ in
            // Next turn of the main queue: the player has moved on to the
            // next copy by then (analytics count the loop first).
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.loopEnded() }
            }
        }
    }

    /// Play `file` (the same video, on the phone) from the next loop on.
    /// `willReplace` runs just before the switch.
    public func replaceAtNextLoop(with file: URL, willReplace: (() -> Void)? = nil) {
        guard source != file else { return }
        pendingFile = file
        self.willReplace = willReplace
    }

    /// A copy is waiting for the next loop (tests).
    public var hasPendingReplacement: Bool { pendingFile != nil }

    private func loopEnded() {
        guard looper != nil else { return }
        if let file = pendingFile {
            pendingFile = nil
            let playing = player.rate > 0
            willReplace?()
            willReplace = nil
            load(file)
            if playing { player.play() }
        }
        onLoop?()
    }

    public func stop() {
        player.pause()
        loopObservation = nil
        pendingFile = nil
        willReplace = nil
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

/// Copies of streamed videos kept on the phone once watched, so a looping
/// video plays from the phone instead of downloading on every loop (the way
/// short-video apps do it), and watching it again costs no data. One quality
/// (the best up to `maxShortSide`) per video; the oldest go first beyond
/// `maxBytes`.
@MainActor
public final class VideoLoopCache {
    public static let shared = VideoLoopCache()

    public var maxBytes: Int64 = 200 * 1024 * 1024
    public var maxShortSide = 1080
    let folder: URL
    private let session: URLSession
    private var running: [String: Task<URL?, Never>] = [:]

    public init(folder: URL? = nil, session: URLSession = .shared) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("scalemule-video-loops", isDirectory: true)
        self.session = session
    }

    /// The copy on this phone, if there is one.
    public func cachedFile(for videoId: String) -> URL? {
        let target = url(videoId)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
        return target
    }

    /// The copy on this phone, downloaded once from `stream` (the video's
    /// HLS master link) when needed. Nil when it can't be fetched.
    public func file(for videoId: String, stream: URL) async -> URL? {
        if let kept = cachedFile(for: videoId) { return kept }
        if let task = running[videoId] { return await task.value }
        let target = url(videoId), folder = folder, session = session, side = maxShortSide
        let task = Task<URL?, Never> {
            await Self.download(stream: stream, maxShortSide: side, to: target, folder: folder, session: session)
        }
        running[videoId] = task
        let file = await task.value
        running[videoId] = nil
        if file != nil { prune() }
        return file
    }

    /// Delete the copy (the video was deleted).
    public func forget(_ videoId: String) {
        try? FileManager.default.removeItem(at: url(videoId))
    }

    private func url(_ videoId: String) -> URL {
        let safe = videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return folder.appendingPathComponent(safe).appendingPathExtension("mp4")
    }

    /// ScaleMule Video keeps each quality as one fragmented MP4 behind its
    /// playlist: the init section and fragments, joined, play as a file.
    nonisolated static func download(stream: URL, maxShortSide: Int, to target: URL, folder: URL, session: URLSession) async -> URL? {
        func get(_ url: URL) async -> Data? {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
            return data
        }
        guard let masterData = await get(stream),
              let variant = HLSPlaylist.bestVariant(in: String(decoding: masterData, as: UTF8.self), base: stream, maxShortSide: maxShortSide),
              let mediaData = await get(variant) else { return nil }
        let parts = HLSPlaylist.files(in: String(decoding: mediaData, as: UTF8.self), base: variant)
        guard !parts.isEmpty else { return nil }
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("part")
        defer { try? manager.removeItem(at: partial) }
        guard manager.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial) else { return nil }
        for part in parts {
            if Task.isCancelled { try? handle.close(); return nil }
            guard let (downloaded, response) = try? await session.download(from: part),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                  let bytes = try? Data(contentsOf: downloaded, options: .mappedIfSafe) else {
                try? handle.close()
                return nil
            }
            defer { try? manager.removeItem(at: downloaded) }
            do { try handle.write(contentsOf: bytes) } catch { try? handle.close(); return nil }
        }
        try? handle.close()
        try? manager.removeItem(at: target)
        do { try manager.moveItem(at: partial, to: target) } catch { return nil }
        return target
    }

    private func prune() {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let dated = files.filter { $0.pathExtension == "mp4" }.map { file -> (URL, Date, Int64) in
            let values = try? file.resourceValues(forKeys: Set(keys))
            return (file, values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }
        var total: Int64 = 0
        for (file, _, size) in dated {
            total += size
            if total > maxBytes { try? manager.removeItem(at: file) }
        }
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

    /// Delete the kept file (the video was deleted).
    public static func remove(_ videoId: String) {
        try? FileManager.default.removeItem(at: url(videoId))
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

    /// Drop the link (the video was deleted).
    public func forget(_ videoId: String) {
        links.removeValue(forKey: videoId)
    }

    /// The kept link, if any (tests and diagnostics).
    public func cachedURL(for videoId: String) -> URL? {
        links[videoId]?.url
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
    /// The caption on screen now (ScaleMule Video captions), or nil.
    @Published public private(set) var caption: String?
    /// The video has captions (show a CC button).
    @Published public private(set) var hasCaptions = false
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
    /// The viewing session being measured (ScaleMule Video analytics).
    private var analytics: PlaybackAnalytics?
    /// Audio session category last applied by `play` (for tests).
    private(set) var appliedAudioCategory: AVAudioSession.Category?
    private lazy var captionClock = CaptionClock { [weak self] text in self?.caption = text }
    private var captionTask: Task<Void, Never>?
    /// Set to false to skip fetching captions.
    public var loadsCaptions = true
    /// Loop from a copy on the phone after the first full play of a stream
    /// (no download on every loop). Off: always stream.
    public var loopsFromLocalCopy = true
    private var localCopyTask: Task<Void, Never>?
    private static let posters = NSCache<NSString, UIImage>()

    public init(videoId: String, videos: VideosService, poster: UIImage? = nil) {
        self.videoId = videoId
        self.videos = videos
        self.poster = poster ?? Self.posters.object(forKey: videoId as NSString)
    }

    /// Forget the poster kept for `videoId` (the video was deleted).
    public static func forgetPoster(_ videoId: String) {
        posters.removeObject(forKey: videoId as NSString)
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
    ///
    /// Sound follows `isMuted`, as in TikTok or Reels: unmuted plays with
    /// `.playback` (heard with the ring switch on silent), muted uses
    /// `.ambient` and leaves the person's music playing. Pass
    /// `audioCategory` to choose yourself. Each play is measured for
    /// ScaleMule Video analytics (`PlaybackAnalytics`).
    public func play(audioCategory: AVAudioSession.Category? = nil) {
        isPaused = false
        appliedAudioCategory = audioCategory ?? Self.audioCategory(muted: isMuted)
        Self.useAudio(muted: isMuted, category: audioCategory)
        if analytics == nil, PlaybackAnalytics.isEnabled {
            analytics = PlaybackAnalytics(videoId: videoId, videos: videos)
        }
        loadCaptions()
        if phase == .playing {
            looping.player.play()
            playerStarted()
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
        analytics?.pause()
    }

    public func togglePause() {
        guard phase == .playing else { return }
        isPaused.toggle()
        if isPaused {
            looping.player.pause()
            analytics?.pause()
        } else {
            looping.player.play()
        }
    }

    /// Release the player (off screen). The viewing session ends here.
    public func stop() {
        startTask?.cancel()
        analytics?.finish()
        analytics = nil
        captionTask?.cancel()
        captionTask = nil
        localCopyTask?.cancel()
        localCopyTask = nil
        captionClock.detach()
        looping.stop()
        phase = .idle
    }

    /// Play a known file (a preview, or a fixture).
    public func play(file: URL) {
        looping.load(file)
        looping.player.isMuted = isMuted
        looping.player.play()
        playerStarted()
        phase = .playing
    }

    /// The player that plays now (it changes when a preloaded one is taken).
    private func playerStarted() {
        analytics?.attach(looping.player)
        if hasCaptions { captionClock.attach(looping.player) }
        looping.onLoop = { [weak self] in self?.loopedOnce() }
    }

    /// Watched to the end of a streamed video: fetch it once and keep
    /// looping from the phone.
    private func loopedOnce() {
        guard loopsFromLocalCopy, localCopyTask == nil, let stream = looping.source,
              stream.scheme == "https" || stream.scheme == "http" else { return }
        let videoId = videoId, target = looping
        localCopyTask = Task { [weak self] in
            guard let file = await VideoLoopCache.shared.file(for: videoId, stream: stream),
                  !Task.isCancelled, let self, self.looping === target, self.phase == .playing else { return }
            target.replaceAtNextLoop(with: file) { [weak self] in self?.analytics?.itemReplaced() }
        }
    }

    private func loadCaptions() {
        guard loadsCaptions, !hasCaptions, captionTask == nil else { return }
        let videoId = videoId, videos = videos
        captionTask = Task { [weak self] in
            let track = await VideoCaptionStore.shared.track(for: videoId, videos: videos)
            guard let self, !Task.isCancelled else { return }
            self.captionTask = nil
            guard let track else { return }
            self.hasCaptions = true
            self.captionClock.set(track: track)
            if self.phase == .playing { self.captionClock.attach(self.looping.player) }
        }
    }

    private func start() async {
        if let local = VideoFileCache.file(for: videoId) ?? VideoLoopCache.shared.cachedFile(for: videoId) {
            play(file: local)
            return
        }
        // Buffered while the previous post was on screen: starts at once.
        if let ready = VideoPreloader.shared.take(videoId) {
            objectWillChange.send()
            looping = ready
            // On screen now: buffer as much as the network allows.
            for item in looping.player.items() { item.preferredForwardBufferDuration = 0 }
            looping.player.isMuted = isMuted
            looping.player.play()
            playerStarted()
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
/// Buffers the start of the next videos of a feed while the current one
/// plays, so a swipe starts the next video at once. As TikTok does, only
/// about the first second of each of the next four is fetched (most people
/// swipe on early); once a video is on screen it buffers normally. Each is
/// a muted, paused player that `VideoPlaybackModel` takes over; at most
/// `capacity` are kept, the furthest dropped first, and all go on a memory
/// warning.
@MainActor
public final class VideoPreloader {
    public static let shared = VideoPreloader()

    /// Videos kept buffered ahead.
    public var capacity = 4
    /// Seconds of each upcoming video fetched ahead.
    public var bufferSeconds: Double = 1
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
            guard VideoFileCache.file(for: id) == nil, VideoLoopCache.shared.cachedFile(for: id) == nil else { continue }
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

    /// Stop buffering `videoId` and release its player (the video was deleted).
    public func forget(_ videoId: String) {
        tasks.removeValue(forKey: videoId)?.cancel()
        for entry in ready where entry.id == videoId { entry.player.stop() }
        ready.removeAll { $0.id == videoId }
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
        item.preferredForwardBufferDuration = bufferSeconds
        looping.load(item)
        looping.player.pause()
        ready.append((id, looping))
        while ready.count > capacity { ready.removeFirst().player.stop() }
    }
}
#endif
