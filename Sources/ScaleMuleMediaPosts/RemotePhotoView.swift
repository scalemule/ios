#if canImport(UIKit)
import SwiftUI
import UIKit
import ScaleMulePhotos

/// A ScaleMule Photos picture at a fixed size, for feeds. It starts from the
/// memory cache (a preloaded photo shows in the first frame, no spinner),
/// else loads through `PhotosService.loadImage` (disk cache, waits out the
/// safety check of a new photo and brief outages). While it loads it shows a
/// spinner, "Checking photo…" while ScaleMule checks a new photo, and
/// "Tap to try again" when it fails.
///
/// Colours are neutral (white on the photo's dark background); wide photos
/// are cropped to fill, or, with `wideStyle: .pan`, fill the height and
/// scroll sideways (iOS 18).
public struct RemotePhotoView: View {
    /// How a photo at least as wide as it is tall fills the frame.
    public enum WideStyle: Equatable, Sendable {
        /// Cropped at the sides to fill the frame.
        case crop
        /// Fills the frame's height and scrolls sideways, starting in the
        /// middle; a bar shows the part on screen and the first wide photo
        /// after launch glides once with `hint` (iOS 18; earlier, `.crop`).
        /// `indicatorBottom` is the bar's distance from the bottom edge.
        case pan(hint: String?, indicatorBottom: CGFloat = 88)
    }

    /// Replaces the network load (previews, UI tests): returns the picture,
    /// or nil when it failed; call `checking` to show "Checking photo…".
    public typealias Loader = @MainActor (_ photoId: String, _ width: Int, _ checking: @escaping @MainActor () -> Void) async -> UIImage?

    /// Text shown while loading or after a failure.
    public struct Labels: Sendable {
        public var checking: String
        public var failed: String

        public init(checking: String = "Checking photo…", failed: String = "Photo didn't load. Tap to try again") {
            self.checking = checking
            self.failed = failed
        }
    }

    public let photoId: String
    public let size: CGSize
    public let wide: Bool
    private let photos: PhotosService
    private let cache: PhotoImageCache
    private let wideStyle: WideStyle
    private let labels: Labels
    private let loader: Loader?
    private let onTap: (UIImage) -> Void

    @State private var image: UIImage?
    @State private var state: LoadState = .loading
    /// Bumped by "Tap to try again" to restart loading.
    @State private var attempt = 0

    /// - Parameters:
    ///   - wide: the post is landscape (from its size): it is fetched at
    ///     `requestWidth(wide:)` = 1600 instead of 1080.
    ///   - onTap: a tap on the loaded picture (for example, open it whole).
    public init(
        photoId: String,
        size: CGSize,
        wide: Bool = false,
        photos: PhotosService,
        cache: PhotoImageCache = .shared,
        wideStyle: WideStyle = .crop,
        labels: Labels = Labels(),
        loader: Loader? = nil,
        onTap: @escaping (UIImage) -> Void = { _ in }
    ) {
        self.photoId = photoId
        self.size = size
        self.wide = wide
        self.photos = photos
        self.cache = cache
        self.wideStyle = wideStyle
        self.labels = labels
        self.loader = loader
        self.onTap = onTap
        // Preloaded (or seen before): shown in the first frame, no spinner.
        let cached = cache.image(for: PhotoImageCache.key(for: photoId))
        _image = State(initialValue: cached.flatMap { Self.bigEnough($0, for: Self.requestWidth(wide: wide)) ? $0 : nil })
    }

    /// The longest side each photo is fetched (and should be preloaded) at:
    /// 1080 for upright photos, 1600 for wide ones, which are shown at the
    /// screen's full height.
    public static func requestWidth(wide: Bool) -> Int { wide ? 1600 : 1080 }

    /// Whether a picture is at least as wide as it is tall (more than 0.95 : 1):
    /// what `WideStyle.pan` scrolls sideways.
    public static func isWide(_ image: UIImage) -> Bool {
        image.size.height > 0 && image.size.width / image.size.height > 0.95
    }

    static func bigEnough(_ image: UIImage, for width: Int) -> Bool {
        max(image.size.width * image.scale, image.size.height * image.scale) >= CGFloat(width) * 0.9
    }

    private enum LoadState: Equatable {
        case loading
        case checking
        case failed
    }

    private var requestWidth: Int { Self.requestWidth(wide: wide) }

    public var body: some View {
        ZStack {
            if let image {
                loaded(image)
            } else {
                switch state {
                case .loading:
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                case .checking:
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text(labels.checking)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                case .failed:
                    Button {
                        attempt += 1
                    } label: {
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 32))
                                .foregroundColor(.white.opacity(0.6))
                            Text(labels.failed)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                        }
                        .padding(24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("retryPhoto")
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: LoadKey(photoId: photoId, attempt: attempt)) { await load() }
    }

    @ViewBuilder
    private func loaded(_ image: UIImage) -> some View {
        if case .pan(let hint, let indicatorBottom) = wideStyle, Self.isWide(image), #available(iOS 18.0, *) {
            PannedPhoto(image: image, size: size, hint: hint, indicatorBottom: indicatorBottom) { onTap(image) }
        } else {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { onTap(image) }
        }
    }

    private struct LoadKey: Hashable {
        let photoId: String
        let attempt: Int
    }

    private func load() async {
        if let loader {
            let loaded = await loader(photoId, requestWidth) { state = .checking }
            if let loaded {
                image = loaded
            } else if !Task.isCancelled {
                state = .failed
            }
            return
        }
        if let image, Self.bigEnough(image, for: requestWidth) { return }
        state = .loading
        // JPEG on purpose: left to choose, the server picks AVIF, which it
        // encodes so slowly that a new photo took 31 s to appear.
        switch await photos.loadImage(id: photoId, width: requestWidth, format: .jpeg, cache: cache, onState: { _ in
            state = .checking
        }) {
        case .success(let loaded):
            image = loaded
        case .failure:
            if !Task.isCancelled { state = .failed }
        }
    }
}

/// A wide photo filling the frame's height, in the system's sideways
/// scroller (smooth, keeps gliding after a flick, and a vertical feed still
/// scrolls). It starts in the middle; a bar near the bottom shows the part
/// on screen, and the first wide photo after launch glides once with a hint.
@available(iOS 18.0, *)
private struct PannedPhoto: View {
    let image: UIImage
    let size: CGSize
    let hint: String?
    let indicatorBottom: CGFloat
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(idType: Never.self)
    @State private var scrolledX: CGFloat = 0
    @State private var showHint = false
    @MainActor private static var hintShown = false

    private var scaledWidth: CGFloat {
        size.height * image.size.width / max(image.size.height, 1)
    }

    /// How far the picture can scroll.
    private var travel: CGFloat { max(0, scaledWidth - size.width) }

    var body: some View {
        ZStack {
            ScrollView(.horizontal, showsIndicators: false) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: scaledWidth, height: size.height)
                    // Inside the scroller: a tap outside it never arrives.
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.center)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                scrolledX = x
            }
            .frame(width: size.width, height: size.height)

            if travel > 0 {
                positionBar
                    .position(x: size.width / 2, y: size.height - indicatorBottom)
            }

            if showHint, let hint {
                Label(hint, systemImage: "hand.draw")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        // A feed builds the next post early; glide only on the one on screen.
        .onScrollVisibilityChange(threshold: 0.9) { visible in
            if visible { Task { await glideOnce() } }
        }
    }

    private var positionBar: some View {
        let track: CGFloat = 56
        let thumb = max(10, track * size.width / scaledWidth)
        let progress = travel > 0 ? min(1, max(0, scrolledX / travel)) : 0.5
        return Capsule()
            .fill(Color.white.opacity(0.3))
            .frame(width: track, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.white)
                    .frame(width: thumb, height: 4)
                    .offset(x: (track - thumb) * progress)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func glideOnce() async {
        guard travel > 0, !Self.hintShown else { return }
        Self.hintShown = true
        withAnimation { showHint = true }
        if !reduceMotion {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeInOut(duration: 0.7)) { position.scrollTo(x: travel * 0.8) }
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(.easeInOut(duration: 0.7)) { position.scrollTo(x: travel / 2) }
        }
        try? await Task.sleep(for: .seconds(2))
        withAnimation { showHint = false }
    }
}
#endif
