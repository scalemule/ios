#if canImport(UIKit)
import AVFoundation
import CoreImage
import Photos
import UIKit

/// Media leaving an app: a mark in the corner (an app's logo on other
/// people's photos) and saving to the iPhone's library with "add only"
/// access, so the app never reads the library.
public enum MediaExport {
    public enum ExportError: LocalizedError, Sendable {
        case notAllowed
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notAllowed:
                return "This app can't save to your photos. Allow it in Settings › Privacy & Security › Photos."
            case .failed(let reason):
                return "Couldn't save (\(reason))."
            }
        }
    }

    /// `mark` drawn white over a soft shadow in the bottom-right corner,
    /// about a quarter of the shorter side wide, so it reads on light and
    /// dark pictures alike.
    public static func watermarked(_ image: UIImage, mark: UIImage) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let logo = mark.withTintColor(.white, renderingMode: .alwaysOriginal)
        let shorter = min(size.width, size.height)
        let logoWidth = max(shorter * 0.24, 96)
        let logoHeight = logoWidth * logo.size.height / max(logo.size.width, 1)
        let margin = shorter * 0.035
        let rect = CGRect(x: size.width - logoWidth - margin, y: size.height - logoHeight - margin, width: logoWidth, height: logoHeight)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            context.cgContext.setShadow(offset: .zero, blur: logoHeight * 0.35, color: UIColor.black.withAlphaComponent(0.55).cgColor)
            logo.draw(in: rect, blendMode: .normal, alpha: 0.92)
            context.cgContext.restoreGState()
        }
    }

    /// `video` with `mark` in the bottom-right corner, placed and sized as on
    /// photos, written as an MP4 without metadata (no location, no device).
    /// Re-encodes the picture (a few seconds for a minute of video); the
    /// sound is kept.
    public static func watermarkedVideo(_ video: URL, mark: UIImage, output: URL? = nil) async throws -> URL {
        let asset = AVURLAsset(url: video)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw ExportError.failed("no picture") }
        guard let logo = Self.rendered(mark.withTintColor(.white, renderingMode: .alwaysOriginal))?.cgImage else {
            throw ExportError.failed("no logo")
        }
        let mark = CIImage(cgImage: logo)
        // Each frame (already upright) with the mark composited bottom right
        // over a soft shadow; Core Image counts y from the bottom.
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let frame = request.sourceImage
            let size = frame.extent.size
            let shorter = min(size.width, size.height)
            let logoWidth = max(shorter * 0.24, 96)
            let scale = logoWidth / max(mark.extent.width, 1)
            let logoHeight = mark.extent.height * scale
            let margin = shorter * 0.035
            let placed = mark
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: frame.extent.minX + size.width - logoWidth - margin, y: frame.extent.minY + margin))
            let faded = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.92)])
            let shadow = placed
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.55),
                ])
                .applyingGaussianBlur(sigma: Double(logoHeight) * 0.12)
            let marked = faded.composited(over: shadow.composited(over: frame)).cropped(to: frame.extent)
            request.finish(with: marked, context: nil)
        }

        let target = output ?? FileManager.default.temporaryDirectory.appendingPathComponent("marked-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: target)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failed("this iPhone can't prepare the video")
        }
        session.videoComposition = composition
        session.outputURL = target
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        let box = SessionBox(session)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { continuation.resume() }
        }
        guard box.session.status == .completed else {
            throw ExportError.failed(box.session.error?.localizedDescription ?? "export failed")
        }
        return target
    }

    private static func rendered(_ image: UIImage) -> UIImage? {
        UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(at: .zero) }
    }

    /// Save a JPEG to the library (asks for "add only" access once).
    public static func saveToLibrary(jpeg: Data) async throws {
        try await save { $0.addResource(with: .photo, data: jpeg, options: nil) }
    }

    /// Save a video file to the library.
    public static func saveToLibrary(video: URL) async throws {
        try await save { $0.addResource(with: .video, fileURL: video, options: nil) }
    }

    private static func save(_ add: @escaping @Sendable (PHAssetCreationRequest) -> Void) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.notAllowed }
        do {
            try await PHPhotoLibrary.shared().performChanges { add(PHAssetCreationRequest.forAsset()) }
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
    }
}
private final class SessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
#endif
