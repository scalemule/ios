#if canImport(UIKit)
import AVFoundation
import SwiftUI
import UIKit
import ScaleMulePhotos
import ScaleMuleVideos

/// A short ScaleMule Video in a feed, TikTok style: the poster first, then
/// it plays (looping) while `isActive` and pauses otherwise; tap to pause.
/// A speaker button mutes every video and the choice is remembered
/// (`muteKey` in UserDefaults). Playback (waiting for conversion, token
/// links, your own new video from this phone, preloaded starts) is
/// `VideoPlaybackModel`.
///
/// Colours are neutral (white on black). Draw it full-bleed under the status
/// bar with `topInset` (the status bar's height); the mute button sits
/// `muteButtonTop` below it.
public struct RemoteVideoView: View {
    /// Text shown over the video.
    public struct Labels: Sendable {
        public var processing: String
        public var failed: String
        public var mute: String
        public var unmute: String

        public init(
            processing: String = "Getting this video ready…",
            failed: String = "Video didn't load. Tap to try again",
            mute: String = "Mute videos",
            unmute: String = "Turn sound on"
        ) {
            self.processing = processing
            self.failed = failed
            self.mute = mute
            self.unmute = unmute
        }
    }

    public let videoId: String
    public let size: CGSize
    /// The post on screen while the feed is showing.
    public let isActive: Bool
    private let landscape: Bool
    private let topInset: CGFloat
    private let muteButtonTop: CGFloat
    private let posterCache: PhotoImageCache?
    private let localFile: URL?
    private let labels: Labels

    @AppStorage private var muted: Bool
    @StateObject private var model: VideoPlaybackModel

    /// - Parameters:
    ///   - landscape: wider than tall: shown whole over a blurred copy of the poster.
    ///   - posterCache: where `MediaUploadQueue` keeps the poster of your own
    ///     new video (`PhotoImageCache.key(for: videoId)`).
    ///   - localFile: play this file instead of the stream (previews, UI tests).
    ///   - muteKey: the UserDefaults key remembering the mute choice.
    public init(
        videoId: String,
        size: CGSize,
        isActive: Bool,
        videos: VideosService,
        landscape: Bool = false,
        topInset: CGFloat = 0,
        muteButtonTop: CGFloat = 60,
        posterCache: PhotoImageCache? = .shared,
        localFile: URL? = nil,
        muteKey: String = "feed.videosMuted",
        labels: Labels = Labels()
    ) {
        self.videoId = videoId
        self.size = size
        self.isActive = isActive
        self.landscape = landscape
        self.topInset = topInset
        self.muteButtonTop = muteButtonTop
        self.posterCache = posterCache
        self.localFile = localFile
        self.labels = labels
        _muted = AppStorage(wrappedValue: false, muteKey)
        _model = StateObject(wrappedValue: VideoPlaybackModel(videoId: videoId, videos: videos))
    }

    /// A video post: landscape when its width is larger than its height.
    public init(
        post: MediaPost,
        size: CGSize,
        isActive: Bool,
        videos: VideosService,
        topInset: CGFloat = 0,
        muteButtonTop: CGFloat = 60,
        posterCache: PhotoImageCache? = .shared,
        localFile: URL? = nil,
        muteKey: String = "feed.videosMuted",
        labels: Labels = Labels()
    ) {
        var landscape = false
        if let width = post.width, let height = post.height { landscape = width > height }
        self.init(
            videoId: post.mediaId, size: size, isActive: isActive, videos: videos, landscape: landscape,
            topInset: topInset, muteButtonTop: muteButtonTop, posterCache: posterCache,
            localFile: localFile, muteKey: muteKey, labels: labels
        )
    }

    public var body: some View {
        ZStack {
            Color.black
            if let poster = model.poster {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: landscape ? 30 : 0)
                    .opacity(landscape ? 0.5 : 1)
                    .clipped()
                if landscape {
                    Image(uiImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                }
            }
            PlayerLayerView(player: model.player, gravity: landscape ? .resizeAspect : .resizeAspectFill)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            overlay
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { model.togglePause() }
        .overlay(alignment: .topTrailing) {
            Button {
                muted.toggle()
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(.top, topInset + muteButtonTop)
            .padding(.trailing, 16)
            .accessibilityLabel(muted ? labels.unmute : labels.mute)
        }
        .task {
            model.isMuted = muted
            // Your own new video's poster is already on this phone.
            if let posterCache, let saved = await posterCache.saved(for: PhotoImageCache.key(for: videoId)) {
                model.setPoster(saved)
            } else {
                await model.loadPoster()
            }
        }
        .task(id: isActive) {
            if isActive { start() } else { model.pause() }
        }
        .onChange(of: muted) { value in model.isMuted = value }
        .onDisappear { model.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video")
    }

    private func start() {
        if let localFile {
            model.play(file: localFile)
        } else {
            model.play()
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.phase {
        case .loading:
            ProgressView().tint(.white)
        case .processing:
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(labels.processing)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(14)
            .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        case .failed:
            Button {
                model.play()
            } label: {
                Label(labels.failed, systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .accessibilityIdentifier("retryVideo")
        case .playing where model.isPaused:
            Image(systemName: "play.fill")
                .font(.system(size: 54))
                .foregroundColor(.white.opacity(0.85))
                .shadow(radius: 6)
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }
}
#endif
