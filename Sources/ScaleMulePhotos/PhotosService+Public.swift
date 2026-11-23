import Foundation
import ScaleMuleCore
import ScaleMuleStorage

/// A size of a public photo, served unsigned from ScaleMule's public CDN.
public struct PublicRendition: Sendable, Equatable, Decodable {
    public let photoId: String
    /// False until the size has been made; `url` is nil until then.
    public let ready: Bool
    public let url: String?
    public let width: Int?
    public let height: Int?

    private enum CodingKeys: String, CodingKey {
        case photoId = "photo_id"
        case ready, url, width, height
    }

    public init(photoId: String, ready: Bool, url: String?, width: Int?, height: Int?) {
        self.photoId = photoId
        self.ready = ready
        self.url = url
        self.width = width
        self.height = height
    }
}

extension PhotosService {
    /// Server code when a public size was not made in time.
    public static let renditionPendingCode = "rendition_pending"

    /// The name Photos gives one size of a photo: `w256_h256_cover_q85_jpeg`.
    /// The same name is the file name of that size on the public CDN.
    public static func renditionKey(width: Int, height: Int, fit: PhotoFit, quality: Int = 85, format: PhotoFormat = .jpeg) -> String {
        "w\(width)_h\(height)_\(fit.rawValue)_q\(min(max(quality, 1), 100))_\(format.rawValue)"
    }

    /// Upload an image that anyone may see (a profile photo, a cover) and
    /// register it as a photo.
    ///
    /// The bytes are sent exactly as given with Storage visibility
    /// `anonymous_visible`, so make them small and strip what should not be
    /// public first. Photos checks the image for unsafe content, keeps any
    /// capture metadata privately and serves only a metadata-free copy, from
    /// the unsigned CDN, once the check has passed. Use `publicImageURL` for a
    /// link to a size of it.
    public func uploadPublic(
        _ data: Data,
        filename: String,
        mimeType: String = "image/jpeg",
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async -> ApiResponse<PhotoInfo> {
        let options = UploadOptions(
            filename: filename,
            contentType: mimeType,
            visibility: .anonymousVisible,
            compression: .off,
            resume: false,
            onProgress: onProgress
        )
        let stored = await storage.upload(data, options: options)
        guard case .success(let file) = stored else {
            return .failure(stored.error ?? ApiError(code: .internalError, message: "Upload failed"))
        }
        if let visibility = file.visibility, visibility != .anonymousVisible {
            return .failure(ApiError(
                code: .internalError,
                message: "Storage returned visibility \(visibility.rawValue) for a public upload.",
                rawCode: "visibility_violation"
            ))
        }
        return await register(fileId: file.id)
    }

    /// One size of a public photo, as Photos has it now
    /// (`GET /v1/photos/public/{id}/manifest?rendition=`). No session needed.
    public func publicRendition(photoId: String, key: String) async -> ApiResponse<PublicRendition> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/photos/public/\(Self.segment(photoId))/manifest",
            query: ["rendition": key],
            credential: .none
        ))
    }

    /// A stable, unsigned link to one size of a public photo
    /// (`uploadPublic`), served by the CDN with no key. The link never
    /// changes or expires, so it can be stored, for example as a profile's
    /// `avatar_url`.
    ///
    /// Photos usually makes the common sizes within seconds of the upload. If
    /// this one is not there yet it is made now (the public transform), and
    /// the link Photos records for it is returned.
    public func publicImageURL(
        photoId: String,
        width: Int,
        height: Int,
        fit: PhotoFit = .cover,
        format: PhotoFormat = .jpeg,
        quality: Int = 85
    ) async -> ApiResponse<URL> {
        let key = Self.renditionKey(width: width, height: height, fit: fit, quality: quality, format: format)
        var requestedTransform = false
        for (attempt, delay) in ([0] + publicRenditionPollDelays).enumerated() {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            switch await publicRendition(photoId: photoId, key: key) {
            case .success(let rendition):
                if rendition.ready, let url = Self.publicURL(rendition.url) { return .success(url) }
            case .failure(let error):
                // A photo that is not public, not checked yet or removed: no link.
                if error.statusCode == 404 || error.statusCode == 400 { return .failure(error) }
            }
            if !requestedTransform && attempt == 0 {
                // Ask for the size once; Photos stores it and records its link.
                requestedTransform = true
                let query = Self.transformQuery(width: width, height: height, fit: fit, format: format, quality: quality)
                let made = await client.requestData(RequestOptions(
                    method: .get,
                    path: "/v1/photos/public/\(Self.segment(photoId))/transform",
                    query: query,
                    credential: .none,
                    accept: "image/jpeg,image/webp,*/*"
                ))
                if case .failure(let error) = made, error.statusCode == 404 { return .failure(error) }
            }
        }
        return .failure(ApiError(
            code: .conflict,
            message: "Your photo is still being prepared. Try again in a moment.",
            statusCode: 202,
            rawCode: Self.renditionPendingCode
        ))
    }

    /// Only unsigned HTTPS links are handed out.
    static func publicURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
}
