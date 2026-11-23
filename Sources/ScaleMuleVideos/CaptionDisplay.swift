#if canImport(UIKit)
import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Captions fetched from ScaleMule Video, by video id. A video without
/// captions is asked again after a few minutes (captions of a new post may
/// arrive just after it).
@MainActor
public final class VideoCaptionStore {
    public static let shared = VideoCaptionStore()
    private var tracks: [String: CaptionTrack] = [:]
    private var missing: [String: Date] = [:]
    private var loading: [String: Task<CaptionTrack?, Never>] = [:]
    /// How long "no captions" is remembered.
    public var missingTTL: TimeInterval = 300

    public init() {}

    public func track(for videoId: String, videos: VideosService) async -> CaptionTrack? {
        if let track = tracks[videoId] { return track }
        if let since = missing[videoId], Date().timeIntervalSince(since) < missingTTL { return nil }
        if let running = loading[videoId] { return await running.value }
        let task = Task { () -> CaptionTrack? in
            guard case .success(let all) = await videos.captions(id: videoId) else { return nil }
            return all.preferred()
        }
        loading[videoId] = task
        let track = await task.value
        loading[videoId] = nil
        if let track, !track.cues.isEmpty {
            tracks[videoId] = track
            missing[videoId] = nil
        } else {
            missing[videoId] = Date()
        }
        return tracks[videoId]
    }

    /// Captions this phone already has (just transcribed, or a fixture).
    public func store(_ track: CaptionTrack, for videoId: String) {
        tracks[videoId] = track
        missing[videoId] = nil
    }

    public func forget(_ videoId: String) {
        tracks[videoId] = nil
        missing[videoId] = nil
    }
}

/// Whether captions show, for every video in the app (remembered).
/// `automatic`: shown while the sound is off, or always when the iPhone's
/// Accessibility → Subtitles & Captioning → Closed Captions is on, the way
/// Instagram and TikTok do it. The CC button switches to `on` or `off`.
@MainActor
public final class CaptionPreferences: ObservableObject {
    public enum Mode: String, Sendable { case automatic, on, off }

    public static let shared = CaptionPreferences()
    private let defaults: UserDefaults
    private let key: String
    private var observer: NSObjectProtocol?

    @Published public var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: key) }
    }
    @Published public private(set) var systemCaptionsOn = UIAccessibility.isClosedCaptioningEnabled

    public init(defaults: UserDefaults = .standard, key: String = "scalemule.captions.mode") {
        self.defaults = defaults
        self.key = key
        mode = defaults.string(forKey: key).flatMap(Mode.init(rawValue:)) ?? .automatic
        observer = NotificationCenter.default.addObserver(
            forName: UIAccessibility.closedCaptioningStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemCaptionsOn = UIAccessibility.isClosedCaptioningEnabled }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    public func showsCaptions(muted: Bool) -> Bool {
        switch mode {
        case .on: return true
        case .off: return false
        case .automatic: return muted || systemCaptionsOn
        }
    }

    /// The CC button: hide what shows, show what is hidden.
    public func toggle(muted: Bool) {
        mode = showsCaptions(muted: muted) ? .off : .on
    }
}

/// A caption as people expect it on a phone: white, bold, on a dark
/// rounded band, centred, at most three lines, growing with Dynamic Type.
/// Put it where nothing covers it (above the post's name and place).
public struct VideoCaptionView: View {
    public let text: String
    /// `.leading` lines it up with a post's name and text; `.center` as on TV.
    public let alignment: HorizontalAlignment

    public init(_ text: String, alignment: HorizontalAlignment = .center) {
        self.text = text
        self.alignment = alignment
    }

    public var body: some View {
        Text(text)
            .font(.system(.body, design: .default).weight(.semibold))
            .foregroundColor(.white)
            .multilineTextAlignment(alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center)
            .lineLimit(3)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .accessibilityLabel(text)
            .accessibilityAddTraits(.updatesFrequently)
            .allowsHitTesting(false)
            .transaction { $0.animation = nil }
    }
}

/// Follows a player's position and says which caption is on screen.
@MainActor
final class CaptionClock {
    private weak var player: AVPlayer?
    private var observer: Any?
    private let onChange: (String?) -> Void
    private var track: CaptionTrack?
    private var current: String?

    init(onChange: @escaping (String?) -> Void) {
        self.onChange = onChange
    }

    func set(track: CaptionTrack?) {
        self.track = track
        update()
    }

    func attach(_ player: AVPlayer) {
        guard player !== self.player || observer == nil else { return }
        detach()
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    func detach() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player = nil
        publish(nil)
    }

    private func update() {
        guard let track, let player else { return publish(nil) }
        publish(track.cue(at: player.currentTime().seconds)?.text)
    }

    private func publish(_ text: String?) {
        guard text != current else { return }
        current = text
        onChange(text)
    }
}
#endif
