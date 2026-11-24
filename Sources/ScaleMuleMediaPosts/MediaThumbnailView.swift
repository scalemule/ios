#if canImport(UIKit)
import SwiftUI
import UIKit
import ScaleMulePhotos
import ScaleMuleVideos

/// A post as a small tile for a grid (a person's posts): the photo, or the
/// video's poster with a play mark, filling the tile. Give it its size with
/// `.aspectRatio` or `.frame`; it clips to that.
public struct MediaThumbnailView: View {
    public let post: MediaPost
    private let photos: PhotosService
    private let videos: VideosService
    private let maxSide: CGFloat
    private let loader: ((MediaPost) async -> UIImage?)?

    @State private var image: UIImage?

    /// - Parameters:
    ///   - maxSide: the longer side of the picture kept in memory, in pixels.
    ///   - loader: load the picture yourself (previews, UI tests).
    public init(post: MediaPost, photos: PhotosService, videos: VideosService, maxSide: CGFloat = 480, loader: ((MediaPost) async -> UIImage?)? = nil) {
        self.post = post
        self.photos = photos
        self.videos = videos
        self.maxSide = maxSide
        self.loader = loader
    }

    public var body: some View {
        Color(white: 0.14)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if post.isVideo {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .task(id: post.id) {
                guard image == nil else { return }
                image = await load()
            }
            .accessibilityLabel(post.isVideo ? "Video" : "Photo")
    }

    private func load() async -> UIImage? {
        if let loader { return await loader(post) }
        if post.isVideo { return await videos.thumbnail(id: post.mediaId, maxSide: maxSide) }
        guard case .success(let picture) = await photos.loadImage(id: post.mediaId, width: Int(maxSide), cache: .shared) else { return nil }
        return await picture.byPreparingThumbnail(ofSize: Self.fit(picture, maxSide: maxSide)) ?? picture
    }

    private static func fit(_ image: UIImage, maxSide: CGFloat) -> CGSize {
        let width = image.size.width * image.scale, height = image.size.height * image.scale
        let longest = max(width, height)
        guard longest > maxSide, longest > 0 else { return CGSize(width: width, height: height) }
        return CGSize(width: width * maxSide / longest, height: height * maxSide / longest)
    }
}
#endif
