#if os(iOS)
import AVFoundation
import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleVideos

/// A real player: the caption on screen follows the video's position.
final class CaptionPlaybackTests: XCTestCase {
    @MainActor
    func testCaptionsFollowThePlayerAcrossLoops() async throws {
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        let id = "caption-test-\(UUID().uuidString)"
        VideoFileCache.keep(clip, for: id)
        defer { VideoFileCache.remove(id); VideoCaptionStore.shared.forget(id) }
        VideoCaptionStore.shared.store(CaptionTrack(language: "en-US", cues: [
            CaptionCue(start: 0, end: 0.45, text: "first"),
            CaptionCue(start: 0.5, end: 0.95, text: "second"),
        ]), for: id)
        PlaybackAnalytics.isEnabled = false
        defer { PlaybackAnalytics.isEnabled = true }
        let (app, _) = createTestClient()
        let model = VideoPlaybackModel(videoId: id, videos: VideosService(app: app))
        model.isMuted = true
        model.play()
        var seen: [String] = []
        let end = Date().addingTimeInterval(2.6)
        while Date() < end {
            if let text = model.caption, seen.last != text { seen.append(text) }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(model.hasCaptions)
        XCTAssertTrue(seen.contains("first") && seen.contains("second"), "\(seen)")
        XCTAssertGreaterThanOrEqual(seen.filter { $0 == "first" }.count, 2, "shown again on the next loop: \(seen)")
        model.stop()
        XCTAssertNil(model.caption, "nothing left on screen after stop")
    }

    @MainActor
    func testPreferencesAutomaticFollowsSoundAndTheButtonWins() {
        let defaults = UserDefaults(suiteName: "captions-\(UUID().uuidString)")!
        let preferences = CaptionPreferences(defaults: defaults)
        XCTAssertEqual(preferences.mode, .automatic)
        XCTAssertTrue(preferences.showsCaptions(muted: true))
        XCTAssertEqual(preferences.showsCaptions(muted: false), UIAccessibility.isClosedCaptioningEnabled)
        preferences.toggle(muted: true)
        XCTAssertEqual(preferences.mode, .off)
        XCTAssertFalse(preferences.showsCaptions(muted: true))
        preferences.toggle(muted: false)
        XCTAssertEqual(preferences.mode, .on)
        XCTAssertTrue(preferences.showsCaptions(muted: false))
        XCTAssertEqual(CaptionPreferences(defaults: defaults).mode, .on, "remembered")
    }
}
#endif
