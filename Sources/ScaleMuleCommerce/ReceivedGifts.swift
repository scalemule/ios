import SwiftUI
import CryptoKit
import ScaleMuleCore

/// Gifts other people sent to the signed-in person, and which of them the
/// person has not been shown yet. Start it with the wallet ledger after sign-in,
/// refresh whenever the ledger changes or the app returns to the foreground,
/// and stop it on sign-out. What was already shown is remembered on
/// the device per app key, user and environment.
@MainActor
public final class ReceivedGiftsModel: ObservableObject {
    /// Delivered gifts sent to this person, newest first.
    @Published public private(set) var gifts: [DigitalGift] = []
    /// The ones that arrived since the person last looked, newest first.
    @Published public private(set) var unseen: [DigitalGift] = []
    @Published public private(set) var hasLoaded = false
    @Published public private(set) var errorMessage: String?
    private let commerce: CommerceService
    private let defaults: UserDefaults
    private var userID: String?
    private var environment: CommerceEnvironment?
    private var generation = UUID()
    private var loading = false

    @Published public private(set) var isLoading = false
    @Published public private(set) var hasMore = false
    private var cursor: String?
    private var seenIDs = Set<String>()
    // Bound each request burst, but allow the collection to page without a total cap.
    static let pageLimit = 5

    public init(commerce: CommerceService, defaults: UserDefaults = .standard) {
        self.commerce = commerce
        self.defaults = defaults
    }

    public func start(userID: String, environment: CommerceEnvironment = .production) {
        stop()
        self.userID = userID
        self.environment = environment
        seenIDs = Set(defaults.stringArray(forKey: seenKey(userID: userID, environment: environment) + ".ids") ?? [])
    }

    public func stop() {
        generation = UUID(); userID = nil; environment = nil; loading = false; isLoading = false
        cursor = nil; hasMore = false; seenIDs = []
        gifts = []; unseen = []; hasLoaded = false; errorMessage = nil
    }

    public func refresh(environment: CommerceEnvironment) async {
        guard let userID else { return }
        if self.environment != environment {
            generation = UUID(); loading = false; isLoading = false
            gifts = []; unseen = []; cursor = nil; hasMore = false; hasLoaded = false
            self.environment = environment
            seenIDs = Set(defaults.stringArray(forKey: seenKey(userID: userID, environment: environment) + ".ids") ?? [])
        }
        await fetch(older: false)
    }

    public func refresh() async {
        guard let environment else { errorMessage = "Sign in to see your gifts."; return }
        await refresh(environment: environment)
    }

    public func loadMore() async {
        guard hasMore else { return }
        await fetch(older: true)
    }

    private func fetch(older: Bool) async {
        guard let userID, let environment, !loading else { return }
        let run = generation
        loading = true; isLoading = true; errorMessage = nil
        defer { if generation == run { loading = false; isLoading = false } }
        var all: [DigitalGift] = []
        var before = older ? cursor : nil
        var more = false
        var completedPage = false
        for _ in 0..<Self.pageLimit {
            let response = await commerce.history(environment: environment, before: before)
            guard generation == run, !Task.isCancelled else { return }
            switch response {
            case .success(let page):
                completedPage = true
                all += page
                let next = page.last?.id
                more = page.count == 30 && next != nil && next != before
                before = next
            case .failure(let error):
                errorMessage = error.message
                // Keep the successful prefix and its cursor so the user can retry.
                more = true
            }
            if errorMessage != nil || !more || Self.received(all, userID: userID).count >= 30 { break }
        }
        guard completedPage else { return }
        if older {
            gifts = Self.received(gifts + all, userID: userID)
            cursor = before; hasMore = more
        } else {
            // A refresh must not throw away older pages already browsed. Replace
            // the refreshed range so changed/refunded gifts do not linger there.
            let retained = more ? gifts.filter { $0.id.lowercased() < (before ?? "").lowercased() } : []
            gifts = Self.received(all + retained, userID: userID)
            if retained.isEmpty { cursor = before; hasMore = more }
        }
        hasLoaded = true
        updateUnseen()
    }

    /// Acknowledge only the gifts actually presented. A later arrival stays new.
    public func markSeen(giftIDs: [String]? = nil) {
        guard let userID, let environment else { return }
        seenIDs.formUnion((giftIDs ?? gifts.map(\.id)).map { $0.lowercased() })
        // Only recent gifts are announced. Keep a bounded acknowledgement record.
        seenIDs = Set(seenIDs.sorted(by: >).prefix(2048))
        defaults.set(Array(seenIDs), forKey: seenKey(userID: userID, environment: environment) + ".ids")
        updateUnseen()
    }

    private func updateUnseen() {
        guard let userID, let environment else { return }
        let legacyWatermark = defaults.string(forKey: seenKey(userID: userID, environment: environment))
        unseen = Self.unseen(Array(gifts.prefix(150)), after: legacyWatermark)
            .filter { !seenIDs.contains($0.id.lowercased()) }
    }

    /// Delivered gifts from someone else to this person, newest first. Gift ids
    /// are time-ordered, so sorting by id is sorting by time.
    static func received(_ all: [DigitalGift], userID: String) -> [DigitalGift] {
        let me = identity(userID)
        var seen = Set<String>()
        return all
            .filter { $0.isDelivered && identity($0.recipientID) == me && identity($0.senderID) != me && seen.insert($0.id.lowercased()).inserted }
            .sorted { $0.id.lowercased() > $1.id.lowercased() }
    }

    static func unseen(_ received: [DigitalGift], after seenID: String?) -> [DigitalGift] {
        guard let seenID, !seenID.isEmpty else { return received }
        let seen = seenID.lowercased()
        return received.filter { $0.id.lowercased() > seen }
    }

    private static func identity(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func seenKey(userID: String, environment: CommerceEnvironment) -> String {
        let namespace = commerce.client.configuration.apiKey + ":" + Self.identity(userID) + ":" + environment.rawValue
        let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        return "scalemule.commerce.gifts.seen." + digest
    }
}

extension DigitalGift {
    /// When the gift arrived (or was sent, if delivery time is missing).
    public var arrivedDate: Date? { Self.date(deliveredAt ?? createdAt) }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        // Other fraction lengths: drop the fraction and read whole seconds.
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }
}

/// A permanent, paginated collection, with the sender on every gift.
public struct ReceivedGiftsView: View {
    @ObservedObject private var model: ReceivedGiftsModel
    private let person: @MainActor (String) async -> GiftRecipient?
    @State private var people: [String: GiftRecipient] = [:]
    @State private var viewed: DigitalGift?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(model: ReceivedGiftsModel, person: @escaping @MainActor (String) async -> GiftRecipient?) {
        self.model = model
        self.person = person
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.isLoading && !model.hasLoaded {
                    ProgressView("Loading your gifts…").frame(maxWidth: .infinity, minHeight: 160)
                } else if model.hasLoaded, model.gifts.isEmpty {
                    ReceivedGiftEmptyState(hasMore: model.hasMore)
                } else if !model.gifts.isEmpty {
                    Text("From people who appreciate your moments.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        ForEach(model.gifts) { gift in
                            Button { viewed = gift } label: {
                                ReceivedGiftCard(gift: gift, sender: people[gift.senderID]) {
                                    GiftArtwork(url: gift.productSnapshot.artworkURL)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("receivedGift")
                            .task {
                                if people[gift.senderID] == nil, let found = await person(gift.senderID), !Task.isCancelled {
                                    people[gift.senderID] = found
                                }
                            }
                        }
                    }
                }
                if let error = model.errorMessage {
                    GiftNotice(text: error, isError: true)
                    Button("Try again") { Task { await model.refresh() } }.buttonStyle(GiftOutlineButtonStyle())
                }
                if model.hasMore {
                    Button { Task { await model.loadMore() } } label: {
                        if model.isLoading { ProgressView() } else { Text("Load older gifts") }
                    }.buttonStyle(GiftOutlineButtonStyle()).disabled(model.isLoading)
                        .frame(maxWidth: .infinity).accessibilityIdentifier("receivedGiftsMore")
                }
            }.padding(18)
        }
        .navigationTitle("Your gifts")
        .giftInlineNavigation()
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .onAppear { model.markSeen() }
        .onChange(of: model.gifts.map(\.id)) { _ in model.markSeen() }
        .sheet(item: $viewed) { gift in
            GiftArrivalView(gifts: [gift], person: person, isNew: false)
        }
    }
}

struct ReceivedGiftEmptyState: View {
    var hasMore = false
    @Environment(\.giftTheme) private var theme
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gift").font(.system(size: 46, weight: .light))
                .foregroundStyle(theme.accent).frame(width: 100, height: 100)
                .background(theme.accent.opacity(0.08), in: Circle())
            Text(hasMore ? "Find your earlier gifts" : "No gifts yet").font(.title2.weight(.bold))
            Text(hasMore ? "Load older gifts to see what people sent you." : "When someone sends you a gift, it’s yours to keep. You’ll see who sent it here.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }.frame(maxWidth: .infinity).padding(.vertical, 48)
    }
}

struct ReceivedGiftCard<Artwork: View>: View {
    let gift: DigitalGift
    let sender: GiftRecipient?
    @ViewBuilder var artwork: Artwork
    @Environment(\.giftTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            artwork.frame(height: 126).frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                Text(gift.quantity > 1 ? "\(gift.productSnapshot.displayName) × \(gift.quantity)" : gift.productSnapshot.displayName)
                    .font(.system(.headline, design: .rounded)).foregroundStyle(.primary)
                HStack(spacing: 6) {
                    GiftPersonAvatar(person: sender).frame(width: 24, height: 24)
                    Text("From \(sender?.name ?? "Someone")")
                        .font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                }
                if let date = gift.arrivedDate {
                    Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct GiftPersonAvatar: View {
    let person: GiftRecipient?
    @Environment(\.giftTheme) private var theme
    var body: some View {
        Group {
            if let url = person?.avatarURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            } else { placeholder }
        }.clipShape(Circle()).accessibilityHidden(true)
    }
    private var placeholder: some View {
        Text(person?.name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(.caption, design: .rounded).bold())
            .foregroundStyle(theme.onAccent)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.accent)
    }
}

/// The arrival and the permanent detail share the same gift, sender and date.
public struct GiftArrivalView: View {
    private let gifts: [DigitalGift]
    private let person: @MainActor (String) async -> GiftRecipient?
    private let seeAll: (() -> Void)?
    private let isNew: Bool
    @State private var sender: GiftRecipient?
    @Environment(\.dismiss) private var dismiss

    public init(gifts: [DigitalGift], person: @escaping @MainActor (String) async -> GiftRecipient?,
                isNew: Bool = true, seeAll: (() -> Void)? = nil) {
        self.gifts = gifts; self.person = person; self.isNew = isNew; self.seeAll = seeAll
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                if let gift = gifts.first {
                    GiftMomentContent(gift: gift, sender: sender, isNew: isNew, additionalCount: gifts.count - 1) {
                        GiftArtwork(url: gift.productSnapshot.artworkURL)
                    }
                    .padding(24)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let seeAll {
                    Button("See your gifts") { dismiss(); seeAll() }.buttonStyle(GiftPrimaryButtonStyle())
                        .accessibilityIdentifier("giftArrivalSeeAll").padding(20)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationTitle("A gift for you").giftInlineNavigation()
            .task { if let id = gifts.first?.senderID { sender = await person(id) } }
        }
    }
}

struct GiftMomentContent<Artwork: View>: View {
    let gift: DigitalGift
    let sender: GiftRecipient?
    let isNew: Bool
    var additionalCount = 0
    @ViewBuilder var artwork: Artwork

    var body: some View {
        VStack(spacing: 16) {
            GiftPersonAvatar(person: sender).frame(width: 64, height: 64)
            Text(isNew ? "You received a gift." : "A gift from \(sender?.name ?? "Someone")")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(GiftText.sent(sender?.name ?? "Someone", gift: gift.productSnapshot.displayName, quantity: gift.quantity))
                .font(.title3).multilineTextAlignment(.center)
                .accessibilityIdentifier("giftArrivalSentence")
            artwork.frame(height: 240).frame(maxWidth: .infinity).padding(.vertical, 8)
            Text(gift.productSnapshot.displayName).font(.system(.title, design: .rounded).bold())
            if let date = gift.arrivedDate {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if additionalCount > 0 {
                Text(additionalCount == 1 ? "And 1 more gift is waiting for you." : "And \(additionalCount) more gifts are waiting for you.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.frame(maxWidth: .infinity)
    }
}

enum GiftText {
    static func sent(_ name: String, gift: String, quantity: Int = 1) -> String {
        if quantity > 1 { return "\(name) sent you \(quantity) × \(gift)" }
        let article = gift.first.map { "aeiouAEIOU".contains($0) } == true ? "an" : "a"
        // "The World" reads better without an article.
        return gift.lowercased().hasPrefix("the ") ? "\(name) sent you \(gift)" : "\(name) sent you \(article) \(gift)"
    }

    static func from(_ name: String, date: Date?, now: Date = Date()) -> String {
        guard let date else { return "From \(name)" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // A clock a little behind the server must not say "in 2 seconds".
        let when = date > now ? "just now" : formatter.localizedString(for: date, relativeTo: now)
        return "From \(name) · \(when)"
    }
}
