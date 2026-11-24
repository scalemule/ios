#if os(iOS)
import AVFoundation
import UIKit
import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleVideos

private final class RequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func note(_ path: String) { lock.lock(); defer { lock.unlock() }; paths.append(path) }
    func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0 == path }.count }
}

final class VideoHandoffTests: XCTestCase {
    @MainActor
    func testLayerReadinessRequiresAnActualFirstFrameAndResetsForAnotherPlayer() async throws {
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        let first = LoopingPlayer(), second = LoopingPlayer()
        let view = PlayerLayerView.PlayerUIView(frame: CGRect(x: 0, y: 0, width: 180, height: 320))
        let root = UIViewController()
        root.view.addSubview(view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        var ready = false
        view.configure(player: first.player, gravity: .resizeAspectFill) { ready = $0 }
        XCTAssertFalse(ready, "no poster handoff before the player has even loaded a frame")
        XCTAssertEqual(view.playerLayer.opacity, 0, "an empty layer must reveal its backing poster immediately")
        first.player.isMuted = true
        first.load(clip)
        first.player.play()
        let deadline = Date().addingTimeInterval(5)
        while !ready, Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(ready, "the real AVPlayerLayer must report a drawable frame")
        XCTAssertEqual(view.playerLayer.opacity, 1)
        first.stop()
        XCTAssertEqual(view.playerLayer.opacity, 1, "a queue transition must not reapply the first-frame poster")
        first.load(clip)
        first.player.play()
        let restartDeadline = Date().addingTimeInterval(5)
        while !ready || view.playerLayer.opacity == 0, Date() < restartDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(view.playerLayer.opacity, 1)
        view.configure(player: second.player, gravity: .resizeAspectFill) { ready = $0 }
        XCTAssertEqual(view.playerLayer.opacity, 0, "cover the empty replacement before a later SwiftUI update")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(ready, "a previous player's ready notification must not uncover an empty replacement")
        view.configure(player: nil, gravity: .resizeAspectFill, onReady: nil)
        first.stop()
        second.stop()
        window.isHidden = true
    }

    @MainActor
    func testEndingTheViewingSessionReplacesItsPlayerIdentity() {
        let (app, _) = createTestClient()
        let model = VideoPlaybackModel(videoId: UUID().uuidString, videos: VideosService(app: app))
        let player = model.player
        model.stop()
        XCTAssertFalse(model.player === player, "only a new viewing session should reset first-frame readiness")
        XCTAssertNil(model.player.currentItem)
    }

    @MainActor
    func testCanceledMetadataCannotRestartAStoppedCellOrReplaceItsNewLocalPlayback() async throws {
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        PlaybackAnalytics.isEnabled = false
        defer { PlaybackAnalytics.isEnabled = true }
        for replacement in [false, true] {
            let counts = RequestCounts()
            let (app, _) = createTestClient()
            let id = "handoff-\(UUID().uuidString)"
            MockURLProtocol.requestHandler = { request in
                counts.note(request.url!.path)
                Thread.sleep(forTimeInterval: 0.2)
                return TestFixtures.mockResponse(statusCode: 200, json: "{\"success\":true,\"data\":{\"id\":\"\(id)\",\"status\":\"failed\"}}")
            }
            let model = VideoPlaybackModel(videoId: id, videos: VideosService(app: app))
            model.loadsCaptions = false
            model.loopsFromLocalCopy = false
            model.isMuted = true
            model.play()
            let deadline = Date().addingTimeInterval(2)
            while counts.count("/v1/videos/\(id)") == 0, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(counts.count("/v1/videos/\(id)"), 1)
            if replacement { model.play(file: clip) } else { model.stop() }
            try await Task.sleep(nanoseconds: 350_000_000)
            XCTAssertEqual(model.phase, replacement ? .playing : .idle)
            if !replacement { XCTAssertNil(model.player.currentItem) }
            model.stop()
        }
    }

    @MainActor
    func testPosterPreparationAndVisibleCellShareOneDecodedImageRequest() async throws {
        let counts = RequestCounts()
        let (app, session) = createTestClient()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 180)).image { context in
            UIColor.cyan.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 180))
        }
        let bytes = try XCTUnwrap(image.pngData())
        MockURLProtocol.requestHandler = { request in
            let path = request.url!.path
            counts.note(path)
            if path == "/poster.png" {
                Thread.sleep(forTimeInterval: 0.1)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, bytes)
            }
            return TestFixtures.mockResponse(statusCode: 200, json: #"{"success":true,"data":{"id":"poster","status":"ready","thumbnail_url":"https://images.test/poster.png"}}"#)
        }
        let posters = VideoPosterStore(session: session)
        let videos = VideosService(app: app)
        async let speculative = posters.load("poster", videos: videos)
        async let visible = posters.load("poster", videos: videos)
        let (first, second) = await (speculative, visible)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertNotNil(posters.cached("poster"))
        XCTAssertEqual(counts.count("/v1/videos/poster"), 1)
        XCTAssertEqual(counts.count("/poster.png"), 1)
        posters.forget("poster")
        XCTAssertNil(posters.cached("poster"))
    }
}
#endif
