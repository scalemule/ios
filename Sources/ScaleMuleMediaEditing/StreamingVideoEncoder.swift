#if canImport(UIKit)
import AVFoundation
import UIKit
import VideoToolbox

/// How a posted video is encoded on the phone (Apple's video chip, no
/// battery cost to speak of): a file ScaleMule Video can stream as it is,
/// with no encoding on the server. HEVC Main 8-bit, ordinary colour
/// (BT.709, HDR is tone-mapped), upright pixels, a keyframe every
/// `keyFrameSeconds` (stream segments start on one), AAC sound.
public struct VideoEncoding: Sendable, Equatable {
    /// The short side is at most this (1080: 1080x1920 portrait).
    public var maxShortSide: Int
    /// Average bitrate at 1080x1920; smaller frames get proportionally less.
    public var bitRateAt1080p: Int
    public var keyFrameSeconds: Double
    public var frameRate: Int
    public var audioBitRate: Int

    public init(maxShortSide: Int = 1080, bitRateAt1080p: Int = 3_500_000, keyFrameSeconds: Double = 2, frameRate: Int = 30, audioBitRate: Int = 128_000) {
        self.maxShortSide = maxShortSide
        self.bitRateAt1080p = bitRateAt1080p
        self.keyFrameSeconds = keyFrameSeconds
        self.frameRate = frameRate
        self.audioBitRate = audioBitRate
    }

    /// What ScaleMule Video streams without re-encoding.
    public static let streaming = VideoEncoding()

    /// Output size for an upright `size`: the short side capped, even numbers.
    func outputSize(for size: CGSize) -> CGSize {
        let width = abs(size.width), height = abs(size.height)
        guard width > 0, height > 0 else { return CGSize(width: 1080, height: 1920) }
        let scale = min(1, CGFloat(maxShortSide) / min(width, height))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded() * 2) }
        return CGSize(width: even(width), height: even(height))
    }

    func videoBitRate(for size: CGSize) -> Int {
        let pixels = Double(size.width * size.height)
        let share = pixels / (1080.0 * 1920.0)
        return max(400_000, Int(Double(bitRateAt1080p) * min(1, share)))
    }
}

enum StreamingVideoEncoder {
    /// Encode `composition` over `timeRange` into `output` (MP4).
    static func encode(
        _ composition: AVAsset,
        videoComposition: AVVideoComposition?,
        timeRange: CMTimeRange,
        metadata: [AVMetadataItem],
        encoding: VideoEncoding,
        to output: URL
    ) async throws {
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw VideoComposerError.unreadable }
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)

        // Frames upright, ordinary colour, a steady frame rate.
        let frames: AVMutableVideoComposition
        if let videoComposition, let copy = videoComposition.mutableCopy() as? AVMutableVideoComposition {
            frames = copy
        } else {
            frames = try await upright(videoTracks[0], duration: composition.load(.duration))
        }
        frames.frameDuration = CMTime(value: 1, timescale: CMTimeScale(encoding.frameRate))
        frames.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        frames.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        frames.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let size = encoding.outputSize(for: frames.renderSize)

        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = timeRange
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.videoComposition = frames
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoComposerError.exportFailed("video reader") }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = metadata
        let colour: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
            AVVideoColorPropertiesKey: colour,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: encoding.videoBitRate(for: size),
                AVVideoMaxKeyFrameIntervalDurationKey: encoding.keyFrameSeconds,
                AVVideoMaxKeyFrameIntervalKey: Int(encoding.keyFrameSeconds * Double(encoding.frameRate)),
                AVVideoExpectedSourceFrameRateKey: encoding.frameRate,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw VideoComposerError.exportFailed("video writer") }
        writer.add(videoInput)

        var audioPair: (AVAssetReaderOutput, AVAssetWriterInput)?
        if !audioTracks.isEmpty {
            var channels = 2
            if let description = try await audioTracks.first?.load(.formatDescriptions).first,
               let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                channels = basic.mChannelsPerFrame == 1 ? 1 : 2
            }
            let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            audioOutput.alwaysCopiesSampleData = false
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels == 1 ? encoding.audioBitRate / 2 : encoding.audioBitRate,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                audioPair = (audioOutput, audioInput)
            }
        }

        guard reader.startReading() else {
            throw VideoComposerError.exportFailed(reader.error?.localizedDescription ?? "reading")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw VideoComposerError.exportFailed(writer.error?.localizedDescription ?? "writing")
        }
        writer.startSession(atSourceTime: timeRange.start)

        let pumps = [(videoOutput as AVAssetReaderOutput, videoInput)] + (audioPair.map { [$0] } ?? [])
        await withTaskGroup(of: Void.self) { group in
            for (index, pump) in pumps.enumerated() {
                let copy = SampleCopy(output: pump.0, input: pump.1, reader: reader)
                group.addTask { await copy.run(on: DispatchQueue(label: "scalemule.encode.\(index)")) }
            }
        }

        if reader.status == .failed || writer.status == .failed {
            let reason = writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "encoding"
            writer.cancelWriting()
            throw VideoComposerError.exportFailed(reason)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw VideoComposerError.exportFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }
}

extension StreamingVideoEncoder {
    /// Frames turned the way the track says to show them (a phone held
    /// upright records sideways pixels and a rotation).
    static func upright(_ track: AVAssetTrack, duration: CMTime) async throws -> AVMutableVideoComposition {
        let (natural, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        let placed = transform.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(placed, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: abs(shown.width).rounded(), height: abs(shown.height).rounded())
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate > 0 ? min(60, frameRate.rounded()) : 30))
        composition.instructions = [instruction]
        return composition
    }
}

/// Moves samples from a reader output to a writer input until either ends.
private final class SampleCopy: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let reader: AVAssetReader

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, reader: AVAssetReader) {
        self.output = output
        self.input = input
        self.reader = reader
    }

    func run(on queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) { [self] in
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !input.append(sample) {
                        finished = true
                        reader.cancelReading()
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
#endif
