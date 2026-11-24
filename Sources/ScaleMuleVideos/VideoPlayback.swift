#if canImport(UIKit)
import AVFoundation
import Combine
import SwiftUI
import UIKit
import ScaleMuleCore
import os.log

/// An AVPlayer on a layer, sized by SwiftUI.
public struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    var gravity: AVLayerVideoGravity
    private let onReadyForDisplay: ((Bool) -> Void)?

    public init(player: AVPlayer?, gravity: AVLayerVideoGravity = .resizeAspect, onReadyForDisplay: ((Bool) -> Void)? = nil) {
        self.player = player
        self.gravity = gravity
        self.onReadyForDisplay = onReadyForDisplay
    }

    public func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.configure(player: player, gravity: gravity, onReady: onReadyForDisplay)
        view.backgroundColor = .clear
        return view
    }

    public func updateUIView(_ view: PlayerUIView, context: Context) {
        view.configure(player: player, gravity: gravity, onReady: onReadyForDisplay)
    }

    public static func dismantleUIView(_ view: PlayerUIView, coordinator: ()) {
        view.configure(player: nil, gravity: view.playerLayer.videoGravity, onReady: nil)
    }

    public final class PlayerUIView: UIView {
        override public class var layerClass: AnyClass { AVPlayerLayer.self }
        public var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private var readiness: NSKeyValueObservation?
        private var currentItemObservation: NSKeyValueObservation?
        private var onReady: ((Bool) -> Void)?
        private var generation = 0
        private var hasDisplayedFrame = false

        func configure(player: AVPlayer?, gravity: AVLayerVideoGravity, onReady: ((Bool) -> Void)?) {
            self.onReady = onReady
            if playerLayer.videoGravity != gravity { playerLayer.videoGravity = gravity }
            guard playerLayer.player !== player || readiness == nil else { return }
            generation += 1
            let generation = generation
            readiness = nil
            currentItemObservation = nil
            hasDisplayedFrame = false
            // The poster stays behind this surface. Cover an empty replacement
            // synchronously, without waiting for a SwiftUI state/render pass.
            setVideoVisible(false)
            playerLayer.player = player
            readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.displayReadinessChanged(generation: generation) }
                } else {
                    DispatchQueue.main.async { self?.displayReadinessChanged(generation: generation) }
                }
            }
            currentItemObservation = player?.observe(\.currentItem, options: [.new]) { [weak self] _, change in
                let emptied = change.newValue.flatMap { $0 } == nil
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.displayReadinessChanged(generation: generation, queueEmptied: emptied) }
                } else {
                    DispatchQueue.main.async { self?.displayReadinessChanged(generation: generation, queueEmptied: emptied) }
                }
            }
        }

        private func setVideoVisible(_ visible: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.opacity = visible ? 1 : 0
            CATransaction.commit()
        }

        private func displayReadinessChanged(generation: Int, queueEmptied: Bool = false) {
            guard self.generation == generation else { return }
            if queueEmptied || playerLayer.player?.currentItem == nil { hasDisplayedFrame = false }
            else if playerLayer.isReadyForDisplay { hasDisplayedFrame = true }
            // A queued loop can briefly reset isReadyForDisplay for its next
            // item. Keep the existing video surface and its last frame instead
            // of flashing the first-frame poster at every loop boundary.
            setVideoVisible(hasDisplayedFrame)
            // The callback may change SwiftUI state; opacity belongs to the
            // video layer's transaction, not this later notification.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.onReady?(self.hasDisplayedFrame)
            }
        }
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
    private var replacementTask: Task<Void, Never>?
    private var replacementObservation: NSKeyValueObservation?
    private var retiringLooper: AVPlayerLooper?
    private var generation = 0
    private let logger = Logger(subsystem: "com.scalemule.sdk", category: "VideoLoop")
    /// Where the loop plays from (a stream link or a file on the phone).
    public private(set) var source: URL?
    /// Called on the main actor each time a loop ends.
    public var onLoop: (() -> Void)?

    public init() {}

    /// Actually prime AVFoundation's media pipeline while paused. Merely
    /// assigning an item and a buffer-duration hint does not perform a preroll.
    func prepareStart(timeout: TimeInterval = 5) async -> Bool {
        let seconds = timeout.isFinite ? min(max(0.1, timeout), 15) : 5
        let deadline = Date().addingTimeInterval(seconds)
        while player.status != .readyToPlay || player.currentItem?.status != .readyToPlay {
            guard !Task.isCancelled, Date() < deadline, player.status != .failed,
                  player.currentItem?.status != .failed else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !Task.isCancelled, player.rate == 0 else { return false }
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.player.cancelPendingPrerolls()
        }
        defer { watchdog.cancel() }
        return await withTaskCancellationHandler {
            await player.preroll(atRate: 1)
        } onCancel: {
            Task { @MainActor [weak self] in self?.player.cancelPendingPrerolls() }
        }
    }

    public func load(_ url: URL) {
        load(AVPlayerItem(url: url))
    }

    /// Loop `item`, only `timeRange` of it when given (a trimmed preview).
    public func load(_ item: AVPlayerItem, timeRange: CMTimeRange? = nil) {
        generation += 1
        replacementTask?.cancel()
        replacementTask = nil
        replacementObservation = nil
        pendingFile = nil
        willReplace = nil
        retiringLooper = nil
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
        observeLoops(looper)
    }

    private func observeLoops(_ looper: AVPlayerLooper) {
        loopObservation = looper.observe(\.loopCount, options: [.new]) { [weak self, weak looper] _, _ in
            // Next turn of the main queue: the player has moved on to the
            // next copy by then (analytics count the loop first).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let looper, self.looper === looper else { return }
                    self.loopEnded()
                }
            }
        }
    }

    /// Queue `file` (the same video, on the phone) after the current stream
    /// iteration. Never empty the visible queue or restart its current item.
    /// On iOS 16, keep the running stream; the next activation uses the cache.
    /// `willReplace` runs when the queued local copy becomes current.
    public func replaceAtNextLoop(with file: URL, willReplace: (() -> Void)? = nil) {
        guard source != file, pendingFile == nil else { return }
        pendingFile = file
        self.willReplace = willReplace
        guard #available(iOS 17, *) else { return }
        let generation = generation
        replacementTask = Task { [weak self] in
            let asset = AVURLAsset(url: file)
            do {
                let duration = try await asset.load(.duration)
                guard duration.isNumeric, duration.seconds > 0,
                      let self, !Task.isCancelled, self.generation == generation,
                      self.pendingFile == file, self.player.currentItem != nil else { return }
                self.queueLocalCopy(asset, file: file, generation: generation)
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.logger.warning("Could not prepare a cached loop; continuing the current stream")
                self.pendingFile = nil
                self.willReplace = nil
            }
        }
    }

    @available(iOS 17, *)
    private func queueLocalCopy(_ asset: AVURLAsset, file: URL, generation: Int) {
        // disableLooping lets the current replica finish. Retain its looper
        // until that happens, then let AVQueuePlayer advance to prepared local
        // replicas. Calling load/removeAllItems here discarded the visible frame.
        retiringLooper = looper
        retiringLooper?.disableLooping()
        loopObservation = nil
        let next = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset),
                                  timeRange: .invalid, existingItemsOrdering: .loopingItemsFollowExistingItems)
        looper = next
        observeLoops(next)
        replacementObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == generation,
                      (self.player.currentItem?.asset as? AVURLAsset)?.url == file else { return }
                self.source = file
                self.pendingFile = nil
                self.willReplace?()
                self.willReplace = nil
                self.replacementObservation = nil
                self.retiringLooper = nil
                self.onLoop?()
            }
        }
    }

    /// A copy is waiting for the next loop (tests).
    public var hasPendingReplacement: Bool { pendingFile != nil }

    private func loopEnded() {
        guard looper != nil else { return }
        onLoop?()
    }

    public func stop() {
        generation += 1
        replacementTask?.cancel()
        replacementTask = nil
        replacementObservation = nil
        player.cancelPendingPrerolls()
        player.pause()
        loopObservation = nil
        pendingFile = nil
        willReplace = nil
        looper?.disableLooping()
        looper = nil
        retiringLooper = nil
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
              let variant = HLSPlaylist.bestVariant(in: String(decoding: masterData, as: UTF8.self), base: stream, maxShortSide: maxShortSide, preferHEVC: true),
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

    public init(videoId: String, videos: VideosService, poster: UIImage? = nil) {
        self.videoId = videoId
        self.videos = videos
        self.poster = poster ?? VideoPosterStore.shared.cached(videoId)
    }

    /// Forget the poster kept for `videoId` (the video was deleted).
    public static func forgetPoster(_ videoId: String) {
        VideoPosterStore.shared.forget(videoId)
    }

    /// A poster known on this phone (your own new post).
    public func setPoster(_ image: UIImage) {
        poster = image
        VideoPosterStore.shared.store(image, for: videoId)
    }

    /// Video's poster image, unless one is set.
    public func loadPoster() async {
        guard poster == nil, let image = await VideoPosterStore.shared.load(videoId, videos: videos),
              !Task.isCancelled else { return }
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
        startTask?.cancel()
        startTask = nil
        playNow(file: file)
    }

    private func playNow(file: URL) {
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
            let cached = VideoLoopCache.shared.cachedFile(for: videoId) != nil
            guard let file = await VideoLoopCache.shared.file(for: videoId, stream: stream),
                  !Task.isCancelled, let self, self.looping === target, self.phase == .playing else { return }
            if !cached, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                self.analytics?.downloaded(bytes: Int64(size))
            }
            // The download may be a higher-resolution HEVC rendition while
            // the adaptive stream is AVC. Reconfiguring that decoder mid-view
            // flashes the poster even with a nonempty queue. Keep streaming
            // this session in that case; the next activation uses the file.
            guard await Self.hasMatchingVideoFormat(target.player.currentItem, file: file),
                  !Task.isCancelled, self.looping === target, self.phase == .playing else { return }
            target.replaceAtNextLoop(with: file) { [weak self] in self?.analytics?.itemReplaced() }
        }
    }

    /// Only splice cached media into a running queue if its video decoder
    /// configuration is unchanged. Unknown formats use the next-activation path.
    static func hasMatchingVideoFormat(_ current: AVPlayerItem?, file: URL) async -> Bool {
        guard let track = current?.tracks.first(where: { $0.assetTrack?.mediaType == .video })?.assetTrack,
              let activeFormats = try? await track.load(.formatDescriptions), activeFormats.count == 1,
              let cachedTrack = try? await AVURLAsset(url: file).loadTracks(withMediaType: .video).first,
              let cachedFormats = try? await cachedTrack.load(.formatDescriptions), cachedFormats.count == 1 else { return false }
        return CMFormatDescriptionEqual(activeFormats[0], otherFormatDescription: cachedFormats[0])
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
        guard !Task.isCancelled else { return }
        // Keep the exact player prepared while the previous post was visible.
        if let ready = await VideoPreloader.shared.acquire(videoId) {
            guard !Task.isCancelled else { ready.stop(); return }
            objectWillChange.send()
            looping = ready
            // On screen now: buffer as much as the network allows.
            for item in looping.player.items() {
                item.preferredForwardBufferDuration = 0
                item.preferredPeakBitRate = 0
            }
            looping.player.isMuted = isMuted
            looping.player.play()
            playerStarted()
            phase = .playing
            return
        }
        guard !Task.isCancelled else { return }
        if let local = VideoFileCache.file(for: videoId) ?? VideoLoopCache.shared.cachedFile(for: videoId) {
            playNow(file: local)
            return
        }
        phase = .loading
        for _ in 0..<36 {
            guard !Task.isCancelled else { return }
            let result = await videos.get(id: videoId)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let info) where info.isReady:
                let resolvedURL = await VideoLinkCache.shared.url(for: videoId, videos: videos)
                guard !Task.isCancelled else { return }
                guard let url = resolvedURL else {
                    phase = .failed
                    return
                }
                playNow(file: url)
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
/// Prerolls nearby videos and hands the same player to the visible cell.
/// `activate` must run before advancing `preload`'s window, so the player the
/// user just reached is retained until its cell acquires it. At most `capacity`
/// upcoming entries plus that one active handoff are retained.
@MainActor
public final class VideoPreloader {
    public static let shared = VideoPreloader()
    public var capacity = 4
    public var bufferSeconds: Double = 1
    /// Bit-rate preference only while speculative; restored to adaptive on handoff.
    public var preferredPeakBitRate: Double = 1_000_000
    private final class Entry {
        var player: LoopingPlayer?
        var task: Task<Void, Never>?
        var finished = false
        var claimed = false
        var prerolled = false
    }
    private var entries: [String: Entry] = [:]
    private var wanted: [String] = []
    private var activeVideoId: String?
    private var memoryWarning: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.scalemule.sdk", category: "VideoPreload")

    public init() {
        memoryWarning = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    deinit {
        if let memoryWarning { NotificationCenter.default.removeObserver(memoryWarning) }
    }

    /// Called synchronously by the pager before its upcoming list changes.
    public func activate(_ videoId: String?) {
        activeVideoId = videoId
        prune()
    }

    public func preload(_ videoIds: [String], videos: VideosService) {
        var seen = Set<String>()
        wanted = Array(videoIds.filter { seen.insert($0).inserted }.prefix(max(0, capacity)))
        prune()
        for id in wanted where entries[id] == nil {
            if let file = VideoFileCache.file(for: id) ?? VideoLoopCache.shared.cachedFile(for: id) {
                schedule(id, url: file)
                continue
            }
            let entry = Entry()
            entries[id] = entry
            entry.task = Task { [weak self] in
                defer { entry.finished = true; entry.task = nil }
                guard let self else { return }
                let response = await videos.get(id: id)
                guard !Task.isCancelled, self.entries[id] === entry else { return }
                guard case .success(let info) = response, info.isReady else {
                    if case .failure(let error) = response {
                        self.logger.warning("Video preparation metadata request failed, HTTP \(error.statusCode ?? 0)")
                    }
                    if self.entries[id] === entry { self.entries.removeValue(forKey: id) }
                    return
                }
                async let poster = VideoPosterStore.shared.load(id, videos: videos, info: info)
                guard let url = await VideoLinkCache.shared.url(for: id, videos: videos),
                      !Task.isCancelled, self.entries[id] === entry else {
                    if !Task.isCancelled { self.logger.warning("Video preparation could not resolve a playback URL") }
                    if self.entries[id] === entry { self.entries.removeValue(forKey: id) }
                    return
                }
                await self.prepare(entry, id: id, url: url)
                _ = await poster
            }
        }
    }

    /// Join in-flight preparation instead of starting the same requests again.
    /// Once a player exists, take it immediately: the active cell can finish
    /// buffering in the foreground without waiting for a speculative preroll.
    public func acquire(_ videoId: String) async -> LoopingPlayer? {
        if let player = take(videoId) { return player }
        guard let entry = entries[videoId] else { return nil }
        while entries[videoId] === entry, entry.player == nil, !entry.finished {
            guard !Task.isCancelled else { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !Task.isCancelled else { return nil }
        return take(videoId)
    }

    public func take(_ videoId: String) -> LoopingPlayer? {
        guard let entry = entries[videoId], let player = entry.player else { return nil }
        entry.claimed = true
        entries.removeValue(forKey: videoId)
        entry.task?.cancel()
        player.player.cancelPendingPrerolls()
        return player
    }

    public func forget(_ videoId: String) {
        guard let entry = entries.removeValue(forKey: videoId) else { return }
        release(entry)
    }

    /// Successfully prerolled entries, rather than merely allocated players.
    public var bufferedIds: [String] { orderedIds.filter { entries[$0]?.prerolled == true } }
    public var preparingIds: [String] { orderedIds.filter { entries[$0]?.prerolled == false } }
    private var orderedIds: [String] {
        let handoff = activeVideoId.flatMap { entries[$0] != nil && !wanted.contains($0) ? $0 : nil }
        return (handoff.map { [$0] } ?? []) + wanted.filter { entries[$0] != nil }
    }

    public func clear() {
        for entry in entries.values { release(entry) }
        entries.removeAll()
        wanted.removeAll()
        activeVideoId = nil
        VideoPosterStore.shared.trim()
    }

    private func prune() {
        let allowed = Set(wanted + (activeVideoId.map { [$0] } ?? []))
        for id in Array(entries.keys) where !allowed.contains(id) { forget(id) }
    }

    private func release(_ entry: Entry) {
        entry.task?.cancel()
        if !entry.claimed { entry.player?.stop() }
    }

    private func schedule(_ id: String, url: URL) {
        let entry = Entry()
        entries[id] = entry
        entry.task = Task { [weak self] in
            defer { entry.finished = true; entry.task = nil }
            await self?.prepare(entry, id: id, url: url)
        }
    }

    private func prepare(_ entry: Entry, id: String, url: URL) async {
        guard !Task.isCancelled, entries[id] === entry else { return }
        let looping = LoopingPlayer()
        looping.player.isMuted = true
        looping.player.automaticallyWaitsToMinimizeStalling = true
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = bufferSeconds.isFinite ? min(max(0.1, bufferSeconds), 5) : 1
        looping.load(item)
        for copy in looping.player.items() {
            copy.preferredForwardBufferDuration = item.preferredForwardBufferDuration
            copy.preferredPeakBitRate = preferredPeakBitRate.isFinite ? max(0, preferredPeakBitRate) : 1_000_000
        }
        entry.player = looping
        let prepared = await looping.prepareStart()
        guard !entry.claimed else { return }
        guard !Task.isCancelled, entries[id] === entry else { looping.stop(); return }
        entry.prerolled = prepared
    }

    /// Known URLs (also used by real-file playback tests).
    func buffer(_ id: String, url: URL) {
        forget(id)
        wanted = Array((wanted.filter { $0 != id } + [id]).suffix(max(0, capacity)))
        prune()
        guard wanted.contains(id) else { return }
        schedule(id, url: url)
    }
}
#endif
