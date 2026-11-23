#if canImport(UIKit)
import AVFoundation
import Foundation
import Network
import ScaleMuleCore
import UIKit

/// Measures one viewing session of a video on an `AVPlayer` and reports it
/// to ScaleMule Video analytics: `play` at the first frame (time to first
/// frame, starting quality), `heartbeat` every 10 s with running totals,
/// `buffer` after each stall, `complete` at the end of each loop, `pause`
/// when the viewer pauses or leaves, and `error`. Totals: watched seconds,
/// how far they watched (a loop counts as all of it), stall time and count,
/// quality switches, dropped frames, bandwidth and segment load time from
/// the player's access log. `VideoPlaybackModel` runs one per play; a custom
/// player can too.
@MainActor
public final class PlaybackAnalytics {
    /// Turn off playback analytics for the whole app.
    public static var isEnabled = true
    /// Seconds between heartbeats while playing.
    public static var heartbeatInterval: TimeInterval = 10

    public let sessionId: String
    private let videoId: String
    private let send: (PlaybackEvent) -> Void
    private weak var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    /// The item being measured (a looping player swaps in a new copy each loop).
    private weak var measuredItem: AVPlayerItem?
    private var measuredDuration: Double = 0
    private var sampler: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []

    private let requestedAt: Date
    private var firstFrameAt: Date?
    private var lastSampleTime: Double?
    private var lastSampleAt: Date?
    private(set) var watchedSeconds: Double = 0
    private var maxPosition: Double = 0
    private(set) var loops = 0
    private var stallStartedAt: Date?
    private(set) var stallSeconds: Double = 0
    private(set) var stallCount = 0
    private var lastHeartbeatAt = Date()
    private var finished = false
    private static let network = NetworkKind()

    /// `send` delivers each event (defaults to `VideosService.track`).
    public init(videoId: String, sessionId: String = PlaybackAnalytics.newSessionId(), send: @escaping (PlaybackEvent) -> Void) {
        self.videoId = videoId
        self.sessionId = sessionId
        self.send = send
        self.requestedAt = Date()
    }

    public convenience init(videoId: String, videos: VideosService) {
        self.init(videoId: videoId) { event in
            Task.detached(priority: .utility) { _ = await videos.track(id: videoId, event: event) }
        }
    }

    public nonisolated static func newSessionId() -> String {
        "ios-" + UUID().uuidString.lowercased()
    }

    /// Follow `player` (call again after swapping players; totals carry on).
    public func attach(_ player: AVPlayer) {
        guard Self.isEnabled, !finished else { return }
        detachObservers()
        self.player = player
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            let waitingForData = player.reasonForWaitingToPlay == .toMinimizeStalls
            MainActor.assumeIsolated { self?.statusChanged(status, waitingForData: waitingForData) }
        }
        measuredItem = player.currentItem
        itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let item = player.currentItem
            MainActor.assumeIsolated { self?.itemChanged(to: item) }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                let ours = (player as? AVQueuePlayer)?.items().contains(item) ?? (player.currentItem === item)
                guard ours else { return }
                self.reportError(message ?? "failed to play to end")
            }
        })
        sampler?.cancel()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.sample()
            }
        }
    }

    /// The viewer paused or the video left the screen: report the totals.
    public func pause() {
        guard Self.isEnabled, firstFrameAt != nil, !finished else { return }
        sample()
        emit(.pause)
    }

    /// The session is over (the post left the screen); nothing is sent after.
    public func finish() {
        guard !finished else { return }
        pause()
        finished = true
        detachObservers()
    }

    // MARK: - Measuring

    private func statusChanged(_ status: AVPlayer.TimeControlStatus, waitingForData: Bool) {
        switch status {
        case .playing:
            if firstFrameAt == nil {
                firstFrameAt = Date()
                emit(.play, extra: [
                    "ttff_ms": Int(Date().timeIntervalSince(requestedAt) * 1000),
                    "startup_quality": currentQuality(),
                ])
            }
            if let started = stallStartedAt {
                let seconds = Date().timeIntervalSince(started)
                stallStartedAt = nil
                stallSeconds += seconds
                stallCount += 1
                emit(.buffer, extra: [
                    "buffering_duration_ms": Int(seconds * 1000),
                    "buffering_state": "recovered",
                ])
            }
            lastSampleAt = Date()
            lastSampleTime = player?.currentTime().seconds
        case .waitingToPlayAtSpecifiedRate:
            // Only a stall after the first frame counts (startup is ttff).
            if firstFrameAt != nil, waitingForData, stallStartedAt == nil { stallStartedAt = Date() }
        case .paused:
            lastSampleAt = nil
        @unknown default:
            break
        }
    }

    /// A looping player (AVPlayerLooper) moved to the next copy of the video:
    /// the loop that was playing ended.
    private func itemChanged(to item: AVPlayerItem?) {
        guard let item, item !== measuredItem else { return }
        let previousLength = measuredDuration
        let hadPlayed = firstFrameAt != nil && measuredItem != nil
        measuredItem = item
        guard hadPlayed else { return }
        if let lastTime = lastSampleTime, previousLength > 0 {
            watchedSeconds += max(0, previousLength - lastTime)
        }
        loopEnded()
        lastSampleAt = Date()
        lastSampleTime = 0
    }

    private func loopEnded() {
        loops += 1
        maxPosition = 0
        emit(.complete, extra: ["loops": loops])
    }

    /// Runs twice a second: watched time, loops and heartbeats.
    func sample() {
        guard let player, player.timeControlStatus == .playing, let item = player.currentItem else {
            lastSampleAt = nil
            return
        }
        if item !== measuredItem { itemChanged(to: item) }
        let length = duration(item)
        if length > 0 { measuredDuration = length }
        let position = player.currentTime().seconds
        let now = Date()
        if let lastAt = lastSampleAt, let lastTime = lastSampleTime, position.isFinite {
            let wall = now.timeIntervalSince(lastAt)
            if position + 0.25 < lastTime {
                // Back at the start on the same item (a player that loops
                // by seeking): the loop ended.
                watchedSeconds += max(0, min(wall, duration(item) - lastTime)) + max(0, position)
                loopEnded()
            } else {
                watchedSeconds += max(0, min(wall * 1.5, position - lastTime))
            }
        }
        if position.isFinite { maxPosition = max(maxPosition, position) }
        lastSampleAt = now
        lastSampleTime = position
        if now.timeIntervalSince(lastHeartbeatAt) >= Self.heartbeatInterval {
            lastHeartbeatAt = now
            emit(.heartbeat)
        }
    }

    private func reportError(_ message: String) {
        emit(.error, extra: ["error_classification": Self.classify(message)])
    }

    // MARK: - Reporting

    private func emit(_ kind: PlaybackEvent.Kind, extra: [String: Any] = [:]) {
        guard Self.isEnabled else { return }
        var metadata = totals()
        for (key, value) in extra { metadata[key] = AnyCodable(value) }
        let position = player?.currentTime().seconds
        send(PlaybackEvent(
            sessionId: sessionId,
            type: kind,
            positionSeconds: position.flatMap { $0.isFinite ? $0 : nil },
            quality: currentQuality(),
            metadata: metadata
        ))
    }

    private func totals() -> [String: AnyCodable] {
        var values: [String: Any] = [
            "watched_seconds": (watchedSeconds * 10).rounded() / 10,
            "rebuffer_ratio": watchedSeconds > 0 ? (stallSeconds / (watchedSeconds + stallSeconds) * 1000).rounded() / 1000 : 0,
            "stall_count": stallCount,
            "loops": loops,
            "is_visible": UIApplication.shared.applicationState == .active,
            "connection_effective_type": Self.network.kind,
            "device_memory_gb": (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 * 10).rounded() / 10,
            "player": "ios-avplayer",
        ]
        if let item = player?.currentItem {
            let length = duration(item)
            if length > 0 {
                values["duration_seconds"] = (length * 10).rounded() / 10
                values["watch_through_ratio"] = loops > 0 ? 1 : (min(1, maxPosition / length) * 1000).rounded() / 1000
            }
            if let buffered = item.loadedTimeRanges.first?.timeRangeValue {
                let ahead = buffered.end.seconds - (player?.currentTime().seconds ?? 0)
                if ahead.isFinite { values["buffer_depth_seconds"] = (max(0, ahead) * 10).rounded() / 10 }
            }
            if let log = item.accessLog() {
                let events = log.events
                values["dropped_frames"] = events.reduce(0) { $0 + max(0, $1.numberOfDroppedVideoFrames) }
                var switches = 0
                var previous: Double?
                for event in events where event.indicatedBitrate > 0 {
                    if let previous, previous != event.indicatedBitrate { switches += 1 }
                    previous = event.indicatedBitrate
                }
                values["quality_switches"] = switches
                if let last = events.last {
                    if last.observedBitrate > 0 { values["hls_bandwidth_estimate_bps"] = Int(last.observedBitrate) }
                    if last.numberOfMediaRequests > 0, last.transferDuration > 0 {
                        values["hls_fragment_load_ms"] = Int(last.transferDuration / Double(last.numberOfMediaRequests) * 1000)
                    }
                }
            }
        }
        return values.mapValues(AnyCodable.init)
    }

    /// "480p": the rendition playing, from its picture height.
    private func currentQuality() -> String? {
        guard let size = player?.currentItem?.presentationSize, size.width > 0, size.height > 0 else { return nil }
        let short = Int(min(size.width, size.height).rounded())
        return "\(short)p"
    }

    private func duration(_ item: AVPlayerItem) -> Double {
        let seconds = item.duration.seconds
        return seconds.isFinite ? seconds : 0
    }

    private func detachObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        itemObservation?.invalidate()
        itemObservation = nil
        sampler?.cancel()
        sampler = nil
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        notifications.removeAll()
    }

    nonisolated static func classify(_ message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("network") || lower.contains("internet") || lower.contains("offline") || lower.contains("timed out") { return "network" }
        if lower.contains("403") || lower.contains("401") || lower.contains("forbidden") || lower.contains("token") { return "auth" }
        if lower.contains("decode") || lower.contains("format") || lower.contains("codec") { return "media" }
        return "other"
    }

    deinit {
        statusObservation?.invalidate()
        itemObservation?.invalidate()
        sampler?.cancel()
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
    }
}

/// wifi / cellular / wired / offline, kept current.
private final class NetworkKind: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var value = "unknown"

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: String
            if path.status != .satisfied { kind = "offline" }
            else if path.usesInterfaceType(.wifi) { kind = "wifi" }
            else if path.usesInterfaceType(.cellular) { kind = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { kind = "wired" }
            else { kind = "other" }
            self?.lock.lock(); self?.value = kind; self?.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "scalemule.playback.network"))
    }

    var kind: String { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
