import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Port of the web SDK's upload-compression.ts, on ImageIO.
///
/// Capture metadata (GPS, time, orientation) is carried over: the platform's
/// intake keeps the original privately and strips the copy it serves, so the
/// phone must not throw it away first.
public enum ImageCompression {
    /// Below this the saving is not worth the work.
    static let minimumBytes = 100 * 1024
    /// Formats the server can already deliver efficiently, or that would lose animation/vectors.
    static let skippedTypes: Set<String> = ["image/gif", "image/svg+xml", "image/webp", "image/avif"]
    static let compressibleTypes: Set<String> = ["image/jpeg", "image/jpg", "image/png", "image/heic", "image/heif"]

    public struct Result: Sendable {
        public let data: Data
        public let contentType: String
        public let filename: String
    }

    public enum Outcome: Sendable {
        case compressed(Result)
        case skipped(reason: String)
    }

    /// A smaller JPEG within `profile`, or the reason it was not made.
    public static func compress(_ data: Data, contentType: String, filename: String, profile: ImageCompressionProfile) -> Outcome {
        let type = contentType.lowercased()
        guard type.hasPrefix("image/") else { return .skipped(reason: "not_image") }
        if skippedTypes.contains(type) { return .skipped(reason: "format") }
        guard compressibleTypes.contains(type) else { return .skipped(reason: "unsupported_type") }
        // HEIC is never sent as is (Storage cannot clean it), whatever its size.
        let isHEIC = type == "image/heic" || type == "image/heif"
        if data.count < minimumBytes && !isHEIC { return .skipped(reason: "too_small") }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return .skipped(reason: "decode_failed")
        }

        // JPEG has no transparency: a transparent PNG (logo, sticker) keeps its format.
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           properties[kCGImagePropertyHasAlpha] as? Bool == true, !isHEIC {
            return .skipped(reason: "transparency")
        }

        var maxPixelSize = profile.maxPixelSize
        var quality = profile.quality
        var best: Data?
        // Lower quality first, then size, until under the target (like
        // browser-image-compression's maxSizeMB loop).
        for _ in 0..<6 {
            guard let encoded = encodeJPEG(source: source, maxPixelSize: maxPixelSize, quality: quality) else { break }
            best = encoded
            if encoded.count <= profile.maxBytes { break }
            if quality > 0.55 {
                quality -= 0.1
            } else {
                maxPixelSize = Int(Double(maxPixelSize) * 0.8)
            }
        }
        guard let best else { return .skipped(reason: "encode_failed") }
        // Not meaningfully smaller: keep the original (HEIC is always converted).
        if !isHEIC && best.count >= Int(Double(data.count) * 0.95) {
            return .skipped(reason: "no_size_reduction")
        }
        return .compressed(Result(data: best, contentType: "image/jpeg", filename: jpegName(filename)))
    }

    /// Full-resolution JPEG of an image Storage cannot clean (HEIC). Other
    /// formats are returned unchanged. Used for originals.
    public static func deliverableOriginal(_ data: Data, contentType: String, filename: String) -> Result {
        let type = contentType.lowercased()
        guard type == "image/heic" || type == "image/heif",
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let jpeg = encodeJPEG(source: source, maxPixelSize: nil, quality: 0.92) else {
            return Result(data: data, contentType: contentType, filename: filename)
        }
        return Result(data: jpeg, contentType: "image/jpeg", filename: jpegName(filename))
    }

    /// Pixel size of encoded image bytes (orientation applied), if readable.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    private static func encodeJPEG(source: CGImageSource, maxPixelSize: Int?, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let image: CGImage?
        if let maxPixelSize {
            // The thumbnailer applies the orientation, so the result is upright.
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary)
            properties[kCGImagePropertyOrientation] = 1
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }
        // The new pixels' size, not the source's.
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        // Capture metadata (EXIF, GPS) carried over with the new pixels.
        properties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func jpegName(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return (base.isEmpty ? "image" : base) + ".jpg"
    }
}
