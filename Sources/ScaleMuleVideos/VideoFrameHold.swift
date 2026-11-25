#if canImport(UIKit)
import AVFoundation
import CoreImage
import UIKit

/// A small, recent decoded frame behind AVPlayerLayer. AVFoundation can make
/// that layer transparent for one display refresh between queue replicas even
/// while isReadyForDisplay remains true. Keep the image until the viewing
/// session ends; never replace it with an empty output at a loop boundary.
@MainActor
final class VideoFrameHold {
    var onFrame: ((UIImage) -> Void)?
    var isVisible = false { didSet { updateClock() } }
    private weak var player: AVPlayer?
    private var displayLink: CADisplayLink?
    private var rendering: Task<Void, Never>?
    private var generation = 0
    private static let context = CIContext(options: [.cacheIntermediates: false])

    @MainActor private final class Tick: NSObject {
        weak var owner: VideoFrameHold?
        init(_ owner: VideoFrameHold) { self.owner = owner }
        @objc func fire(_ link: CADisplayLink) { owner?.capture(link) }
    }

    func attach(_ player: AVPlayer?) {
        generation += 1
        rendering?.cancel()
        rendering = nil
        self.player = player
        updateClock()
    }

    private func updateClock() {
        guard #available(iOS 18.0, *) else { return }
        guard isVisible, player != nil else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: Tick(self), selector: #selector(Tick.fire(_:)))
        // Only the active player produces images. One bounded image and one
        // in-flight conversion per surface; native playback keeps its full fps.
        link.preferredFramesPerSecond = 12
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func capture(_ link: CADisplayLink) {
        guard #available(iOS 18.0, *), player?.rate != 0, rendering == nil,
              let sample = player?.videoOutput?.taggedBuffers(forHostTime: CMTime(seconds: link.timestamp, preferredTimescale: 1_000_000_000)),
              let tagged = sample.taggedBufferGroup.first,
              case .pixelBuffer(let buffer) = tagged.buffer else { return }
        let transform = sample.activeConfiguration.preferredTransform
        let generation = generation
        let context = Self.context
        rendering = Task { [weak self] in
            let image = await Task.detached(priority: .utility) { () -> UIImage? in
                let source = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
                let side = max(source.extent.width, source.extent.height)
                let scale = min(1, 960 / max(side, 1))
                let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                guard let cg = context.createCGImage(small, from: small.extent) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.rendering = nil
            if let image { self.onFrame?(image) }
        }
    }

    deinit {
        displayLink?.invalidate()
        rendering?.cancel()
    }
}
#endif
