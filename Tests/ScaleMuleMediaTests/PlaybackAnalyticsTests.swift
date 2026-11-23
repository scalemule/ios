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
        // Nothing after finish.
        let count = events.count
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(events.count, count)
    }

    func testErrorsAreClassified() {
        XCTAssertEqual(PlaybackAnalytics.classify("The Internet connection appears to be offline."), "network")
        XCTAssertEqual(PlaybackAnalytics.classify("HTTP 403 Forbidden"), "auth")
        XCTAssertEqual(PlaybackAnalytics.classify("Cannot decode"), "media")
        XCTAssertEqual(PlaybackAnalytics.classify("Ошибка 未知 🎬"), "other")
    }
}
#endif
