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
///
/// Captions (ScaleMule Video, transcribed when the video was posted) show
/// while the sound is off, or always with the iPhone's Closed Captions
/// setting; a CC button under the mute button turns them on or off for every
/// video (`CaptionPreferences`). They sit `captionBottomInset` above the
/// bottom, or pass `caption` to draw `VideoCaptionView` in your own layout,
/// for example just above the post's name and place.
public struct RemoteVideoView: View {
    /// Text shown over the video.
    public struct Labels: Sendable {
        public var processing: String
        public var failed: String
        public var mute: String
        public var unmute: String
        public var showCaptions: String
        public var hideCaptions: String

        public init(
            processing: String = "Getting this video ready…",
            failed: String = "Video didn't load. Tap to try again",
            mute: String = "Mute videos",
            unmute: String = "Turn sound on",
            showCaptions: String = "Show captions",
            hideCaptions: String = "Hide captions"
        ) {
            self.processing = processing
            self.failed = failed
            self.mute = mute
            self.unmute = unmute
            self.showCaptions = showCaptions
            self.hideCaptions = hideCaptions
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
    private let captionBottomInset: CGFloat
    private let captionOut: Binding<String?>?

    @AppStorage private var muted: Bool
    @StateObject private var model: VideoPlaybackModel
    @State private var firstFrameReady = false
    @ObservedObject private var captionPreferences: CaptionPreferences

    /// - Parameters:
    ///   - landscape: wider than tall: shown whole over a blurred copy of the poster.
    ///   - posterCache: where `MediaUploadQueue` keeps the poster of your own
    ///     new video (`PhotoImageCache.key(for: videoId)`).
    ///   - localFile: play this file instead of the stream (previews, UI tests).
    ///   - muteKey: the UserDefaults key remembering the mute choice.
    ///   - caption: receives the caption to show (nil when none or hidden);
    ///     the view then draws none itself.
    ///   - captionBottomInset: where the view draws captions itself, from the bottom.
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
        labels: Labels = Labels(),
        caption: Binding<String?>? = nil,
        captionBottomInset: CGFloat = 150,
        captionPreferences: CaptionPreferences = .shared
    ) {
        self.captionOut = caption
        self.captionBottomInset = captionBottomInset
        _captionPreferences = ObservedObject(wrappedValue: captionPreferences)
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
        labels: Labels = Labels(),
        caption: Binding<String?>? = nil,
        captionBottomInset: CGFloat = 150,
        captionPreferences: CaptionPreferences = .shared
    ) {
        var landscape = false
        if let width = post.width, let height = post.height { landscape = width > height }
        self.init(
            videoId: post.mediaId, size: size, isActive: isActive, videos: videos, landscape: landscape,
            topInset: topInset, muteButtonTop: muteButtonTop, posterCache: posterCache,
            localFile: localFile, muteKey: muteKey, labels: labels,
            caption: caption, captionBottomInset: captionBottomInset, captionPreferences: captionPreferences
        )
    }

    public var body: some View {
        ZStack {
            Color.black
            if landscape, let poster = model.poster {
                Image(uiImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 30)
                    .opacity(0.5)
                    .clipped()
            }
            PlayerLayerView(player: model.player, gravity: landscape ? .resizeAspect : .resizeAspectFill) { ready in
                firstFrameReady = ready
            }
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            // Keep the real poster ABOVE the player until its first frame is
            // drawable. Item-ready or play() alone does not mean a visible frame.
            if !firstFrameReady {
                if let poster = model.poster {
                    Image(uiImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: landscape ? .fit : .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                        .accessibilityIdentifier("videoPoster")
                } else {
                    Color(white: 0.12)
                    Image(systemName: "video.fill")
                        .font(.system(size: 44)).foregroundStyle(.white.opacity(0.25))
                }
            }
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
        .overlay(alignment: .topTrailing) {
            if model.hasCaptions {
                let showing = captionPreferences.showsCaptions(muted: muted)
                Button {
                    captionPreferences.toggle(muted: muted)
                } label: {
                    Image(systemName: showing ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .padding(.top, topInset + muteButtonTop + 46)
                .padding(.trailing, 16)
                .accessibilityLabel(showing ? labels.hideCaptions : labels.showCaptions)
                .accessibilityIdentifier("captionsButton")
            }
        }
        .overlay(alignment: .bottom) {
            if captionOut == nil, let shown = shownCaption {
                VideoCaptionView(shown)
                    .padding(.horizontal, 24)
                    .padding(.bottom, captionBottomInset)
            }
        }
        .onChange(of: shownCaption) { value in captionOut?.wrappedValue = value }
        .onDisappear { captionOut?.wrappedValue = nil }
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
        .onDisappear { firstFrameReady = false; model.stop() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video")
    }

    /// The caption to show now: there is one, and captions are on.
    private var shownCaption: String? {
        guard isActive, let caption = model.caption, captionPreferences.showsCaptions(muted: muted) else { return nil }
        return caption
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
        case .playing where !firstFrameReady:
            ProgressView().tint(.white)
        case .idle where isActive:
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
