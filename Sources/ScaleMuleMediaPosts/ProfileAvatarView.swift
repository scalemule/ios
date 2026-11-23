#if canImport(UIKit)
import SwiftUI
import UIKit
import ScaleMulePhotos

/// A person's round profile photo (`AuthUser.avatarURL`,
/// `PublicProfile.avatarURL`). The first letter of `name` on `background`
/// shows while it loads, when there is none, and when it cannot be loaded.
/// Pictures are kept in memory and on disk (`ProfileAvatarView.cache`).
public struct ProfileAvatarView: View {
    /// The profile photo link (ScaleMule's public CDN), if the person has one.
    public let url: URL?
    /// Its first letter is shown when there is no photo.
    public let name: String
    public let size: CGFloat
    private let background: Color
    private let foreground: Color
    private let font: Font?
    private let cache: PhotoImageCache

    @State private var image: UIImage?

    /// - Parameters:
    ///   - background: the circle behind the initial (the app's accent).
    ///   - foreground: the initial's colour.
    ///   - font: the initial's font; default bold system at 42% of `size`.
    public init(
        url: URL?,
        name: String,
        size: CGFloat = 40,
        background: Color = Color(white: 0.85),
        foreground: Color = Color(white: 0.25),
        font: Font? = nil,
        cache: PhotoImageCache? = nil
    ) {
        self.url = url
        self.name = name
        self.size = size
        self.background = background
        self.foreground = foreground
        self.font = font
        self.cache = cache ?? Self.cache
    }

    /// Profile photos in memory (16 MB) and on disk (300 files).
    @MainActor public static let cache = PhotoImageCache(folderName: "scalemule-avatars", memoryBytes: 16 * 1024 * 1024, filesKept: 300)

    /// One picture per link: a new profile photo is a new link.
    public static func cacheKey(for url: URL) -> String {
        url.pathComponents.suffix(2).joined(separator: "-")
    }

    /// The letter shown without a photo.
    public static func initial(of name: String) -> String {
        String(name.prefix(1)).uppercased()
    }

    public var body: some View {
        ZStack {
            Circle().fill(background)
            Text(Self.initial(of: name))
                .font(font ?? .system(size: size * 0.42, weight: .bold))
                .foregroundColor(foreground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        let key = Self.cacheKey(for: url)
        if let cached = cache.image(for: key) {
            image = cached
            return
        }
        image = nil
        if let saved = await cache.saved(for: key) {
            image = saved
            return
        }
        // Public, unsigned and never changing: a plain download, no key sent.
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let loaded = UIImage(data: data)?.preparingForDisplay(),
              !Task.isCancelled else { return }
        cache.store(loaded, data: data, for: key)
        image = loaded
    }
}
#endif
