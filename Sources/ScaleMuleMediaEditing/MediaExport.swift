#if canImport(UIKit)
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
#endif
