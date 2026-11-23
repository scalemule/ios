import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Turns a picture into what is sent as a profile photo.
public enum ProfilePhotoImage {
    /// Longest side of the picture sent.
    public static let maxPixelSize = 1024
    static let quality = 0.85

    /// An upright JPEG of at most `maxPixelSize` on its longest side, on an
    /// opaque background, with no metadata at all (no GPS, camera or time):
    /// a profile photo is public and needs none of it. Nil when the bytes are
    /// not a readable image.
    public static func prepare(_ data: Data, maxPixelSize: Int = maxPixelSize) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  // Applies the orientation, so the pixels are upright.
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else { return nil }
        return encode(image)
    }

    /// The same for decoded pixels (already upright).
    public static func prepare(_ image: CGImage, maxPixelSize: Int = maxPixelSize) -> Data? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let scale = min(1, Double(maxPixelSize) / Double(longest))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let flattened = draw(image, width: width, height: height) else { return nil }
        return encodeJPEG(flattened)
    }

    private static func encode(_ image: CGImage) -> Data? {
        guard let flattened = draw(image, width: image.width, height: image.height) else { return nil }
        return encodeJPEG(flattened)
    }

    /// Draw onto white in sRGB: transparency becomes white, not black.
    private static func draw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        // Only the quality: no metadata dictionary is carried over.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
