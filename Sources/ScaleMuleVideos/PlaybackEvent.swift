import Foundation
import ScaleMuleCore

/// One playback event for ScaleMule Video analytics. A viewing session (one
/// `sessionId`) reports `play` at the first frame, `heartbeat` every 10 s
/// while playing, `buffer` after each stall, `complete` at each loop end,
/// `pause` when the viewer pauses or leaves, and `error`. Running totals in
/// `metadata` use the keys the ScaleMule dashboard reads: `watched_seconds`,
/// `watch_through_ratio`, `rebuffer_ratio`, `ttff_ms`, `quality_switches`,
/// `dropped_frames`, `buffering_duration_ms`, `buffer_depth_seconds`,
/// `hls_bandwidth_estimate_bps`, `hls_fragment_load_ms`, `startup_quality`,
/// `connection_effective_type`, `device_memory_gb`, `is_visible`,
/// `error_classification`.
public struct PlaybackEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case play, pause, seek, complete, buffer, error, heartbeat
    }

    public var sessionId: String
    public var type: Kind
    public var positionSeconds: Double?
    public var quality: String?
    public var metadata: [String: AnyCodable]

    public init(sessionId: String, type: Kind, positionSeconds: Double? = nil, quality: String? = nil, metadata: [String: AnyCodable] = [:]) {
        self.sessionId = sessionId
        self.type = type
        self.positionSeconds = positionSeconds
        self.quality = quality
        self.metadata = metadata
    }
}
