#if os(iOS)
import AVFoundation
import UIKit
import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleVideos

final class VideoLoopCacheTests: XCTestCase {
    @MainActor
    func testDownloadedCopyOnlySplicesIntoTheMatchingVideoFormat() async throws {
        let current = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        let different = try XCTUnwrap(Bundle.module.url(forResource: "fragmented", withExtension: "mp4", subdirectory: "Fixtures"))
        let looping = LoopingPlayer()
        looping.player.isMuted = true
        looping.load(current)
        looping.player.play()
        defer { looping.stop() }
        let deadline = Date().addingTimeInterval(5)
        while looping.player.currentItem?.tracks.isEmpty != false, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let same = await VideoPlaybackModel.hasMatchingVideoFormat(looping.player.currentItem, file: current)
        let changed = await VideoPlaybackModel.hasMatchingVideoFormat(looping.player.currentItem, file: different)
        let unknown = await VideoPlaybackModel.hasMatchingVideoFormat(nil, file: current)
        XCTAssertTrue(same)
        XCTAssertFalse(changed, "changing the decoder format during a visible loop must be deferred")
        XCTAssertFalse(unknown, "unknown stream formats must keep the current video running")
    }

    @MainActor
    func testPendingCachedCopyCannotReviveAStoppedOrReplacedPlayer() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "fragmented", withExtension: "mp4", subdirectory: "Fixtures"))
        let place = folder()
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: place) }
        let copy = place.appendingPathComponent("copy.mp4")
        try FileManager.default.copyItem(at: fixture, to: copy)
        for replace in [false, true] {
            let looping = LoopingPlayer()
            var callbacks = 0
            looping.load(fixture)
            looping.replaceAtNextLoop(with: copy) { callbacks += 1 }
            if replace { looping.load(fixture) } else { looping.stop() }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(looping.hasPendingReplacement)
            XCTAssertEqual(callbacks, 0, "canceled preparation must not switch another viewing session")
            XCTAssertEqual(looping.player.rate, 0, "background cache preparation must not start playback")
            if !replace { XCTAssertNil(looping.player.currentItem) }
            looping.stop()
        }
    }

    @MainActor
    func testSwitchingToTheDownloadedCopyNeverEmptiesTheVisibleQueue() async throws {
        guard #available(iOS 17, *) else { return }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "fragmented", withExtension: "mp4", subdirectory: "Fixtures"))
        let place = folder()
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: place) }
        let first = place.appendingPathComponent("stream.mp4"), copy = place.appendingPathComponent("download.mp4")
        try FileManager.default.copyItem(at: fixture, to: first)
        try FileManager.default.copyItem(at: fixture, to: copy)
        let looping = LoopingPlayer()
        let surface = PlayerLayerView.PlayerUIView(frame: CGRect(x: 0, y: 0, width: 180, height: 320))
        let controller = UIViewController()
        controller.view.addSubview(surface)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        surface.configure(player: looping.player, gravity: .resizeAspectFill, onReady: nil)
        looping.player.isMuted = true
        looping.load(first)
        looping.player.play()
        defer { looping.stop(); window.isHidden = true }
        let firstFrameDeadline = Date().addingTimeInterval(5)
        while !surface.playerLayer.isReadyForDisplay, Date() < firstFrameDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(surface.playerLayer.isReadyForDisplay)
        let empty = EmptyQueueEvents()
        let observation = looping.player.observe(\.currentItem, options: [.new]) { player, _ in
            if player.currentItem == nil { empty.note() }
        }
        defer { observation.invalidate() }
        looping.replaceAtNextLoop(with: copy)
        let duration = try await AVURLAsset(url: fixture).load(.duration).seconds
        let deadline = Date().addingTimeInterval(duration * 3 + 5)
        while looping.source != copy, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(looping.source, copy)
        XCTAssertEqual(empty.count, 0, "switching a visible loop must not remove its current item, even for one frame")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(surface.playerLayer.isReadyForDisplay)
    }
    private let master = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=600000,RESOLUTION=360x640
    /v1/videos/v1/stream/360p/index.m3u8?token=t
    #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1080x1920
    /v1/videos/v1/stream/1080p/index.m3u8?token=t
    """
    private let media = """
    #EXTM3U
    #EXT-X-MAP:URI="https://assets.example.com/v/hls/1080p/segments.m4s",BYTERANGE="800@0"
    #EXTINF:2.0,
    #EXT-X-BYTERANGE:5000@800
    https://assets.example.com/v/hls/1080p/segments.m4s
    #EXT-X-ENDLIST
    """

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("loop-cache-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    func testDownloadsTheVideoOnceAndKeepsIt() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "fragmented", withExtension: "mp4", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: fixture)
        let (_, session) = createTestClient()
        var requests: [String] = []
        let master = self.master, media = self.media
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            requests.append(url.path)
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.hasSuffix("/playlist.m3u8") { return (ok, Data(master.utf8)) }
            if url.path.hasSuffix("/1080p/index.m3u8") { return (ok, Data(media.utf8)) }
            if url.path.hasSuffix("segments.m4s") { return (ok, bytes) }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let place = folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let cache = VideoLoopCache(folder: place, session: session)
        let stream = URL(string: "https://api.example.com/v1/videos/v1/playlist.m3u8?token=t")!
        let downloaded = await cache.file(for: "v1", stream: stream)
        let file = try XCTUnwrap(downloaded)
        XCTAssertEqual(try Data(contentsOf: file), bytes, "the 1080p file, whole")
        XCTAssertEqual(requests.filter { $0.hasSuffix("segments.m4s") }.count, 1)
        let playable = try await AVURLAsset(url: file).load(.isPlayable)
        XCTAssertTrue(playable)

        MockURLProtocol.requestHandler = { _ in XCTFail("downloaded twice"); throw URLError(.badURL) }
        let again = await cache.file(for: "v1", stream: stream)
        XCTAssertEqual(again, file)
        XCTAssertEqual(cache.cachedFile(for: "v1"), file)

        cache.forget("v1")
        XCTAssertNil(cache.cachedFile(for: "v1"))
    }

    @MainActor
    func testFailedDownloadKeepsNothing() async throws {
        let (_, session) = createTestClient()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let place = folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let cache = VideoLoopCache(folder: place, session: session)
        let file = await cache.file(for: "v2", stream: URL(string: "https://api.example.com/v1/videos/v2/playlist.m3u8")!)
        XCTAssertNil(file)
        XCTAssertNil(cache.cachedFile(for: "v2"))
    }

    @MainActor
    func testOldestCopiesGoBeyondTheLimit() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "fragmented", withExtension: "mp4", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: fixture)
        let (_, session) = createTestClient()
        let master = self.master, media = self.media
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.hasSuffix("/playlist.m3u8") { return (ok, Data(master.utf8)) }
            if url.path.hasSuffix("/1080p/index.m3u8") { return (ok, Data(media.utf8)) }
            return (ok, bytes)
        }
        let place = folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let cache = VideoLoopCache(folder: place, session: session)
        cache.maxBytes = Int64(bytes.count) * 2
        for id in ["a", "b", "c"] {
            _ = await cache.file(for: id, stream: URL(string: "https://api.example.com/v1/videos/\(id)/playlist.m3u8")!)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(cache.cachedFile(for: "a"), "oldest dropped")
        XCTAssertNotNil(cache.cachedFile(for: "b"))
        XCTAssertNotNil(cache.cachedFile(for: "c"))
    }

    @MainActor
    func testLoopMovesToTheCopyAtTheNextLoop() async throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "fragmented", withExtension: "mp4", subdirectory: "Fixtures"))
        let place = folder()
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: place) }
        let first = place.appendingPathComponent("first.mp4"), copy = place.appendingPathComponent("copy.mp4")
        try FileManager.default.copyItem(at: fixture, to: first)
        try FileManager.default.copyItem(at: fixture, to: copy)
        let looping = LoopingPlayer()
        looping.player.isMuted = true
        looping.load(first)
        var loops = 0, replaced = 0
        looping.onLoop = { loops += 1 }
        looping.replaceAtNextLoop(with: copy) { replaced += 1 }
        XCTAssertTrue(looping.hasPendingReplacement)
        looping.player.play()
        let duration = try await AVURLAsset(url: fixture).load(.duration).seconds
        let deadline = Date().addingTimeInterval(duration * 3 + 5)
        while looping.source != copy, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(looping.source, copy, "plays from the copy after a loop")
        XCTAssertEqual(replaced, 1)
        XCTAssertGreaterThanOrEqual(loops, 1)
        XCTAssertFalse(looping.hasPendingReplacement)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertGreaterThan(looping.player.rate, 0, "still playing")
        looping.stop()
    }
}

private final class EmptyQueueEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func note() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
