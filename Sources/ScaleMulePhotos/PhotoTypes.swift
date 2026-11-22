import Foundation
import ScaleMuleCore

/// A photo stored in ScaleMule Photos.
public struct PhotoInfo: Sendable, Decodable, Identifiable, Equatable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let fileSize: Int
    public let width: Int
    public let height: Int
    /// ISO 8601 timestamp.
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id, filename, width, height
        case mimeType = "mime_type"
        case fileSize = "file_size"
        case createdAt = "created_at"
    }
}

/// How a sized image fills the requested box.
public enum PhotoFit: String, Sendable {
    /// Fill the box, cropping around the photo's focal point.
    case cover
    /// Fit inside the box, keeping the whole photo.
    case contain
    case fill
    /// Like `contain`, but never enlarges.
    case scaledown
}

public enum PhotoFormat: String, Sendable {
    case jpeg, png, webp, avif
}
