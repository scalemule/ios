import Foundation
import ScaleMuleCore

/// Upload photos and fetch sized copies (ScaleMule Photos, `/v1/photos`).
///
/// Every upload is checked for illegal and unsafe content before anyone can
/// see it: until the check passes, `image(...)` fails with
/// `PhotosService.scanPendingCode`, and a photo that fails it is never served.
/// Photos are stripped of capture metadata (GPS, camera serial) on upload.
public final class PhotosService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient

    /// Server code while a new photo is still being checked.
    public static let scanPendingCode = "SCAN_PENDING"

    public required init(client: HTTPClient) {
        self.client = client
    }

    public convenience init(app: ScaleMuleApp) {
        self.init(client: app.client)
    }

    /// Upload one image as the signed-in person. Not retried automatically,
    /// because every upload creates a new photo.
    public func upload(
        _ data: Data,
        filename: String,
        mimeType: String = "image/jpeg"
    ) async -> ApiResponse<PhotoInfo> {
        var form = MultipartFormData()
        form.addFile(name: "file", filename: filename, mimeType: mimeType, data: data)

        return await client.request(RequestOptions(
            method: .post,
            path: "/v1/photos/upload",
            credential: .accessToken,
            rawBody: form.encoded(),
            contentType: form.contentType,
            retryable: false
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
