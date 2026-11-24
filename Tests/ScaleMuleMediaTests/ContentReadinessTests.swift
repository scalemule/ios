#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit
import XCTest
import ScaleMuleMediaPosts
import ScaleMulePhotos
import ScaleMuleTestHelpers
import ScaleMuleVideos

final class ContentReadinessTests: XCTestCase {
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
        if let player = view.layer as? AVPlayerLayer { return player }
        for subview in view.subviews { if let player = playerLayer(in: subview) { return player } }
        return nil
    }
}
#endif
