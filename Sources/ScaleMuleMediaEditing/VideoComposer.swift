#if canImport(UIKit)
import AVFoundation
import CoreImage
import UIKit

/// What a person did to a video before posting: the clips they recorded (in
/// order), where it starts and ends, a look, and whether its sound is kept.
public struct VideoEdit: Sendable, Equatable, Codable {
    public var clips: [URL]
    /// Seconds into the joined clips.
    public var trimStart: Double
    /// Seconds into the joined clips; nil = to the end.
    public var trimEnd: Double?
    public var look: PhotoLook
    public var muted: Bool

    public init(clips: [URL], trimStart: Double = 0, trimEnd: Double? = nil, look: PhotoLook = .original, muted: Bool = false) {
        self.clips = clips
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.look = look
        self.muted = muted
    }
}

/// A video ready to upload.
public struct PreparedVideo: Sendable {
    public let file: URL
    /// As people see it (portrait stays portrait).
    public let width: Int
    public let height: Int
    public let duration: Double
    public let poster: UIImage
}

public enum VideoComposerError: LocalizedError, Sendable {
    case noClips
    case unreadable
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noClips: return "There is no video to post."
        case .unreadable: return "That video couldn't be opened."
        case .exportFailed(let reason): return "The video couldn't be prepared (\(reason))."
        }
    }
}

/// Joins clips, trims, applies a look and mutes; exports a compact file for
/// posting (1080p HEVC, about 4-6 MB per 10 s) with a poster frame. The same
/// composition drives the live preview while editing.
///
/// Clips must share one orientation (`CaptureController` records a whole
/// take at the orientation of its first clip, as TikTok does).
public enum VideoComposer {
    /// Joined length of the clips, in seconds.
    public static func duration(of clips: [URL]) async throws -> Double {
        var total = 0.0
        for clip in clips {
            // The picture's length (what joining uses).
            if let track = try await AVURLAsset(url: clip).loadTracks(withMediaType: .video).first {
                total += try await track.load(.timeRange).duration.seconds
            }
        }
        return total
    }

    /// The edit as it will be posted (look, sound), for a player while
    /// editing; loop it over `timeRange` (the trim), for example with
    /// `LoopingPlayer.load(_:timeRange:)`.
    public struct Preview: @unchecked Sendable {
        public let item: AVPlayerItem
        public let timeRange: CMTimeRange
        /// Length of all clips, before trimming.
        public let totalSeconds: Double
    }

    public static func preview(for edit: VideoEdit, maxSeconds: Double = 60) async throws -> Preview {
        let built = try await build(edit)
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        let range = trimmedRange(edit, total: built.composition.duration, maxSeconds: maxSeconds)
        return Preview(item: item, timeRange: range, totalSeconds: built.composition.duration.seconds)
    }

    /// Frames along the joined clips, for a trim strip.
    public static func frames(of clips: [URL], count: Int, maxSide: CGFloat = 160) async -> [UIImage] {
        guard count > 0, let built = try? await build(VideoEdit(clips: clips)) else { return [] }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let total = built.composition.duration.seconds
        var images: [UIImage] = []
        for index in 0..<count {
            let time = CMTime(seconds: total * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image { images.append(UIImage(cgImage: image)) }
        }
        return images
    }

    /// The finished file, at most `maxSeconds` long. `location` is written into
    /// the file for ScaleMule Video to keep privately (it serves copies without
    /// it); nothing else in the file says where it was made.
    public static func export(_ edit: VideoEdit, maxSeconds: Double = 60, location: CaptureLocation? = nil) async throws -> PreparedVideo {
        let built = try await build(edit)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("scalemule-\(UUID().uuidString).mp4")
        let preset = AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVC1920x1080)
            ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw VideoComposerError.exportFailed("no export session")
        }
        let range = trimmedRange(edit, total: built.composition.duration, maxSeconds: maxSeconds)
        session.timeRange = range
        session.videoComposition = built.videoComposition
        session.shouldOptimizeForNetworkUse = true
        if let location { session.metadata = captureMetadata(location) }
        try await run(session, to: output)

        let exported = AVURLAsset(url: output)
        let generator = AVAssetImageGenerator(asset: exported)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        let seconds = range.duration.seconds
        let frame = try await generator.image(at: CMTime(seconds: min(0.3, seconds / 2), preferredTimescale: 600)).image
        guard let track = try await exported.loadTracks(withMediaType: .video).first else { throw VideoComposerError.unreadable }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = natural.applying(transform)
        return PreparedVideo(
            file: output,
            width: Int(abs(shown.width).rounded()),
            height: Int(abs(shown.height).rounded()),
            duration: try await exported.load(.duration).seconds,
            poster: UIImage(cgImage: frame)
        )
    }

    // MARK: - Building

    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVVideoComposition?
    }

    static func build(_ edit: VideoEdit) async throws -> Built {
        guard !edit.clips.isEmpty else { throw VideoComposerError.noClips }
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoComposerError.unreadable
        }
        let audio = edit.muted ? nil : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var transform: CGAffineTransform?
        for clip in edit.clips {
            let asset = AVURLAsset(url: clip)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw VideoComposerError.unreadable }
            // The picture's own range: a clip whose sound runs longer would
            // otherwise leave a frozen gap at the join.
            let range = try await source.load(.timeRange)
            guard range.duration.seconds > 0 else { continue }
            try video.insertTimeRange(range, of: source, at: cursor)
            if transform == nil { transform = try await source.load(.preferredTransform) }
            if let audio, let sound = try await asset.loadTracks(withMediaType: .audio).first {
                let soundRange = try await sound.load(.timeRange)
                let start = CMTimeMaximum(soundRange.start, range.start)
                let end = CMTimeMinimum(soundRange.end, range.end)
                if end > start {
                    try audio.insertTimeRange(CMTimeRange(start: start, end: end), of: sound, at: cursor + (start - range.start))
                }
            }
            cursor = cursor + range.duration
        }
        video.preferredTransform = transform ?? .identity
        if let audio, audio.segments.isEmpty { composition.removeTrack(audio) }

        var videoComposition: AVVideoComposition?
        if edit.look != .original {
            let look = edit.look
            // Frames arrive upright (the track's transform applied); the look
            // is the same Core Image chain photos use.
            videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
                let source = request.sourceImage
                let output = look.apply(to: source.clampedToExtent()).cropped(to: source.extent)
                request.finish(with: output, context: PhotoLookEngine.context)
            }
        }
        return Built(composition: composition, videoComposition: videoComposition)
    }

    static func trimmedRange(_ edit: VideoEdit, total: CMTime, maxSeconds: Double) -> CMTimeRange {
        let length = total.seconds
        let start = min(max(0, edit.trimStart), max(0, length - 0.1))
        let end = min(edit.trimEnd ?? length, length, start + maxSeconds)
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: max(end, start + 0.1), preferredTimescale: 600)
        )
    }

    static func captureMetadata(_ capture: CaptureLocation) -> [AVMetadataItem] {
        let place = AVMutableMetadataItem()
        place.identifier = .quickTimeMetadataLocationISO6709
        place.value = capture.iso6709 as NSString
        place.dataType = kCMMetadataBaseDataType_UTF8 as String
        let date = AVMutableMetadataItem()
        date.identifier = .quickTimeMetadataCreationDate
        date.value = ISO8601DateFormatter().string(from: capture.takenAt) as NSString
        date.dataType = kCMMetadataBaseDataType_UTF8 as String
        return [place, date]
    }

    private static func run(_ session: AVAssetExportSession, to output: URL) async throws {
        if #available(iOS 18, macOS 15, *) {
            do {
                try await session.export(to: output, as: .mp4)
            } catch {
                throw VideoComposerError.exportFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            nonisolated(unsafe) let exporting = session
            await withCheckedContinuation { continuation in
                exporting.exportAsynchronously { continuation.resume() }
            }
            if session.status != .completed {
                throw VideoComposerError.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
            }
        }
    }
}
#endif
