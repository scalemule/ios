#if os(iOS)
import SwiftUI
import UIKit
import XCTest
import AVFoundation
import ScaleMuleTestHelpers
import ScaleMuleMediaPosts
@testable import ScaleMuleFeed
@testable import ScaleMuleVideos

private struct Post: Identifiable { let id: Int }

/// Counts post views alive at once (cells are reused; old posts are freed).
@MainActor
private enum Created { static var total = 0 }

@MainActor
private final class Alive {
    static var count = 0
    static var most = 0
}

private struct PostView: View {
    let post: Post
    let isActive: Bool
    @StateObject private var tracker = Tracker()
    var body: some View {
        Text("Post \(post.id)\(isActive ? " (active)" : "")")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("post-\(post.id)")
    }
}

@MainActor
private final class Tracker: ObservableObject {
    init() { Alive.count += 1; Alive.most = max(Alive.most, Alive.count); Created.total += 1 }
    deinit { MainActor.assumeIsolated { Alive.count -= 1 } }
}

private struct StatefulPager: View {
    let posts: [Post]
    let onUpcoming: ([Post]) -> Void
    let onNearEnd: () -> Void
    let onActive: (Int?) -> Void
    @State private var active: Int?

    var body: some View {
        FeedPager(items: posts, activeID: $active, lookahead: 3,
                  onUpcoming: onUpcoming, onNearEnd: onNearEnd) { post, isActive in
            PostView(post: post, isActive: isActive)
        }
        .onChange(of: active) { onActive($0) }
    }
}

@MainActor
private final class VideoUpdates: ObservableObject {
    @Published var revision = 0
}

private struct VideoPager: View {
    let ids: [String]
    let videos: VideosService
    @ObservedObject var updates: VideoUpdates
    @State private var active: String?

    private struct Video: Identifiable { let id: String }

    var body: some View {
        FeedPager(items: ids.map(Video.init), activeID: $active,
                  onUpcoming: { VideoPreloader.shared.preload($0.map(\.id), videos: videos) },
                  onActiveChanged: { VideoPreloader.shared.activate($0?.id) }) { item, isActive in
            RemoteVideoView(videoId: item.id, size: CGSize(width: 390, height: 844),
                            isActive: isActive, videos: videos)
                .overlay(alignment: .top) { Text("Revision \(updates.revision)") }
        }
    }
}

final class FeedPagerTests: XCTestCase {
    @MainActor
    func testVisibleVideoKeepsItsLayerAndItemAcrossBindingEchoesAndContentUpdates() async throws {
        PlaybackAnalytics.isEnabled = false
        defer { PlaybackAnalytics.isEnabled = true }
        MockURLProtocol.requestHandler = { _ in TestFixtures.mockResponse(statusCode: 404, json: "{}") }
        let (app, _) = createTestClient()
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        let ids = (0..<6).map { _ in UUID().uuidString }
        for id in ids { VideoFileCache.keep(clip, for: id) }
        let updates = VideoUpdates()
        let host = UIHostingController(rootView: VideoPager(ids: ids, videos: VideosService(app: app), updates: updates).ignoresSafeArea())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            VideoPreloader.shared.clear()
            ids.forEach(VideoFileCache.remove)
        }
        try await Task.sleep(for: .milliseconds(300))
        let collection = try XCTUnwrap(Self.find(UICollectionView.self, in: host.view))
        for page in 0..<ids.count {
            collection.setContentOffset(CGPoint(x: 0, y: CGFloat(page) * collection.bounds.height), animated: false)
            collection.layoutIfNeeded()
            let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: page, section: 0)))
            let deadline = Date().addingTimeInterval(5)
            while Self.find(PlayerLayerView.PlayerUIView.self, in: cell)?.playerLayer.isReadyForDisplay != true, Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let surface = try XCTUnwrap(Self.find(PlayerLayerView.PlayerUIView.self, in: cell))
            let player = try XCTUnwrap(surface.playerLayer.player)
            let item = try XCTUnwrap(player.currentItem)
            XCTAssertTrue(surface.playerLayer.isReadyForDisplay)
            for _ in 0..<3 {
                updates.revision += 1 // Same path as active-ID echoes, counts and parent state changes.
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertTrue(Self.find(PlayerLayerView.PlayerUIView.self, in: cell) === surface,
                              "updating feed state must not remount the visible video layer")
                XCTAssertTrue(surface.playerLayer.player === player)
                XCTAssertTrue(player.currentItem === item,
                              "a visible video must not be stopped and started from zero on a feed update")
                XCTAssertTrue(surface.playerLayer.isReadyForDisplay,
                              "the displayed frame must survive parent updates")
            }
        }
    }

    @MainActor
    func testScrollingFarKeepsFewPostsAliveAndReportsWhatIsNext() async throws {
        Alive.count = 0
        Alive.most = 0
        Created.total = 0
        let posts = (0..<500).map(Post.init)
        var active: Int? = nil
        var upcoming: [Int] = []
        var nearEnd = 0
        // Exercise real SwiftUI binding echoes as well as UIKit scrolling.
        let pager = StatefulPager(posts: posts,
                                  onUpcoming: { upcoming = $0.map(\.id) },
                                  onNearEnd: { nearEnd += 1 },
                                  onActive: { active = $0 })
        let host = UIHostingController(rootView: pager.ignoresSafeArea())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(upcoming, [1, 2, 3], "the next three posts are announced")

        let collection = try XCTUnwrap(Self.find(UICollectionView.self, in: host.view))
        for page in 1..<500 {
            collection.setContentOffset(CGPoint(x: 0, y: CGFloat(page) * collection.bounds.height), animated: false)
            collection.layoutIfNeeded()
            if page % 25 == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        collection.delegate?.scrollViewDidEndDecelerating?(collection)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(active, 499)
        XCTAssertEqual(upcoming, [], "nothing after the last post")
        XCTAssertGreaterThan(nearEnd, 0)
        print("FEEDPAGER alive at most \(Alive.most), now \(Alive.count), created over 500 posts \(Created.total)")
        XCTAssertGreaterThan(Created.total, 100, "posts were really drawn as the feed scrolled")
        XCTAssertGreaterThanOrEqual(Alive.most, 1)
        XCTAssertLessThanOrEqual(Alive.most, 8, "only the cells near the screen exist (\(Alive.most) at most)")
        XCTAssertLessThanOrEqual(Alive.count, 6, "posts scrolled past are freed (\(Alive.count) alive)")
        window.isHidden = true
    }

    @MainActor
    func testPreloaderKeepsAtMostItsCapacity() async throws {
        let preloader = VideoPreloader()
        preloader.capacity = 2
        XCTAssertEqual(VideoPreloader().capacity, 4, "TikTok style: the next four videos")
        XCTAssertEqual(VideoPreloader().bufferSeconds, 1, "about one second of each")
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        for id in ["a", "b", "c"] {
            preloader.buffer(id, url: clip)
        }
        XCTAssertEqual(preloader.preparingIds, ["b", "c"])
        let deadline = Date().addingTimeInterval(6)
        while preloader.bufferedIds.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(preloader.bufferedIds, ["b", "c"])
        XCTAssertNotNil(preloader.take("c"))
        XCTAssertNil(preloader.take("c"), "handed over once")
        preloader.clear()
        XCTAssertEqual(preloader.bufferedIds, [])
    }

    @MainActor
    func testVisibleVideoIsHandedOverBeforeTheNextWindowPrunesIt() async throws {
        let preloader = VideoPreloader()
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        preloader.buffer("next", url: clip)
        let deadline = Date().addingTimeInterval(6)
        while preloader.bufferedIds.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(preloader.bufferedIds, ["next"], "an actual AVFoundation preroll completed")
        preloader.activate("next")
        let (app, _) = createTestClient()
        preloader.preload([], videos: VideosService(app: app))
        let warmed = try XCTUnwrap(preloader.take("next"), "the cell must still receive the reached video")
        XCTAssertEqual(warmed.player.currentItem?.status, .readyToPlay)
        XCTAssertEqual(warmed.player.rate, 0, "speculative players must stay silent and paused")
        XCTAssertNil(preloader.take("next"))
        warmed.stop()
        preloader.clear()
    }

    @MainActor
    func testTakingAnInFlightPlayerAndClearingCacheDoesNotStopItsPlayback() async throws {
        let preloader = VideoPreloader()
        let clip = try XCTUnwrap(Bundle.module.url(forResource: "portrait-1", withExtension: "mov", subdirectory: "Fixtures"))
        preloader.buffer("next", url: clip)
        preloader.activate("next")
        let result = await preloader.acquire("next")
        let player = try XCTUnwrap(result)
        preloader.clear()
        player.player.play()
        let deadline = Date().addingTimeInterval(4)
        while !player.player.currentTime().seconds.isFinite || player.player.currentTime().seconds < 0.1 {
            guard Date() < deadline else { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(player.player.currentTime().seconds, 0.05, "canceling speculative work must not kill the transferred player")
        player.stop()
    }

    @MainActor
    func testFastScrollingAdvancesPreparationBeforeDecelerationEndsAndDoesNotEchoScrollBack() async throws {
        var active: Int?
        var upcoming: [Int] = []
        var events: [String] = []
        let pager = FeedPager(items: (0..<100).map(Post.init), activeID: Binding(get: { active }, set: { active = $0 }),
                              onUpcoming: { items in upcoming = items.map(\.id); events.append("upcoming") },
                              onActiveChanged: { item in events.append("active:\(item?.id ?? -1)") }) { post, isActive in
            PostView(post: post, isActive: isActive)
        }
        let controller = FeedPagerController(pager: pager)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 250_000_000)
        let collection = try XCTUnwrap(Self.find(UICollectionView.self, in: controller.view))
        events.removeAll()
        let pageHeight = collection.bounds.height
        collection.setContentOffset(CGPoint(x: 0, y: pageHeight * 20), animated: false)
        collection.layoutIfNeeded()
        collection.delegate?.scrollViewDidScroll?(collection)
        XCTAssertEqual(upcoming, [21, 22, 23, 24], "preparation moves while scrolling, without an end-deceleration event")
        XCTAssertEqual(events.prefix(2), ["active:20", "upcoming"], "protect the landing item before pruning it from the next window")
        controller.update(pager) // SwiftUI still holds the previous binding this turn.
        XCTAssertEqual(collection.contentOffset.y, pageHeight * 20, accuracy: 1)
        collection.setContentOffset(CGPoint(x: 0, y: pageHeight * 30), animated: false)
        collection.delegate?.scrollViewDidScroll?(collection)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(active, 30, "a queued publish for page 20 must not override page 30")
        XCTAssertEqual(upcoming, [31, 32, 33, 34])
        window.isHidden = true
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }
}
#endif
