import AVFoundation
import Foundation
import ImageIO
import CoreLocation
import UniformTypeIdentifiers

/// Where and when a photo or video was taken. It travels inside the uploaded
/// file only: ScaleMule Photos and Video keep it privately with the original
/// and serve copies without it (scalemule-repos `docs/LOCATION-PRIVACY.md`).
/// What a post shows is the separate public location the person chose.
public struct CaptureLocation: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var horizontalAccuracy: Double?
    public var takenAt: Date

    public init(latitude: Double, longitude: Double, altitude: Double? = nil, horizontalAccuracy: Double? = nil, takenAt: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.takenAt = takenAt
    }

    public init(_ location: CLLocation, takenAt: Date = Date()) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            takenAt: takenAt
        )
    }

    public var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    /// ISO 6709, as QuickTime and MP4 store a video's location.
    public var iso6709: String {
        var text = String(format: "%+08.4f%+09.4f", latitude, longitude)
        if let altitude { text += String(format: "%+08.3f", altitude) }
        return text + "/"
    }
}

public enum CaptureMetadata {
    /// The JPEG with GPS position and capture time written into its metadata.
    /// The picture itself is copied, not re-compressed.
    public static func jpeg(_ data: Data, adding capture: CaptureLocation) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return data }
        let metadata = CGImageMetadataCreateMutable()
        func set(_ dictionary: CFString, _ key: CFString, _ value: Any) {
            _ = CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value as CFTypeRef)
        }
        let gps = kCGImagePropertyGPSDictionary
        set(gps, kCGImagePropertyGPSLatitude, abs(capture.latitude))
        set(gps, kCGImagePropertyGPSLatitudeRef, capture.latitude >= 0 ? "N" : "S")
        set(gps, kCGImagePropertyGPSLongitude, abs(capture.longitude))
        set(gps, kCGImagePropertyGPSLongitudeRef, capture.longitude >= 0 ? "E" : "W")
        if let altitude = capture.altitude {
            set(gps, kCGImagePropertyGPSAltitude, abs(altitude))
            set(gps, kCGImagePropertyGPSAltitudeRef, altitude >= 0 ? 0 : 1)
        }
        if let accuracy = capture.horizontalAccuracy {
            set(gps, kCGImagePropertyGPSHPositioningError, accuracy)
        }
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy:MM:dd"
        set(gps, kCGImagePropertyGPSDateStamp, utc.string(from: capture.takenAt))
        utc.dateFormat = "HH:mm:ss"
        set(gps, kCGImagePropertyGPSTimeStamp, utc.string(from: capture.takenAt))
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy:MM:dd HH:mm:ss"
        set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, local.string(from: capture.takenAt))
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            return data
        }
        return output as Data
    }

    /// Where a video was recorded (a video picked from the library), from its
    /// ISO 6709 location metadata, when it has one.
    public static func location(inVideo url: URL) async -> CaptureLocation? {
        let asset = AVURLAsset(url: url)
        var items: [AVMetadataItem] = []
        if let common = try? await asset.load(.metadata) { items += common }
        for format in (try? await asset.load(.availableMetadataFormats)) ?? [] {
            items += (try? await asset.loadMetadata(for: format)) ?? []
        }
        var takenAt = Date()
        for item in items where item.identifier == .quickTimeMetadataCreationDate || item.commonKey == .commonKeyCreationDate {
            if let text = try? await item.load(.stringValue), let date = ISO8601DateFormatter().date(from: text) {
                takenAt = date
                break
            }
        }
        for item in items where item.identifier == .quickTimeMetadataLocationISO6709
            || item.identifier == .quickTimeUserDataLocationISO6709
            || item.commonKey == .commonKeyLocation {
            if let text = try? await item.load(.stringValue), var capture = parseISO6709(text) {
                capture.takenAt = takenAt
                return capture
            }
        }
        return nil
    }

    /// "+37.7749-122.4194+010.000/" → a capture location.
    static func parseISO6709(_ text: String) -> CaptureLocation? {
        // A coordinate reference ("CRSWGS_84") may follow; only the numbers before it count.
        let text = text.components(separatedBy: "CRS").first ?? text
        var numbers: [Double] = []
        var current = ""
        for character in text {
            if character == "+" || character == "-" || character == "/" {
                if let value = Double(current) { numbers.append(value) }
                current = character == "/" ? "" : String(character)
            } else if character.isNumber || character == "." {
                current.append(character)
            }
        }
        if let value = Double(current) { numbers.append(value) }
        guard numbers.count >= 2, (-90...90).contains(numbers[0]), (-180...180).contains(numbers[1]) else { return nil }
        return CaptureLocation(latitude: numbers[0], longitude: numbers[1], altitude: numbers.count > 2 ? numbers[2] : nil)
    }

    /// The GPS position in an image's metadata (a photo picked from the
    /// library), when it has one.
    public static func location(inImage data: Data) -> CaptureLocation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let north = (gps[kCGImagePropertyGPSLatitudeRef] as? String) != "S"
        let east = (gps[kCGImagePropertyGPSLongitudeRef] as? String) != "W"
        var takenAt = Date()
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            takenAt = formatter.date(from: original) ?? takenAt
        }
        return CaptureLocation(
            latitude: north ? latitude : -latitude,
            longitude: east ? longitude : -longitude,
            altitude: gps[kCGImagePropertyGPSAltitude] as? Double,
            takenAt: takenAt
        )
    }
}
