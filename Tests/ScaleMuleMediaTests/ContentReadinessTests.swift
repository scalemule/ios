#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit
import XCTest
import ScaleMuleMediaPosts
import ScaleMulePhotos
import ScaleMuleTestHelpers
@testable import ScaleMuleVideos

final class ContentReadinessTests: XCTestCase {
    @MainActor
    func testShortLoadingWaitDoesNotFlashASpinnerButASustainedWaitDoes() async throws {
        let (app, _) = createTestClient()
        MockURLProtocol.requestHandler = { _ in
            Thread.sleep(forTimeInterval: 1)
            return TestFixtures.mockResponse(statusCode: 404, json: "{}")
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView:
            RemoteVideoView(videoId: UUID().uuidString, size: CGSize(width: 180, height: 320),
                            isActive: true, videos: VideosService(app: app)))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(Self.spinner(in: window), "a normal 50–100 ms handoff must not display loading UI")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNotNil(Self.spinner(in: window), "a genuine sustained wait must still provide loading feedback")
    }

    @MainActor
    func testPreloadingPublishesTheFirstFrameToAnAlreadyMountedInactiveVideo() async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Player-level frame output requires iOS 18") }
        let (app, _) = createTestClient()
        // No server poster: the image must come from the preloaded decoder.
        MockURLProtocol.requestHandler = { _ in TestFixtures.mockResponse(statusCode: 404, json: "{}") }
        let id = UUID().uuidString
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        let preloader = VideoPreloader()
        var ready = 0
        let video = RemoteVideoView(videoId: id, size: CGSize(width: 180, height: 320), isActive: false,
                                    videos: VideosService(app: app), onReady: { ready += 1 })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: video)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            preloader.clear(); VideoPlaybackModel.forgetPoster(id)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ready, 0)
        preloader.buffer(id, url: clip)
        let deadline = Date().addingTimeInterval(6)
        while ready == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(ready, 0, "the real cover must appear before the post becomes active")
        XCTAssertNotNil(VideoPosterStore.shared.cached(id))
        XCTAssertFalse(Self.playerLayer(in: window)?.isReadyForDisplay == true, "the mounted cell has not started a player")
        let prepared = try XCTUnwrap(preloader.take(id))
        XCTAssertEqual(prepared.player.rate, 0, "preparing a cover must not play the next post")
        prepared.stop()
    }

    @MainActor
    func testARequestedPhotoIsNotReadyUntilItsDecodedImageAppears() async throws {
        let (app, _) = createTestClient()
        var provide: CheckedContinuation<UIImage?, Never>?
        var ready = 0
        let photo = RemotePhotoView(photoId: UUID().uuidString, size: CGSize(width: 180, height: 320),
                                    photos: PhotosService(app: app),
                                    loader: { _, _, _ in await withCheckedContinuation { provide = $0 } },
                                    onReady: { ready += 1 })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: photo)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ready, 0, "a spinner must not count as feed content")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 320)).image { context in
            UIColor.cyan.setFill(); context.fill(CGRect(x: 0, y: 0, width: 180, height: 320))
        }
        try XCTUnwrap(provide).resume(returning: image)
        let deadline = Date().addingTimeInterval(3)
        while ready == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(ready, 0, "the actual loaded image must appear before onboarding may proceed")
    }

    @MainActor
    func testAVideoWithoutAPosterWaitsForItsActualFirstFrame() async throws {
        let (app, _) = createTestClient()
        MockURLProtocol.requestHandler = { _ in TestFixtures.mockResponse(statusCode: 404, json: "{}") }
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        var ready = 0
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let video = RemoteVideoView(videoId: UUID().uuidString, size: CGSize(width: 180, height: 320), isActive: true,
                                    videos: VideosService(app: app), localFile: clip, onReady: {
            XCTAssertTrue(Self.playerLayer(in: window)?.isReadyForDisplay == true)
            ready += 1
        })
        window.rootViewController = UIHostingController(rootView: video)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let deadline = Date().addingTimeInterval(5)
        while ready == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(ready, 0)
    }

    @MainActor private static func playerLayer(in view: UIView) -> AVPlayerLayer? {
        if let player = view as? PlayerLayerView.PlayerUIView { return player.playerLayer }
        if let player = view.layer as? AVPlayerLayer { return player }
        for subview in view.subviews { if let player = playerLayer(in: subview) { return player } }
        return nil
    }

    @MainActor private static func spinner(in view: UIView) -> UIActivityIndicatorView? {
        if let spinner = view as? UIActivityIndicatorView, spinner.isAnimating { return spinner }
        for subview in view.subviews { if let spinner = spinner(in: subview) { return spinner } }
        return nil
    }
}
#endif
