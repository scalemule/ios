// Filters ("looks") and adjustments people apply to a photo or video before
// posting. Pure Core Image, so the same chain renders the on-screen preview,
// the filter thumbnails, the full photo and every frame of a video.

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// One filter in the strip under the photo.
public enum PhotoLook: String, CaseIterable, Identifiable, Sendable, Codable {
    case original, vivid, mint, golden, bright, film, dusk, fade, silver, noir

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .original: return "Original"
        case .vivid: return "Vivid"
        case .mint: return "Mint"
        case .golden: return "Golden"
        case .bright: return "Bright"
        case .film: return "Film"
        case .dusk: return "Dusk"
        case .fade: return "Fade"
        case .silver: return "Silver"
        case .noir: return "Noir"
        }
    }

    public func apply(to image: CIImage) -> CIImage {
        switch self {
        case .original:
            return image
        case .vivid:
            return image
                .vibrance(0.55)
                .colorControls(saturation: 1.08, contrast: 1.08)
        case .mint:
            // Firehosy's own look: cool, fresh greens, gently lifted shadows.
            return image
                .warmth(-0.45, tint: -6)
                .colorMatrix(red: 0.94, green: 1.0, blue: 1.02, bias: (0.0, 0.02, 0.035))
                .vibrance(0.2)
                .toneCurve(shadowLift: 0.05, highlights: 0.97)
        case .golden:
            return image
                .warmth(0.8, tint: 4)
                .vibrance(0.2)
                .colorControls(saturation: 1.05, contrast: 1.04)
        case .bright:
            return image
                .exposure(0.25)
                .vibrance(0.3)
                .toneCurve(shadowLift: 0.03, highlights: 1)
        case .film:
            return image
                .photoEffect(CIFilter.photoEffectInstant())
                .vignette(intensity: 0.6)
        case .dusk:
            return image
                .photoEffect(CIFilter.photoEffectProcess())
                .exposure(-0.1)
        case .fade:
            return image.photoEffect(CIFilter.photoEffectFade())
        case .silver:
            return image.photoEffect(CIFilter.photoEffectTonal())
        case .noir:
            return image.photoEffect(CIFilter.photoEffectNoir())
        }
    }
}

/// The sliders in Adjust.
public enum PhotoAdjustment: String, CaseIterable, Identifiable, Sendable, Codable {
    case brightness, contrast, warmth, saturation

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .warmth: return "Warmth"
        case .saturation: return "Saturation"
        }
    }

    public var symbol: String {
        switch self {
        case .brightness: return "sun.max"
        case .contrast: return "circle.lefthalf.filled"
        case .warmth: return "thermometer.medium"
        case .saturation: return "drop"
        }
    }
}

/// Everything a person changed. Slider values run from -1 to 1; 0 changes nothing.
public struct PhotoEdits: Equatable, Sendable, Codable {
    public var look: PhotoLook = .original
    public var enhance = false
    public var brightness: Double = 0
    public var contrast: Double = 0
    public var warmth: Double = 0
    public var saturation: Double = 0

    public init() {}

    public var isOriginal: Bool { self == PhotoEdits() }
    public var hasAdjustments: Bool { brightness != 0 || contrast != 0 || warmth != 0 || saturation != 0 }

    public subscript(adjustment: PhotoAdjustment) -> Double {
        get {
            switch adjustment {
            case .brightness: return brightness
            case .contrast: return contrast
            case .warmth: return warmth
            case .saturation: return saturation
            }
        }
        set {
            let value = min(1, max(-1, newValue))
            switch adjustment {
            case .brightness: brightness = value
            case .contrast: contrast = value
            case .warmth: warmth = value
            case .saturation: saturation = value
            }
        }
    }

    /// Enhance, then the look, then the sliders.
    public func apply(to image: CIImage, enhancement: [CIFilter]) -> CIImage {
        var output = image
        if enhance {
            for filter in enhancement {
                filter.setValue(output, forKey: kCIInputImageKey)
                if let next = filter.outputImage { output = next }
            }
        }
        output = look.apply(to: output)
        if brightness != 0 { output = output.exposure(brightness * 0.8) }
        if contrast != 0 || saturation != 0 {
            output = output.colorControls(saturation: 1 + saturation * (saturation > 0 ? 0.6 : 1), contrast: 1 + contrast * 0.25)
        }
        if warmth != 0 { output = output.warmth(warmth, tint: 0) }
        return output.cropped(to: image.extent)
    }
}

public enum PhotoLookEngine {
    /// One context for the whole app: building one is slow.
    public static let context = CIContext(options: [.cacheIntermediates: false])

    /// Auto-enhance for this photo (exposure, white balance, shadows), worked out once.
    public static func enhancement(for image: CIImage) -> [CIFilter] {
        image.autoAdjustmentFilters(options: [.redEye: false, .crop: false, .level: false])
    }

    public static func render(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

// MARK: - Building blocks

extension CIImage {
    public func scaled(toMaxSide maxSide: CGFloat) -> CIImage {
        let longest = max(extent.width, extent.height)
        guard longest > maxSide, longest > 0 else { return self }
        let scale = maxSide / longest
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = self
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let output = filter.outputImage else { return self }
        return output.transformed(by: CGAffineTransform(translationX: -output.extent.origin.x, y: -output.extent.origin.y))
    }

    fileprivate func vibrance(_ amount: Float) -> CIImage {
        let filter = CIFilter.vibrance()
        filter.inputImage = self
        filter.amount = amount
        return filter.outputImage ?? self
    }

    fileprivate func colorControls(saturation: Double = 1, contrast: Double = 1) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = self
        filter.saturation = Float(saturation)
        filter.contrast = Float(contrast)
        return filter.outputImage ?? self
    }

    fileprivate func exposure(_ ev: Double) -> CIImage {
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = self
        filter.ev = Float(ev)
        return filter.outputImage ?? self
    }

    /// amount > 0 warms, < 0 cools; 1 is a strong shift.
    fileprivate func warmth(_ amount: Double, tint: Double) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = self
        filter.neutral = CIVector(x: 6500, y: 0)
        // Cooling needs a bigger step in kelvin than warming for the same visible change.
        let kelvin = amount >= 0 ? 6500 - amount * 2200 : 6500 - amount * 5000
        filter.targetNeutral = CIVector(x: CGFloat(kelvin), y: CGFloat(tint))
        return filter.outputImage ?? self
    }

    fileprivate func colorMatrix(red: CGFloat, green: CGFloat, blue: CGFloat, bias: (CGFloat, CGFloat, CGFloat)) -> CIImage {
        let filter = CIFilter.colorMatrix()
        filter.inputImage = self
        filter.rVector = CIVector(x: red, y: 0, z: 0, w: 0)
        filter.gVector = CIVector(x: 0, y: green, z: 0, w: 0)
        filter.bVector = CIVector(x: 0, y: 0, z: blue, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: bias.0, y: bias.1, z: bias.2, w: 0)
        return filter.outputImage ?? self
    }

    fileprivate func toneCurve(shadowLift: CGFloat, highlights: CGFloat) -> CIImage {
        let filter = CIFilter.toneCurve()
        filter.inputImage = self
        filter.point0 = CGPoint(x: 0, y: shadowLift)
        filter.point1 = CGPoint(x: 0.25, y: 0.25 + shadowLift * 0.5)
        filter.point2 = CGPoint(x: 0.5, y: 0.5)
        filter.point3 = CGPoint(x: 0.75, y: 0.75 - (1 - highlights) * 0.3)
        filter.point4 = CGPoint(x: 1, y: highlights)
        return filter.outputImage ?? self
    }

    fileprivate func vignette(intensity: Float) -> CIImage {
        let filter = CIFilter.vignette()
        filter.inputImage = self
        filter.intensity = intensity
        filter.radius = Float(max(extent.width, extent.height) / 1.6)
        return filter.outputImage ?? self
    }

    fileprivate func photoEffect(_ filter: CIFilter & CIPhotoEffect) -> CIImage {
        filter.inputImage = self
        return filter.outputImage ?? self
    }
}

#if canImport(UIKit)
import UIKit

/// Renders one photo's edits off the main thread: a screen-sized preview while
/// editing, small filter thumbnails, and the finished photo for posting.
public actor PhotoRenderer {
    private let source: UIImage
    private var preview: CIImage?
    private var thumbnailBase: CIImage?
    private var enhancement: [CIFilter] = []

    public init(source: UIImage) {
        self.source = source
    }

    /// The photo as Core Image, turned upright.
    private static func upright(_ image: UIImage) -> CIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let oriented = CIImage(cgImage: cgImage).oriented(CGImagePropertyOrientation(image.imageOrientation))
        return oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.origin.x, y: -oriented.extent.origin.y))
    }

    private func prepare() {
        guard preview == nil, let full = Self.upright(source) else { return }
        let screen = full.scaled(toMaxSide: 1600)
        preview = screen
        thumbnailBase = screen.scaled(toMaxSide: 220)
        enhancement = PhotoLookEngine.enhancement(for: screen)
    }

    public func renderPreview(_ edits: PhotoEdits) -> UIImage? {
        prepare()
        guard let preview, let cgImage = PhotoLookEngine.render(edits.apply(to: preview, enhancement: enhancement)) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// One thumbnail per look, with Enhance and the sliders applied too.
    public func renderThumbnails(_ edits: PhotoEdits) -> [PhotoLook: UIImage] {
        prepare()
        guard let thumbnailBase else { return [:] }
        var thumbnails: [PhotoLook: UIImage] = [:]
        for look in PhotoLook.allCases {
            var variant = edits
            variant.look = look
            if let cgImage = PhotoLookEngine.render(variant.apply(to: thumbnailBase, enhancement: enhancement)) {
                thumbnails[look] = UIImage(cgImage: cgImage)
            }
        }
        return thumbnails
    }

    /// The photo to post: untouched when nothing changed, otherwise rendered at
    /// up to `maxSide` pixels (the size posts are stored at).
    public func renderFinal(_ edits: PhotoEdits, maxSide: CGFloat) -> UIImage {
        guard !edits.isOriginal else { return source }
        prepare()
        guard let full = Self.upright(source)?.scaled(toMaxSide: maxSide),
              let cgImage = PhotoLookEngine.render(edits.apply(to: full, enhancement: enhancement)) else { return source }
        return UIImage(cgImage: cgImage)
    }
}

extension CGImagePropertyOrientation {
    public init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
#endif
