#if canImport(UIKit)
import SwiftUI
import UIKit

/// A full-screen, vertically paging feed (TikTok, Reels, Shorts) built on
/// `UICollectionView`: only the cells near the screen exist and they are
/// reused, so memory stays flat however far people scroll. SwiftUI draws
/// each post (`content`); the pager says which post is on screen and which
/// come next, so an app can preload them (`PhotoPrefetcher`,
/// `VideoPreloader`).
///
/// SwiftUI environment objects do not reach the cells (they live in
/// UIKit); pass what a post needs into `content`, or attach
/// `.environmentObject` there.
public struct FeedPager<Item: Identifiable, Content: View>: UIViewControllerRepresentable where Item.ID: Hashable & Sendable {
    public var items: [Item]
    /// The post on screen. Set it to scroll there (for example to the top).
    @Binding public var activeID: Item.ID?
    /// How many posts past the one on screen `onUpcoming` reports.
    public var lookahead: Int
    /// `onNearEnd` is called this many posts before the end, so the next
    /// page is there before anyone reaches it.
    public var loadMoreDistance: Int
    /// Called when the posts after the one on screen change (nearest first).
    public var onUpcoming: ([Item]) -> Void
    /// Synchronous handoff before the preload window moves past this item.
    public var onActiveChanged: (Item?) -> Void
    /// Called when the post on screen is within `loadMoreDistance` of the end.
    public var onNearEnd: () -> Void
    /// Pull to refresh, when given.
    public var onRefresh: (() async -> Void)?
    /// A post; `isActive` is true while it is the one on screen.
    public var content: (Item, Bool) -> Content

    public init(
        items: [Item],
        activeID: Binding<Item.ID?>,
        lookahead: Int = 4,
        loadMoreDistance: Int = 8,
        onUpcoming: @escaping ([Item]) -> Void = { _ in },
        onActiveChanged: @escaping (Item?) -> Void = { _ in },
        onNearEnd: @escaping () -> Void = {},
        onRefresh: (() async -> Void)? = nil,
        @ViewBuilder content: @escaping (Item, Bool) -> Content
    ) {
        self.items = items
        _activeID = activeID
        self.lookahead = lookahead
        self.loadMoreDistance = loadMoreDistance
        self.onUpcoming = onUpcoming
        self.onActiveChanged = onActiveChanged
        self.onNearEnd = onNearEnd
        self.onRefresh = onRefresh
        self.content = content
    }

    public func makeUIViewController(context: Context) -> FeedPagerController<Item, Content> {
        FeedPagerController(pager: self)
    }

    public func updateUIViewController(_ controller: FeedPagerController<Item, Content>, context: Context) {
        controller.update(self)
    }
}

// Activity is SwiftUI state, not a collection snapshot change. Reconfiguring
// cells on every scroll threshold prevents UIKit from promptly recycling them.
@MainActor
private final class FeedActivity<ID: Hashable>: ObservableObject {
    @Published var activeID: ID?
}

private struct FeedPostContent<Item: Identifiable, Content: View>: View where Item.ID: Hashable {
    let item: Item
    @ObservedObject var activity: FeedActivity<Item.ID>
    let content: (Item, Bool) -> Content

    var body: some View { content(item, item.id == activity.activeID) }
}

/// The UIKit side of `FeedPager`.
@MainActor
public final class FeedPagerController<Item: Identifiable, Content: View>: UIViewController, UICollectionViewDelegate where Item.ID: Hashable & Sendable {
    private var pager: FeedPager<Item, Content>
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item.ID>!
    private var itemsByID: [Item.ID: Item] = [:]
    private var order: [Item.ID] = []
    private var active: Item.ID?
    private let activity = FeedActivity<Item.ID>()
    private var lastUpcoming: [Item.ID] = []
    private var lastPublishedActive: Item.ID?

    init(pager: FeedPager<Item, Content>) {
        self.pager = pager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override public func viewDidLoad() {
        super.viewDidLoad()
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            return NSCollectionLayoutSection(group: group)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.isPagingEnabled = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.showsVerticalScrollIndicator = false
        collectionView.backgroundColor = .black
        collectionView.scrollsToTop = false
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "feedPager"
        view.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<UICollectionViewCell, Item.ID> { [weak self] cell, _, id in
            guard let self, let item = self.itemsByID[id] else { return }
            let activity = self.activity, content = self.pager.content
            cell.contentConfiguration = UIHostingConfiguration {
                // A new identity per post: a reused cell never keeps the
                // previous post's state (its picture or its player).
                FeedPostContent(item: item, activity: activity, content: content).id(id)
            }
            .margins(.all, 0)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Item.ID>(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        if pager.onRefresh != nil { addRefreshControl() }
        apply(pager.items)
    }

    func update(_ pager: FeedPager<Item, Content>) {
        self.pager = pager
        guard isViewLoaded else { return }
        if pager.onRefresh != nil, collectionView.refreshControl == nil { addRefreshControl() }
        apply(pager.items)
        if let wanted = pager.activeID, wanted != active, wanted != lastPublishedActive,
           let index = order.firstIndex(of: wanted) {
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
            setActive(wanted)
        }
    }

    private func apply(_ items: [Item]) {
        var seen = Set<Item.ID>()
        let unique = items.filter { seen.insert($0.id).inserted }
        let ids = unique.map(\.id)
        itemsByID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item.ID>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        let sameOrder = ids == order
        order = ids
        if sameOrder {
            // Do not carry reconfiguration identifiers from older snapshots.
            let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            snapshot.reconfigureItems(visible)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        if active == nil || !ids.contains(active!) {
            setActive(currentID() ?? ids.first)
        } else {
            reportUpcoming()
        }
    }

    private func currentID() -> Item.ID? {
        let height = collectionView.bounds.height
        guard height > 0, !order.isEmpty else { return nil }
        let index = Int((collectionView.contentOffset.y / height).rounded())
        return order[max(0, min(index, order.count - 1))]
    }

    private func setActive(_ id: Item.ID?) {
        guard id != active else { return }
        active = id
        activity.activeID = id
        pager.onActiveChanged(id.flatMap { itemsByID[$0] })
        if pager.activeID != id {
            // Not during a SwiftUI update.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active == id else { return }
                self.lastPublishedActive = id
                self.pager.activeID = id
            }
        }
        reportUpcoming()
    }

    private func reportUpcoming() {
        guard let active, let index = order.firstIndex(of: active) else { return }
        let next = Array(order.dropFirst(index + 1).prefix(pager.lookahead))
        if next != lastUpcoming {
            lastUpcoming = next
            pager.onUpcoming(next.compactMap { itemsByID[$0] })
        }
        if index >= order.count - 1 - pager.loadMoreDistance { pager.onNearEnd() }
    }

    // MARK: - Scrolling

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard dataSource != nil else { return }
        setActive(currentID())
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        setActive(currentID())
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        setActive(currentID())
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { setActive(currentID()) }
    }

    // MARK: - Refresh

    private func addRefreshControl() {
        let control = UIRefreshControl()
        control.tintColor = .white
        control.addTarget(self, action: #selector(refresh), for: .valueChanged)
        collectionView.refreshControl = control
    }

    @objc private func refresh() {
        Task { [weak self] in
            await self?.pager.onRefresh?()
            self?.collectionView.refreshControl?.endRefreshing()
        }
    }
}
#endif
