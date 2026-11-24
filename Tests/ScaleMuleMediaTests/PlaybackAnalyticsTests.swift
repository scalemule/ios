#if os(iOS)
import AVFoundation
import XCTest
@testable import ScaleMuleCore
@testable import ScaleMuleVideos

/// A real AVPlayer plays a 1 s clip on a loop; the events are what the
/// ScaleMule dashboard reads.
final class PlaybackAnalyticsTests: XCTestCase {
    @MainActor
    func testARealPlayReportsFirstFrameLoopsWatchTimeAndTheFinalTotals() async throws {
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        var events: [PlaybackEvent] = []
        PlaybackAnalytics.heartbeatInterval = 1
        defer { PlaybackAnalytics.heartbeatInterval = 10 }
        let analytics = PlaybackAnalytics(videoId: "v1") { events.append($0) }
        let looping = LoopingPlayer()
        looping.player.isMuted = true
        looping.load(clip)
        analytics.attach(looping.player)
        looping.player.play()
        try await Task.sleep(nanoseconds: 3_500_000_000)
        analytics.finish()
        looping.stop()

        let kinds = events.map(\.type)
        XCTAssertEqual(kinds.first, .play, "\(kinds)")
        XCTAssertEqual(kinds.filter { $0 == .play }.count, 1, "one view per session")
        XCTAssertGreaterThanOrEqual(kinds.filter { $0 == .complete }.count, 1, "loops are reported: \(kinds)")
        XCTAssertTrue(kinds.contains(.heartbeat), "\(kinds)")
        XCTAssertEqual(kinds.last, .pause)
        XCTAssertTrue(Set(events.map(\.sessionId)).count == 1)
        let first = try XCTUnwrap(events.first)
        XCTAssertNotNil(first.metadata["ttff_ms"]?.value as? Int)
        let last = try XCTUnwrap(events.last)
        let watched = try XCTUnwrap(last.metadata["watched_seconds"]?.value as? Double)
        XCTAssertGreaterThan(watched, 2.0, "about 3 s watched across loops")
        XCTAssertLessThan(watched, 4.5)
        XCTAssertEqual(last.metadata["watch_through_ratio"]?.value as? Double ?? (last.metadata["watch_through_ratio"]?.value as? Int).map(Double.init), 1.0)
        XCTAssertNotNil(last.metadata["connection_effective_type"])
        XCTAssertEqual(last.metadata["codec"]?.value as? String, "h264", "the codec playing")
        XCTAssertEqual(last.metadata["playback_source"]?.value as? String, "file")
        XCTAssertNotNil(last.metadata["bytes_transferred"], "bytes reported (none for a file)")
        // Nothing after finish.
        let count = events.count
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(events.count, count)
    }

    func testPlaybackSourceSaysWhereTheCopyIs() {
        XCTAssertEqual(PlaybackAnalytics.playbackSource(URL(string: "https://api.example.com/v1/videos/v/playlist.m3u8")), "stream")
        XCTAssertEqual(PlaybackAnalytics.playbackSource(URL(fileURLWithPath: "/x/Caches/scalemule-video-loops/v.mp4")), "local_copy")
        XCTAssertEqual(PlaybackAnalytics.playbackSource(URL(fileURLWithPath: "/x/Caches/scalemule-videos/v.mp4")), "own_upload")
        XCTAssertNil(PlaybackAnalytics.playbackSource(nil))
        XCTAssertEqual(PlaybackAnalytics.codecName(kCMVideoCodecType_HEVC), "hevc")
        XCTAssertEqual(PlaybackAnalytics.codecName(kCMVideoCodecType_H264), "h264")
    }

    func testLoopCopyPrefersHEVCAndSharingPrefersH264() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1080x1920,CODECS="avc1.64002a,mp4a.40.2"
        h264/1080p/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1600000,RESOLUTION=1080x1920,CODECS="hvc1.1.6.L120.90,mp4a.40.2"
        hevc/1080p/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1800000,RESOLUTION=720x1280,CODECS="avc1.64002a,mp4a.40.2"
        h264/720p/index.m3u8
        """
        let base = URL(string: "https://api.example.com/v1/videos/v/playlist.m3u8")!
        XCTAssertEqual(HLSPlaylist.bestVariant(in: master, base: base, maxShortSide: 1080, preferHEVC: true)?.path, "/v1/videos/v/hevc/1080p/index.m3u8")
        XCTAssertEqual(HLSPlaylist.bestVariant(in: master, base: base, maxShortSide: 1080)?.path, "/v1/videos/v/h264/1080p/index.m3u8")
        XCTAssertEqual(HLSPlaylist.bestVariant(in: master, base: base, maxShortSide: 720, preferHEVC: true)?.path, "/v1/videos/v/h264/720p/index.m3u8", "no HEVC at 720p: H.264")
    }

    func testErrorsAreClassified() {
        XCTAssertEqual(PlaybackAnalytics.classify("The Internet connection appears to be offline."), "network")
        XCTAssertEqual(PlaybackAnalytics.classify("HTTP 403 Forbidden"), "auth")
        XCTAssertEqual(PlaybackAnalytics.classify("Cannot decode"), "media")
        XCTAssertEqual(PlaybackAnalytics.classify("Ошибка 未知 🎬"), "other")
    }
}
#endif
