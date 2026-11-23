#if os(iOS)
import SwiftUI
import UIKit
import XCTest
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

final class FeedPagerTests: XCTestCase {
    @MainActor
    func testScrollingFarKeepsFewPostsAliveAndReportsWhatIsNext() async throws {
        Alive.count = 0
        Alive.most = 0
        Created.total = 0
        let posts = (0..<500).map(Post.init)
        var active: Int? = nil
        var upcoming: [Int] = []
        var nearEnd = 0
        let binding = Binding<Int?>(get: { active }, set: { active = $0 })
        let pager = FeedPager(
            items: posts, activeID: binding, lookahead: 3,
            onUpcoming: { upcoming = $0.map(\.id) },
            onNearEnd: { nearEnd += 1 }
        ) { post, isActive in PostView(post: post, isActive: isActive) }
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
    func testPreloaderKeepsAtMostItsCapacity() {
        let preloader = VideoPreloader()
        preloader.capacity = 2
        for id in ["a", "b", "c"] {
            preloader.buffer(id, url: URL(string: "https://example.com/\(id).m3u8")!)
        }
        XCTAssertEqual(preloader.bufferedIds, ["b", "c"])
        XCTAssertNotNil(preloader.take("c"))
        XCTAssertNil(preloader.take("c"), "handed over once")
        preloader.clear()
        XCTAssertEqual(preloader.bufferedIds, [])
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }
}
#endif
