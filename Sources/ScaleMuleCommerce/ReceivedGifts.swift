import SwiftUI
import CryptoKit
import ScaleMuleCore

/// Gifts other people sent to the signed-in person, and which of them the
/// person has not been shown yet. Start it after sign-in, refresh it once the
/// App Store environment is known and whenever the app returns to the
/// foreground, and stop it on sign-out. What was already shown is remembered on
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

    /// A person's gift history lists sent and received gifts together, so a few
    /// pages are read to find the received ones.
    static let pageLimit = 5

    public init(commerce: CommerceService, defaults: UserDefaults = .standard) {
        self.commerce = commerce
        self.defaults = defaults
    }

    public func start(userID: String) {
        stop()
        self.userID = userID
    }

    public func stop() {
        generation = UUID(); userID = nil; environment = nil; loading = false
        gifts = []; unseen = []; hasLoaded = false; errorMessage = nil
    }

    public func refresh(environment: CommerceEnvironment) async {
        guard let userID, !loading else { return }
        let run = generation
        loading = true
        defer { if generation == run { loading = false } }
        var all: [DigitalGift] = []
        var before: String?
        var failure: String?
        pages: for _ in 0..<Self.pageLimit {
            let response = await commerce.history(environment: environment, before: before)
            guard generation == run, !Task.isCancelled else { return }
            switch response {
            case .success(let page):
                all += page
                before = page.last?.id
                if page.count < 30 || before == nil { break pages }
            case .failure(let error):
                failure = error.message
                break pages
            }
        }
        // A failed first page keeps what is already shown.
        if all.isEmpty, let failure {
            errorMessage = failure
            return
        }
        self.environment = environment
        gifts = Self.received(all, userID: userID)
        unseen = Self.unseen(gifts, after: defaults.string(forKey: seenKey(userID: userID, environment: environment)))
        hasLoaded = true
        errorMessage = nil
    }

    /// Call when the person has been shown the new gifts.
    public func markSeen() {
        defer { unseen = [] }
        guard let userID, let environment, let newest = gifts.first else { return }
        let key = seenKey(userID: userID, environment: environment)
        if let stored = defaults.string(forKey: key), stored.lowercased() >= newest.id.lowercased() { return }
        defaults.set(newest.id, forKey: key)
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

/// Every gift the person has received, with who sent it. The host resolves a
/// sender's public name and photo; an unresolved sender shows as "Someone".
public struct ReceivedGiftsView: View {
    @ObservedObject private var model: ReceivedGiftsModel
    private let person: @MainActor (String) async -> GiftRecipient?
    @State private var people: [String: GiftRecipient] = [:]
    @State private var viewed: DigitalGift?

    public init(model: ReceivedGiftsModel, person: @escaping @MainActor (String) async -> GiftRecipient?) {
        self.model = model
        self.person = person
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !model.hasLoaded, let error = model.errorMessage {
                    Text("Your gifts couldn’t load").font(.title2.bold())
                    Text(error).foregroundStyle(.secondary).padding(.top, 4)
                } else if !model.hasLoaded {
                    ProgressView("Loading your gifts…").frame(maxWidth: .infinity, minHeight: 160)
                } else if model.gifts.isEmpty {
                    Text("No gifts yet").font(.title2.bold())
                    Text("Gifts people send you will appear here.").foregroundStyle(.secondary).padding(.top, 4)
                } else {
                    ForEach(model.gifts) { gift in
                        Button { viewed = gift } label: { row(gift) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("receivedGift")
                        Divider()
                    }
                }
            }.padding(24)
        }
        .navigationTitle("Gifts you received")
        .task(id: model.gifts.map(\.id)) { await resolvePeople(model.gifts) }
        // Looking at the list is seeing the gifts, including ones that load while it is open.
        .onAppear { model.markSeen() }
        .onChange(of: model.gifts.first?.id) { _ in model.markSeen() }
        .sheet(item: $viewed) { gift in
            GiftPresentationView(gift: gift.productSnapshot, title: "From \(name(gift))")
        }
    }

    private func row(_ gift: DigitalGift) -> some View {
        HStack(spacing: 14) {
            GiftArtwork(url: gift.productSnapshot.artworkURL).frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(gift.quantity > 1 ? "\(gift.productSnapshot.displayName) × \(gift.quantity)" : gift.productSnapshot.displayName)
                    .font(.headline).foregroundStyle(.primary)
                Text(GiftText.from(name(gift), date: gift.arrivedDate)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func name(_ gift: DigitalGift) -> String { people[gift.senderID]?.name ?? "Someone" }

    private func resolvePeople(_ gifts: [DigitalGift]) async {
        for id in Set(gifts.map(\.senderID)) where people[id] == nil {
            if let found = await person(id) { people[id] = found }
        }
    }
}

/// Shown once when new gifts have arrived: the newest gift, who sent it, and a
/// way to the full list. Call `markSeen()` on the model when it is dismissed.
public struct GiftArrivalView: View {
    private let gifts: [DigitalGift]
    private let person: @MainActor (String) async -> GiftRecipient?
    private let seeAll: (() -> Void)?
    @State private var sender: GiftRecipient?
    @Environment(\.dismiss) private var dismiss

    /// `gifts` are the unseen gifts, newest first.
    public init(gifts: [DigitalGift], person: @escaping @MainActor (String) async -> GiftRecipient?, seeAll: (() -> Void)? = nil) {
        self.gifts = gifts
        self.person = person
        self.seeAll = seeAll
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let gift = gifts.first {
                    Text(gifts.count > 1 ? "You received \(gifts.count) gifts" : "You received a gift").font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    GiftArtwork(url: gift.productSnapshot.artworkURL).frame(maxWidth: 260, maxHeight: 260)
                    Text(GiftText.sent(sender?.name ?? "Someone", gift: gift.productSnapshot.displayName))
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        .accessibilityIdentifier("giftArrivalSentence")
                    if gifts.count > 1 {
                        Text(gifts.count == 2 ? "and 1 more gift" : "and \(gifts.count - 1) more gifts").foregroundStyle(.secondary)
                    }
                    Text("It’s yours to keep.").foregroundStyle(.secondary)
                    if let seeAll {
                        Button("See your gifts") { dismiss(); seeAll() }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("giftArrivalSeeAll")
                    }
                }
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { if let id = gifts.first?.senderID { sender = await person(id) } }
        }
    }
}

enum GiftText {
    static func sent(_ name: String, gift: String) -> String {
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
