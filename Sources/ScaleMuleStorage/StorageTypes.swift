import Foundation
import ScaleMuleCore

/// Who can see a stored file.
public enum StorageVisibility: String, Sendable, Codable {
    /// Signed links only; the owner and the app's team.
    case `private`
    /// Any signed-in user of the app.
    case appPublic = "app_public"
    /// Anyone, on the public CDN, once the file has passed its scan.
    case anonymousVisible = "anonymous_visible"
}

/// A file stored in ScaleMule Storage.
public struct StoredFile: Sendable, Equatable {
    public let id: String
    public let filename: String
    public let contentType: String
    public let sizeBytes: Int64
    /// Short-lived signed link to the bytes, when the server returns one.
    public let url: String?
    public let visibility: StorageVisibility?
    /// Unsigned CDN link; only for `anonymousVisible` files that passed their scan.
    public let cdnUrl: String?

    public init(id: String, filename: String, contentType: String, sizeBytes: Int64, url: String?, visibility: StorageVisibility?, cdnUrl: String?) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.url = url
        self.visibility = visibility
        self.cdnUrl = cdnUrl
    }
}

/// How far an upload has got.
public struct UploadProgress: Sendable, Equatable {
    public let bytesSent: Int64
    public let totalBytes: Int64

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(bytesSent) / Double(totalBytes)) : 0
    }

    public init(bytesSent: Int64, totalBytes: Int64) {
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
    }
}

/// Whether an image is made smaller on the phone before it is sent.
public enum UploadCompression: Sendable, Equatable {
    /// Size and quality chosen from the connection, like the web SDK:
    /// from 1280 px at 0.6 on a very slow network to 3840 px at 0.85 on a
    /// fast one. Capture metadata is kept (the platform strips the copy it
    /// serves and keeps the original privately).
    case adaptive
    /// Send the bytes exactly as given (originals, documents).
    case off
    /// A fixed profile.
    case custom(ImageCompressionProfile)
}

/// Upload behaviour. The defaults match the ScaleMule web SDK.
public struct UploadOptions: Sendable {
    /// Display filename (the server sanitizes it).
    public var filename: String
    /// MIME type of the bytes, for example `image/jpeg`.
    public var contentType: String
    /// Defaults to `.private`, the safest choice; Photos serves registered
    /// photos to the app's signed-in users either way.
    public var visibility: StorageVisibility
    public var metadata: [String: AnyCodable]?
    public var compression: UploadCompression
    /// Use the multipart path even for a small file.
    public var forceMultipart: Bool
    /// Keep a record on the device so the same bytes uploaded again (after a
    /// lost connection, or after the app was closed) continue where they
    /// stopped instead of starting over. Server sessions last 24 hours.
    public var resume: Bool
    /// Part size override in bytes (the server clamps it to 5–100 MB).
    public var chunkSize: Int?
    /// Parts uploaded at the same time; chosen from the network if nil.
    public var maxConcurrency: Int?
    /// Report upload events to ScaleMule analytics and logs.
    public var telemetry: Bool
    public var onProgress: (@Sendable (UploadProgress) -> Void)?

    public init(
        filename: String,
        contentType: String,
        visibility: StorageVisibility = .private,
        metadata: [String: AnyCodable]? = nil,
        compression: UploadCompression = .adaptive,
        forceMultipart: Bool = false,
        resume: Bool = true,
        chunkSize: Int? = nil,
        maxConcurrency: Int? = nil,
        telemetry: Bool = true,
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) {
        self.filename = filename
        self.contentType = contentType
        self.visibility = visibility
        self.metadata = metadata
        self.compression = compression
        self.forceMultipart = forceMultipart
        self.resume = resume
        self.chunkSize = chunkSize
        self.maxConcurrency = maxConcurrency
        self.telemetry = telemetry
        self.onProgress = onProgress
    }
}

// MARK: - Wire types (Storage /v1/storage/signed-url/*)

struct PresignedUploadResponse: Decodable, Sendable {
    let fileId: String
    let uploadUrl: String
    let completionToken: String

    private enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case uploadUrl = "upload_url"
        case completionToken = "completion_token"
    }
}

/// `/signed-url/complete` and `/signed-url/multipart/complete`.
struct UploadCompleteResponse: Decodable, Sendable {
    let fileId: String
    let filename: String
    let sizeBytes: Int64
    let contentType: String
    let url: String?
    let visibility: String?
    let cdnUrl: String?

    private enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case filename
        case sizeBytes = "size_bytes"
        case contentType = "content_type"
        case url
        case visibility
        case cdnUrl = "cdn_url"
    }

    var storedFile: StoredFile {
        StoredFile(
            id: fileId,
            filename: filename,
            contentType: contentType,
            sizeBytes: sizeBytes,
            url: url,
            visibility: visibility.flatMap(StorageVisibility.init(rawValue:)),
            cdnUrl: cdnUrl
        )
    }
}

struct MultipartStartResponse: Decodable, Sendable {
    let uploadSessionId: String
    let fileId: String
    let completionToken: String
    let partSizeBytes: Int
    let totalParts: Int
    let partUrls: [PartURL]

    private enum CodingKeys: String, CodingKey {
        case uploadSessionId = "upload_session_id"
        case fileId = "file_id"
        case completionToken = "completion_token"
        case partSizeBytes = "part_size_bytes"
        case totalParts = "total_parts"
        case partUrls = "part_urls"
    }
}

struct PartURL: Decodable, Sendable {
    let partNumber: Int
    let url: String

    private enum CodingKeys: String, CodingKey {
        case partNumber = "part_number"
        case url
    }
}

struct MultipartPartUrlsResponse: Decodable, Sendable {
    let partUrls: [PartURL]

    private enum CodingKeys: String, CodingKey {
        case partUrls = "part_urls"
    }
}
