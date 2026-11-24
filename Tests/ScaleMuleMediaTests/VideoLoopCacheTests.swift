#if os(iOS)
import AVFoundation
import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleVideos

final class VideoLoopCacheTests: XCTestCase {
    @MainActor
    func testExistingPlaybackKeepsItsSourceUntilReactivationUsesTheDownloadedCache() async throws {
        PlaybackAnalytics.isEnabled = false
        defer { PlaybackAnalytics.isEnabled = true }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "fragmented", withExtension: "mp4", subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: fixture)
        let (app, session) = createTestClient()
        let master = self.master, media = self.media
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.path.hasSuffix("/playlist.m3u8") { return (ok, Data(master.utf8)) }
            if url.path.hasSuffix("/1080p/index.m3u8") { return (ok, Data(media.utf8)) }
            if url.path.hasSuffix("segments.m4s") { return (ok, bytes) }
            return TestFixtures.mockResponse(statusCode: 404, json: "{}")
        }
        let place = folder()
        defer { try? FileManager.default.removeItem(at: place) }
        let cache = VideoLoopCache(folder: place, session: session)
        let id = UUID().uuidString
        let model = VideoPlaybackModel(videoId: id, videos: VideosService(app: app), loopCache: cache)
        model.isMuted = true
        model.loadsCaptions = false
        model.play(file: fixture)
        defer { model.stop() }
        let stream = URL(string: "https://api.example.com/v1/videos/v1/playlist.m3u8")!
        let downloaded = await cache.file(for: id, stream: stream)
        let file = try XCTUnwrap(downloaded)
        // A completed background download must not replace the visible loop.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            XCTAssertEqual((model.player.currentItem?.asset as? AVURLAsset)?.url, fixture)
            try await Task.sleep(for: .milliseconds(30))
        }
        model.stop()
        model.play()
        let startDeadline = Date().addingTimeInterval(5)
        while model.phase != .playing, Date() < startDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.phase, .playing)
        XCTAssertEqual((model.player.currentItem?.asset as? AVURLAsset)?.url, file,
                       "the next viewing session must use the completed local cache")
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
#endif
