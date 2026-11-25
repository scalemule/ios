import SwiftUI
import AVKit
import ScaleMuleCore

/// Native gift picker. Pass the authenticated recipient's ID, never an email.
/// The host app owns sign-in and starts/stops both stores with that session.
public struct GiftPickerView: View {
    @ObservedObject private var store: AppleGiftStore
    @ObservedObject private var delivery: GiftDeliveryStore
    @State private var recipient: GiftRecipient?
    private let loadRecipients: (@MainActor () async throws -> [GiftRecipient])?
    private let contextType: String?
    private let contextID: String?
    @State private var products: [GiftProduct] = []
    @State private var balance: CommerceBalance?
    @State private var selected: String?
    @State private var error: String?
    @State private var loading = true
    @State private var showWallet = false
    @State private var showDelivery = false
    @State private var hasMore = false
    @State private var showRecipients = false
    @State private var productCursor: String?

    public init(store: AppleGiftStore, delivery: GiftDeliveryStore, recipientID: String, recipientName: String,
                contextType: String? = nil, contextID: String? = nil) {
        self.store=store;self.delivery=delivery
        self._recipient = State(initialValue: GiftRecipient(id: recipientID, name: recipientName))
        self.loadRecipients = nil
        self.contextType=contextType;self.contextID=contextID
    }
    /// Opens the catalog before a recipient is chosen. The host supplies real,
    /// authorized recipients from its social graph; browsing never spends credits.
    public init(store: AppleGiftStore, delivery: GiftDeliveryStore,
                loadRecipients: @escaping @MainActor () async throws -> [GiftRecipient]) {
        self.store = store; self.delivery = delivery
        self._recipient = State(initialValue: nil)
        self.loadRecipients = loadRecipients
        self.contextType = nil; self.contextID = nil
    }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make their moment.").font(.largeTitle.bold())
                    Text(recipient.map { "Send a gift to \($0.name). It’s theirs to keep." }
                         ?? "Pick a gift, choose someone, and make their day.").foregroundStyle(.secondary)
                    if loadRecipients != nil {
                        Button { showRecipients = true } label: {
                            Label(recipient.map { "To: \($0.name) · Change" } ?? "Choose who to send it to", systemImage: "person.crop.circle")
                        }.buttonStyle(.bordered).disabled(delivery.isSending)
                            .accessibilityIdentifier("giftChooseRecipient")
                    }
                }
                HStack {
                    Label(balance.map { "\($0.availableMinor) credits" } ?? "Your credits", systemImage: "sparkle").font(.headline)
                    Spacer()
                    Button("Get credits") { showWallet = true }.buttonStyle(.bordered)
                }
                if store.environment == .sandbox { Text("Sandbox · test credits only").font(.caption).foregroundStyle(.secondary) }
                if store.needsAppStoreConnection {
                    Text(store.message ?? "Connect to the App Store to load gifts.").foregroundStyle(.secondary)
                    Button("Connect to App Store") { Task { await store.connectToAppStore(); await load() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLoading)
                }
                else if loading || store.isLoading { ProgressView("Loading gifts…").frame(maxWidth: .infinity, minHeight: 160) }
                else if let error, products.isEmpty {
                    Text("Gifts couldn’t load").font(.title2.bold())
                    Text(error).foregroundStyle(.secondary)
                    Button("Try again") { Task { await load() } }
                }
                else if products.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Gifts are on their way.").font(.title2.bold())
                        Text("There aren’t any gifts available to send yet.").foregroundStyle(.secondary)
                        Button("Refresh") { Task { await load() } }
                    }.padding(.vertical, 36)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 24) {
                        ForEach(products) { product in
                            Button { selected = product.id } label: {
                                VStack(spacing: 10) {
                                    GiftArtwork(url: product.artworkURL).frame(height: 112)
                                    Text(product.displayName).font(.headline).foregroundStyle(.primary)
                                    Text("\(product.unitPriceMinor) credits").font(.subheadline).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity).padding(12)
                                .background(selected == product.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 22))
                                .overlay(RoundedRectangle(cornerRadius: 22).stroke(selected == product.id ? Color.accentColor : .clear, lineWidth: 2))
                            }.buttonStyle(.plain)
                            .accessibilityLabel("\(product.displayName), \(product.unitPriceMinor) credits")
                            .accessibilityAddTraits(selected == product.id ? .isSelected : [])
                        }
                    }
                }
                if hasMore { Button("More gifts") { Task { await moreProducts() } } }
                if let message = delivery.message { Text(message).font(.callout).accessibilityAddTraits(.updatesFrequently) }
                if !delivery.pending.isEmpty { Button("Retry gift delivery") { Task { await delivery.retryPending(); await refreshBalance() } }.disabled(delivery.isSending) }
                if let error, !products.isEmpty { Text(error).foregroundStyle(.red) }
                Text("Gifts are digital items. Credits and gifts cannot be exchanged for cash.").font(.footnote).foregroundStyle(.secondary)
            }.padding(24)
        }
        .navigationTitle(loadRecipients == nil ? "Send a gift" : "Gift shop")
        .safeAreaInset(edge: .bottom) { sendControls }
        .task { await load() }
        .onChange(of: store.fulfillmentRevision) { _ in Task { await refreshBalance() } }
        .onChange(of: store.environment) { value in if value != nil { Task { await load() } } }
        .onChange(of: delivery.lastDelivered?.id) { _ in
            if let recipient, delivery.lastDelivered?.recipientID == recipient.id { showDelivery = true }
        }
        .sheet(isPresented: $showDelivery) {
            if let gift = delivery.lastDelivered { GiftPresentationView(gift: gift.productSnapshot, title: "Gift sent to \(recipient?.name ?? "recipient")") }
        }
        .sheet(isPresented: $showWallet) { NavigationStack { CommerceWalletView(store: store) } }
        .sheet(isPresented: $showRecipients) {
            if let loadRecipients {
                GiftRecipientPicker(load: loadRecipients) { recipient = $0 }
            }
        }
    }
    @ViewBuilder private var sendControls: some View {
        if let product = products.first(where: { $0.id == selected }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(product.description).font(.subheadline).foregroundStyle(.secondary)
                if let recipient {
                    Button {
                        guard let environment = store.environment else { return }
                        Task {
                            await delivery.send(product: product, recipientID: recipient.id, environment: environment,
                                                contextType: contextType, contextID: contextID)
                            await refreshBalance()
                        }
                    } label: {
                        HStack {
                            if delivery.isSending { ProgressView() }
                            Text(delivery.isSending ? "Sending…" : "Send \(product.displayName) to \(recipient.name) · \(product.unitPriceMinor) credits")
                                .fontWeight(.semibold)
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("giftConfirmSend")
                        .disabled(delivery.isSending || store.environment == nil || (balance?.availableMinor ?? 0) < product.unitPriceMinor)
                } else {
                    Button("Choose recipient for \(product.displayName)") { showRecipients = true }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                }
                if (balance?.availableMinor ?? 0) < product.unitPriceMinor {
                    Button("Get more credits") { showWallet = true }.font(.footnote)
                }
                if let message = delivery.message { Text(message).font(.footnote) }
            }.padding(16).frame(maxWidth: .infinity).background(.regularMaterial)
        }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        if store.environment == nil && !store.isLoading && !store.needsAppStoreConnection { await store.start() }
        guard let environment = store.environment else { error = store.message; return }
        async let items = store.commerce.products(environment: environment)
        async let wallet = store.commerce.balance(environment: environment)
        switch await items { case .success(let value): productCursor = value.last?.id; products = ordered(value); hasMore = value.count == 30; case .failure(let failure): error = failure.message }
        if case .success(let value) = await wallet { balance = value }
    }
    private func moreProducts() async {
        guard let environment = store.environment, let cursor = productCursor else { return }
        switch await store.commerce.products(environment: environment, before: cursor) {
        case .success(let next): productCursor = next.last?.id; products = ordered(products + next); hasMore = next.count == 30
        case .failure(let failure): error = failure.message
        }
    }
    private func ordered(_ items: [GiftProduct]) -> [GiftProduct] {
        items.sorted { $0.unitPriceMinor == $1.unitPriceMinor ? $0.id < $1.id : $0.unitPriceMinor < $1.unitPriceMinor }
    }
    private func refreshBalance() async {
        guard let environment = store.environment else { return }
        if case .success(let value) = await store.commerce.balance(environment: environment) { balance = value }
    }
}

public struct CommerceWalletView: View {
    @ObservedObject private var store: AppleGiftStore
    @State private var inventory: [GiftInventoryItem] = []
    @State private var viewedGift: GiftInventoryItem?
    @State private var hasMore = false
    @State private var balance: CommerceBalance?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    public init(store: AppleGiftStore) { self.store = store }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your credits").font(.headline).foregroundStyle(.secondary)
                    Text(balance.map { String($0.availableMinor) } ?? "—").font(.system(size: 52, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("For little gifts that make a big moment.").foregroundStyle(.secondary)
                }
                if store.environment == .sandbox { Text("Sandbox · purchases use test credits").font(.footnote).foregroundStyle(.secondary) }
                if store.isLoading { ProgressView("Loading credit packs…") }
                ForEach(store.offers) { offer in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(offer.pack.creditsPerUnit) credits").font(.title3.bold())
                            Text(offer.pack.displayName).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(offer.displayPrice) { Task { await store.purchase(offer) } }.buttonStyle(.borderedProminent)
                            .disabled(store.isPurchasing || !store.enabled)
                            .accessibilityLabel("Buy \(offer.pack.creditsPerUnit) credits for \(offer.displayPrice)")
                    }.padding(.vertical, 10)
                    Divider()
                }
                if store.offers.isEmpty && !store.isLoading && store.message == nil { Text("Credit packs are not available yet.").foregroundStyle(.secondary) }
                if let message = store.message { Text(message).font(.callout) }
                if store.needsAppStoreConnection {
                    Button("Connect to App Store") { Task { await store.connectToAppStore(); await refresh() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLoading || store.isPurchasing)
                        .accessibilityIdentifier("commerceConnectAppStore")
                } else if store.offers.isEmpty && !store.isLoading {
                    Button("Reload credit packs") { Task { await store.start(); await refresh() } }
                        .disabled(store.isPurchasing)
                }
                Button("Check pending purchases") { Task { await store.retryUnfinished(); await refresh() } }
                    .disabled(store.isLoading || store.isPurchasing || store.environment == nil)
                Text("Payments are handled by Apple. Credits do not expire and cannot be transferred or withdrawn as cash.").font(.footnote).foregroundStyle(.secondary)
                Text("Your gifts").font(.title2.bold()).padding(.top, 8)
                if inventory.isEmpty { Text("Gifts people send you will appear here.").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 20) {
                    ForEach(inventory) { item in
                        Button { viewedGift = item } label: {
                            VStack(spacing: 8) {
                                GiftArtwork(url: item.productSnapshot.artworkURL).frame(height: 110)
                                Text(item.productSnapshot.displayName).font(.headline)
                                Text("\(item.availableQuantity) owned").font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if hasMore { Button("More received gifts") { Task { await moreInventory() } } }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(24)
        }.navigationTitle("Credits & gifts")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task { if store.environment == nil && !store.isLoading && !store.needsAppStoreConnection { await store.start() }; await refresh() }
        .onChange(of: store.fulfillmentRevision) { _ in Task { await refresh() } }
        .onChange(of: store.environment) { value in if value != nil { Task { await refresh() } } }
        .sheet(item: $viewedGift) { item in GiftPresentationView(gift: item.productSnapshot, title: "Your gift") }
    }
    private func moreInventory() async {
        guard let environment = store.environment, let last = inventory.last else { return }
        switch await store.commerce.inventory(environment: environment, before: last.id) {
        case .success(let next): inventory += next; hasMore = next.count == 30
        case .failure(let failure): error = failure.message
        }
    }
    private func refresh() async {
        guard let environment = store.environment else { return }
        async let wallet = store.commerce.balance(environment: environment)
        async let owned = store.commerce.inventory(environment: environment)
        switch await wallet { case .success(let value): balance=value; case .failure(let failure): error=failure.message }
        switch await owned { case .success(let value): inventory=value; hasMore = value.count == 30; case .failure(let failure): error=failure.message }
    }
}

struct GiftArtwork: View {
    let url: URL
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFit()
            case .failure: Image(systemName: "gift").resizable().scaledToFit().padding(28).foregroundStyle(.secondary)
            default: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.accessibilityHidden(true)
    }
}

/// Shared artwork presentation for gifts and reactions. Motion is opt-in and
/// never hides the still image before a video is ready. Viewing is not consuming.
public struct GiftPresentationView: View {
    private let gift: GiftSnapshot
    private let title: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer?
    public init(gift: GiftSnapshot, title: String = "Your gift") { self.gift = gift; self.title = title }
    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(gift.displayName).font(.largeTitle.bold())
                GiftArtwork(url: gift.artworkURL).frame(maxWidth: 300, maxHeight: 300)
                if let player { VideoPlayer(player: player).frame(height: 220) }
                else if let animation = gift.animationURL, !reduceMotion {
                    Button("Play gift animation") {
                        let video = AVPlayer(url: animation); video.isMuted = true; player = video; video.play()
                    }.buttonStyle(.bordered)
                }
                Text("A little appreciation, yours to keep.").foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }.onDisappear { player?.pause(); player = nil }
    }
}
