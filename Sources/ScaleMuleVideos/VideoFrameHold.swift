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
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var observation: NSKeyValueObservation?
    private var displayLink: CADisplayLink?
    private var transform: CGAffineTransform?
    private var metadata: Task<Void, Never>?
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
        observation = nil
        metadata?.cancel()
        rendering?.cancel()
        rendering = nil
        detachOutput()
        self.player = player
        observation = player?.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.attachCurrentItem() }
        }
        updateClock()
    }

    private func attachCurrentItem() {
        guard item !== player?.currentItem else { return }
        detachOutput()
        guard let item = player?.currentItem else { return }
        self.item = item
        transform = nil
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        self.output = output
        metadata?.cancel()
        metadata = Task { [weak self, weak item] in
            guard let item,
                  let track = try? await item.asset.loadTracks(withMediaType: .video).first,
                  let transform = try? await track.load(.preferredTransform),
                  !Task.isCancelled, self?.item === item else { return }
            self?.transform = transform
        }
    }

    private func detachOutput() {
        if let output { item?.remove(output) }
        output = nil
        item = nil
    }

    private func updateClock() {
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
        guard player?.rate != 0, rendering == nil, let output, let transform else { return }
        let time = output.itemTime(forHostTime: link.timestamp)
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
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
        metadata?.cancel()
        rendering?.cancel()
        if let output { item?.remove(output) }
    }
}
#endif
