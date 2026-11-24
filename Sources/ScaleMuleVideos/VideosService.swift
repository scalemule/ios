import Foundation
import ScaleMuleCore
@_exported import ScaleMuleStorage

/// Short videos with ScaleMule Video (`/v1/videos`).
///
/// Upload goes through the ScaleMule Storage pipeline (straight to S3,
/// multipart, retried and resumable), then `/v1/videos/register` hands the
/// file to Video, which checks it and makes adaptive streaming copies
/// (HLS, several qualities, portrait kept portrait) and a poster image.
/// Play it with `playbackURL(id:)` in AVPlayer once `status` is `ready`.
public final class VideosService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient
    public let storage: StorageService

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

    /// Upload a video file (already compressed on the phone; it is sent
    /// unchanged) and register it. The video id is the Storage file id.
    /// Calling again with the same bytes after a failure resumes the upload.
    public func upload(
        _ data: Data,
        filename: String,
        mimeType: String = "video/mp4",
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async -> ApiResponse<RegisteredVideo> {
        let stored = await storage.uploadPrivate(data, options: UploadOptions(
            filename: filename,
            contentType: mimeType,
            onProgress: onProgress
        ))
        guard case .success(let file) = stored else {
            return .failure(stored.error ?? ApiError(code: .internalError, message: "Upload failed"))
        }
        return await register(fileId: file.id)
    }

    /// Hand a file already in Storage to Video. Answers at once; the video
    /// is checked and converted in the background (see `get`).
    public func register(fileId: String) async -> ApiResponse<RegisteredVideo> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/videos/register",
            body: ["file_id": fileId],
            credential: .accessToken
        ))
    }

    /// The video's details: status (`ready` once playable), size, duration and poster.
    public func get(id: String) async -> ApiResponse<VideoInfo> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/videos/\(Self.segment(id))",
            credential: .accessToken
        ))
    }

    /// Delete the video everywhere: ScaleMule Video removes its streaming
    /// copies, poster and preview, the uploaded original in Storage, its
    /// playback statistics and CDN copies. Only the video's owner (or the
    /// app's team) may; anyone else, and a video already deleted, gets a 404
    /// (`error.statusCode == 404`). This phone's copies go too, whatever the
    /// answer: the file kept after posting, the playback link, a buffered
    /// player and the poster.
    public func delete(id: String) async -> ApiResponse<VideoDeletion> {
        let result: ApiResponse<VideoDeletion> = await client.request(RequestOptions(
            method: .delete,
            path: "/v1/videos/\(Self.segment(id))",
            credential: .accessToken
        ))
        await Self.forgetLocalCopies(of: id)
        return result
    }

    /// Drop what this phone keeps of one video.
    @MainActor
    public static func forgetLocalCopies(of id: String) {
        #if canImport(UIKit)
        VideoFileCache.remove(id)
        VideoLoopCache.shared.forget(id)
        VideoLinkCache.shared.forget(id)
        VideoPreloader.shared.forget(id)
        VideoPlaybackModel.forgetPoster(id)
        VideoCaptionStore.shared.forget(id)
        #endif
    }

    /// A link AVPlayer can play directly: the HLS master playlist with a
    /// short-lived playback token (no headers needed; every quality playlist
    /// carries it). Ask for a new one when it expires.
    public func playbackURL(id: String, validFor seconds: Int = 3600) async -> ApiResponse<URL> {
        let result: ApiResponse<PlaybackToken> = await client.request(RequestOptions(
            method: .post,
            path: "/v1/videos/\(Self.segment(id))/embed-token",
            body: ["expires_in": seconds],
            credential: .accessToken
        ))
        switch result {
        case .success(let token):
            var components = URLComponents(
                url: client.configuration.baseURL.appendingPathComponent("v1/videos/\(Self.segment(id))/playlist.m3u8"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "token", value: token.token)]
            guard let url = components?.url else {
                return .failure(ApiError(code: .internalError, message: "Could not build the playback link"))
            }
            return .success(url)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Record a playback event for ScaleMule Video analytics
    /// (`POST /v1/videos/{id}/track`). `VideoPlaybackModel` sends these by
    /// itself; call it directly only for a custom player.
    public func track(id: String, event: PlaybackEvent) async -> ApiResponse<EmptyResponse> {
        var body: [String: Any] = [
            "session_id": event.sessionId,
            "event_type": event.type.rawValue,
        ]
        if let position = event.positionSeconds, position.isFinite { body["timestamp_seconds"] = max(0, position) }
        if let quality = event.quality { body["quality"] = quality }
        if !event.metadata.isEmpty { body["metadata"] = event.metadata.mapValues(\.value) }
        return await client.requestVoid(RequestOptions(
            method: .post,
            path: "/v1/videos/\(Self.segment(id))/track",
            body: body,
            credential: .accessToken,
            retryable: false
        ))
    }

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? value
    }
}

/// What `/register` answers.
public struct RegisteredVideo: Sendable, Decodable, Equatable {
    public let videoId: String
    /// `registering` (checked, converting) or `pending_scan` (still being checked).
    public let status: String

    private enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case status
    }
}

/// What `DELETE /v1/videos/{id}` answers.
public struct VideoDeletion: Sendable, Decodable, Equatable {
    public let videoId: String
    public let deleted: Bool
    /// Objects removed from the video bucket (streaming copies, poster, preview).
    public let objectsDeleted: Int?
    /// `deleted`, `not_in_storage` or `kept_other_uploader`.
    public let storageOriginal: String?
    /// `requested` or `not_configured`.
    public let cdnInvalidation: String?
    /// The video was still being converted; Video finishes the cleanup within minutes.
    public let processingCancelled: Bool?

    private enum CodingKeys: String, CodingKey {
        case deleted
        case videoId = "video_id"
        case objectsDeleted = "objects_deleted"
        case storageOriginal = "storage_original"
        case cdnInvalidation = "cdn_invalidation"
        case processingCancelled = "processing_cancelled"
    }
}

/// A video in ScaleMule Video.
public struct VideoInfo: Sendable, Decodable, Equatable, Identifiable {
    public let id: String
    /// `uploading`, `processing`, `ready` or `failed`.
    public let status: String
    public let durationSeconds: Double?
    public let width: Int?
    public let height: Int?
    /// Poster image (signed link), once made.
    public let thumbnailUrl: String?

    public var isReady: Bool { status == "ready" }

    private enum CodingKeys: String, CodingKey {
        case id, status, width, height
        case durationSeconds = "duration_seconds"
        case thumbnailUrl = "thumbnail_url"
    }
}

struct PlaybackToken: Decodable, Sendable {
    let token: String
    let expiresAt: Int?

    private enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}
