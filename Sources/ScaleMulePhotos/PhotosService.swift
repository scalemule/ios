import Foundation
import ScaleMuleCore
@_exported import ScaleMuleStorage

/// Upload photos and fetch sized copies (ScaleMule Photos, `/v1/photos`).
///
/// Uploads use the ScaleMule Storage pipeline (the same one as the web SDK):
/// sized to the connection, sent straight to S3 in parts that are retried
/// and resumed, then registered with Photos, which makes every size from it.
///
/// Every upload is checked for illegal and unsafe content before anyone can
/// see it: until the check passes, `image(...)` fails with
/// `PhotosService.scanPendingCode`, and a photo that fails it is never served.
/// Photos are stripped of capture metadata (GPS, camera serial) before they
/// are served; the platform keeps the original privately.
public final class PhotosService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient
    /// The upload pipeline Photos uses.
    public let storage: StorageService

    /// Server code while a new photo is still being checked.
    public static let scanPendingCode = "SCAN_PENDING"
    /// `register` gave up waiting for the safety check; the photo is
    /// registered by the server when the check finishes.
    public static let scanTimeoutCode = "scan_timeout"

    public required convenience init(client: HTTPClient) {
        self.init(client: client, storage: StorageService(client: client))
    }

    public convenience init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    init(client: HTTPClient, storage: StorageService) {
        self.client = client
        self.storage = storage
    }

    /// What is sent for a new photo.
    public enum UploadQuality: Sendable, Equatable {
        /// Sized to the connection (the web SDK's profiles): about 3840 px
        /// on a fast network, down to 1280 px on a very slow one.
        case adaptive
        /// The full-resolution photo, unchanged (HEIC becomes a full-size
        /// JPEG, which Storage can clean).
        case original
    }

    /// Upload one image as the signed-in person and register it as a photo.
    ///
    /// Not a single request: the bytes go to S3 through Storage (every PUT
    /// retried; a multipart upload, as for a `.original` photo, continues
    /// where it stopped when called again with the same bytes), then Photos
    /// registers the file once its safety scan has passed (waiting up to
    /// about 17 s, like the web SDK).
    public func upload(
        _ data: Data,
        filename: String,
        mimeType: String = "image/jpeg",
        quality: UploadQuality = .adaptive,
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async -> ApiResponse<PhotoInfo> {
        var payload = data
        var name = filename
        var type = mimeType
        if quality == .original {
            let deliverable = await Task.detached(priority: .userInitiated) {
                ImageCompression.deliverableOriginal(data, contentType: mimeType, filename: filename)
            }.value
            payload = deliverable.data
            name = deliverable.filename
            type = deliverable.contentType
        }
        let options = UploadOptions(
            filename: name,
            contentType: type,
            visibility: .private,
            compression: quality == .original ? .off : .adaptive,
            onProgress: onProgress
        )
        let stored = await storage.upload(payload, options: options)
        guard case .success(let file) = stored else {
            return .failure(stored.error ?? ApiError(code: .internalError, message: "Upload failed"))
        }
        return await register(fileId: file.id)
    }

    /// Make a photo from a file already in Storage. The server waits about
    /// 5 s for the file's safety scan; this asks again twice, a second apart.
    public func register(fileId: String) async -> ApiResponse<PhotoInfo> {
        let options = RequestOptions(
            method: .post,
            path: "/v1/photos/register",
            body: ["file_id": fileId],
            credential: .accessToken
        )
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            let result: ApiResponse<RegisterResult> = await client.request(options)
            switch result {
            case .success(let outcome):
                if let photo = outcome.photo { return .success(photo) }
                // pending_scan: ask again.
            case .failure(let error):
                return .failure(error)
            }
        }
        return .failure(ApiError(
            code: .unknown,
            message: "This photo is still being checked. It will appear when the check finishes.",
            statusCode: 202,
            rawCode: Self.scanTimeoutCode
        ))
    }

    /// The image bytes, resized on the server. Results are cached by the
    /// server and CDN, so asking for the same size again is cheap.
    public func image(
        id: String,
        width: Int? = nil,
        height: Int? = nil,
        fit: PhotoFit = .contain,
        format: PhotoFormat? = nil,
        quality: Int? = nil
    ) async -> ApiResponse<Data> {
        await client.requestData(RequestOptions(
            method: .get,
            path: "/v1/photos/\(Self.segment(id))/transform",
            query: Self.transformQuery(width: width, height: height, fit: fit, format: format, quality: quality),
            credential: .accessToken,
            accept: "image/avif,image/webp,image/jpeg,*/*"
        ))
    }

    public func get(id: String) async -> ApiResponse<PhotoInfo> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/photos/\(Self.segment(id))",
            credential: .accessToken
        ))
    }

    /// Delete one of your own photos.
    public func delete(id: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/photos/\(Self.segment(id))",
            credential: .accessToken
        ))
    }

    // MARK: - Helpers

    static func transformQuery(width: Int?, height: Int?, fit: PhotoFit, format: PhotoFormat?, quality: Int?) -> [String: String] {
        var query: [String: String] = ["fit": fit.rawValue]
        if let width, width > 0 { query["width"] = String(width) }
        if let height, height > 0 { query["height"] = String(height) }
        if let format { query["format"] = format.rawValue }
        if let quality { query["quality"] = String(min(max(quality, 1), 100)) }
        return query
    }

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? value
    }
}

/// `/register` answers with the photo, or `{"status": "pending_scan"}` while
/// the safety scan is still running.
struct RegisterResult: Decodable, Sendable {
    let photo: PhotoInfo?

    private enum CodingKeys: String, CodingKey { case status }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(String.self, forKey: .status) == "pending_scan" {
            photo = nil
        } else {
            photo = try PhotoInfo(from: decoder)
        }
    }
}
