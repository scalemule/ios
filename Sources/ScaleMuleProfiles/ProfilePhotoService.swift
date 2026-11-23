import Foundation
import ScaleMuleCore
import ScaleMuleAuth
import ScaleMulePhotos
import ScaleMuleStorage
#if canImport(UIKit)
import UIKit
#endif

/// Add, change or remove the signed-in person's profile photo.
///
/// The picture goes through ScaleMule Photos like any other: it is checked for
/// unsafe content, and only a metadata-free copy is served. It is stored as a
/// public photo, so the profile's `avatar_url` is a stable, unsigned link on
/// the public CDN (256 px square) that any app, page or person can show
/// without a key and that never expires.
public final class ProfilePhotoService: @unchecked Sendable {
    /// Side of the square profile picture the link points at.
    public static let avatarSize = 256

    public let auth: AuthService
    public let photos: PhotosService
    let app: ScaleMuleApp?

    public convenience init(app: ScaleMuleApp) {
        self.init(auth: AuthService(app: app), photos: PhotosService(app: app), app: app)
    }

    /// `app` lets the service find (and delete) the previous profile photo
    /// after a change; without it the previous photo is kept.
    public init(auth: AuthService, photos: PhotosService, app: ScaleMuleApp? = nil) {
        self.auth = auth
        self.photos = photos
        self.app = app
    }

    #if canImport(UIKit)
    /// Make `image` the signed-in person's profile photo. See `setProfilePhoto(_ data:)`.
    public func setProfilePhoto(
        _ image: UIImage,
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async -> ApiResponse<AuthUser> {
        let prepared: Data? = await Task.detached(priority: .userInitiated) {
            // jpegData keeps the orientation tag; prepare applies it.
            guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }
            return ProfilePhotoImage.prepare(data)
        }.value
        return await setPrepared(prepared, onProgress: onProgress)
    }
    #endif

    /// Make an encoded image (JPEG, HEIC, PNG...) the signed-in person's
    /// profile photo, and return the updated user.
    ///
    /// Steps: made upright, at most 1024 px, with no metadata; uploaded as a
    /// public photo and registered (waits for the safety check); the 256 px
    /// square link taken; the profile's `avatar_url` set to it, which also
    /// updates the auth state. The previous profile photo made here is then
    /// deleted.
    public func setProfilePhoto(
        _ data: Data,
        onProgress: (@Sendable (UploadProgress) -> Void)? = nil
    ) async -> ApiResponse<AuthUser> {
        let prepared = await Task.detached(priority: .userInitiated) {
            ProfilePhotoImage.prepare(data)
        }.value
        return await setPrepared(prepared, onProgress: onProgress)
    }

    /// Remove the profile photo: `avatar_url` becomes empty (Auth keeps no
    /// null for it), and the photo made here is deleted.
    public func removeProfilePhoto() async -> ApiResponse<AuthUser> {
        let previous = await currentAvatarURL()
        let result = await auth.updateProfile(avatarUrl: "")
        if case .success = result { await deletePhoto(behind: previous) }
        return result
    }

    // MARK: - Steps

    private func setPrepared(_ prepared: Data?, onProgress: (@Sendable (UploadProgress) -> Void)?) async -> ApiResponse<AuthUser> {
        guard let prepared else {
            return .failure(ApiError(
                code: .validationError,
                message: "This picture could not be read. Choose another one.",
                statusCode: 400,
                rawCode: "unreadable_image"
            ))
        }
        let previous = await currentAvatarURL()

        let uploaded = await photos.uploadPublic(prepared, filename: "profile.jpg", mimeType: "image/jpeg", onProgress: onProgress)
        guard case .success(let photo) = uploaded else {
            return .failure(uploaded.error ?? ApiError(code: .internalError, message: "Upload failed"))
        }
        let link = await photos.publicImageURL(
            photoId: photo.id,
            width: Self.avatarSize,
            height: Self.avatarSize,
            fit: .cover,
            format: .jpeg,
            quality: 85
        )
        guard case .success(let url) = link else {
            return .failure(link.error ?? ApiError(code: .internalError, message: "No link for the photo"))
        }
        let updated = await auth.updateProfile(avatarUrl: url.absoluteString)
        switch updated {
        case .success:
            if previous != url { await deletePhoto(behind: previous) }
        case .failure:
            // The profile still points at the old photo: drop the new one.
            _ = await photos.delete(id: photo.id)
        }
        return updated
    }

    private func currentAvatarURL() async -> URL? {
        guard let app else { return nil }
        if case .authenticated(let user) = await app.authState.state { return user.avatarURL }
        return await app.sessionManager.rememberedUser()?.avatarURL
    }

    /// Best effort: only a photo this service made (a Photos public link).
    private func deletePhoto(behind url: URL?) async {
        guard let id = Self.photoId(fromAvatarURL: url) else { return }
        _ = await photos.delete(id: id)
    }

    /// The Photos id in a public Photos link
    /// (`https://<cdn>/{app}/anonymous/photos/{photo_id}/{size}.{ext}`), or nil.
    public static func photoId(fromAvatarURL url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 5,
              parts[parts.count - 4] == "anonymous",
              parts[parts.count - 3] == "photos",
              UUID(uuidString: parts[parts.count - 2]) != nil else { return nil }
        return parts[parts.count - 2]
    }
}

extension AuthUser {
    /// The profile photo link, when there is one. Auth stores an empty string
    /// for a removed photo; only HTTPS links are returned.
    public var avatarURL: URL? { ProfileURL.avatar(avatarUrl) }
}

enum ProfileURL {
    static func avatar(_ value: String?) -> URL? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
}
