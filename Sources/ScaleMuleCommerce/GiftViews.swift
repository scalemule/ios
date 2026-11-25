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
    @State private var catalogLoad = UUID()
    @Environment(\.giftTheme) private var theme

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
            VStack(alignment: .leading, spacing: 16) {
                if loadRecipients != nil {
                    Button { showRecipients = true } label: { GiftRecipientRow(recipient: recipient, canChange: true) }
                        .buttonStyle(.plain).disabled(delivery.isSending)
                        .accessibilityIdentifier("giftChooseRecipient")
                } else {
                    GiftRecipientRow(recipient: recipient)
                }
                balanceRow
                if let message = delivery.message { GiftNotice(text: message).accessibilityAddTraits(.updatesFrequently) }
                if !delivery.pending.isEmpty {
                    Button("Retry gift delivery") { Task { await delivery.retryPending(); await refreshBalance() } }
                        .buttonStyle(GiftOutlineButtonStyle()).disabled(delivery.isSending)
                }
                if loading && products.isEmpty { ProgressView("Loading gifts…").frame(maxWidth: .infinity, minHeight: 200) }
                else if let error, products.isEmpty {
                    emptyState(title: "Gifts couldn’t load", text: error, action: "Try again")
                }
                else if products.isEmpty {
                    emptyState(title: "No gifts yet", text: "There aren’t any gifts to send right now.", action: "Refresh")
                } else {
                    Text("Choose a gift").font(.title3.bold()).padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(products) { product in
                            Button { selected = product.id } label: {
                                GiftCard(name: product.displayName, price: product.unitPriceMinor, isSelected: selected == product.id) {
                                    GiftArtwork(url: product.artworkURL)
                                }
                            }.buttonStyle(.plain)
                            .accessibilityLabel("\(product.displayName), \(product.unitPriceMinor) credits")
                            .accessibilityAddTraits(selected == product.id ? .isSelected : [])
                        }
                    }
                }
                if hasMore { Button("More gifts") { Task { await moreProducts() } }.buttonStyle(GiftOutlineButtonStyle()).frame(maxWidth: .infinity) }
                if let error, !products.isEmpty { GiftNotice(text: error, isError: true) }
                if store.needsAppStoreConnection {
                    Text("Browse gifts now. Apple will verify purchases when you get credits; your balance will appear once your account is verified.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Gifts are digital items. Credits and gifts cannot be exchanged for cash.").font(.footnote).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }.padding(.horizontal, 18).padding(.vertical, 16)
        }
        .navigationTitle(loadRecipients == nil ? "Send a gift" : "Gift shop")
        .safeAreaInset(edge: .bottom) { sendControls }
        .task { await load() }
        .onChange(of: store.fulfillmentRevision) { _ in Task { await refreshBalance() } }
        .onChange(of: store.environment) { _ in balance = nil; selected = nil; Task { await load() } }
        .onChange(of: delivery.lastDelivered?.id) { _ in
            if let recipient, delivery.lastDelivered?.recipientID == recipient.id { showDelivery = true }
        }
        .sheet(isPresented: $showDelivery) {
            if let gift = delivery.lastDelivered { GiftPresentationView(gift: gift.productSnapshot, title: "Gift sent to \(recipient?.name ?? "recipient")", message: "Delivered. You spent \(gift.totalMinor) credits.") }
        }
        .sheet(isPresented: $showWallet) { NavigationStack { CommerceWalletView(store: store) } }
        .sheet(isPresented: $showRecipients) {
            if let loadRecipients {
                GiftRecipientPicker(load: loadRecipients) { recipient = $0 }
            }
        }
    }
    /// The balance and the way to get more, in one row.
    private var balanceRow: some View {
        HStack(spacing: 10) {
            if let balance { CreditAmount(amount: balance.availableMinor, font: .title3.weight(.bold)) }
            Text(balance == nil ? "Your credits" : (balance?.availableMinor == 1 ? "credit" : "credits"))
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Get credits") { showWallet = true }.buttonStyle(GiftOutlineButtonStyle())
                .accessibilityIdentifier("giftGetCredits")
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    private func emptyState(title: String, text: String, action: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "gift").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action) { Task { await load() } }.buttonStyle(GiftOutlineButtonStyle()).padding(.top, 4)
        }.frame(maxWidth: .infinity).padding(.vertical, 36)
    }
    @ViewBuilder private var sendControls: some View {
        if let product = products.first(where: { $0.id == selected }) {
            let missing = product.unitPriceMinor - (balance?.availableMinor ?? 0)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    GiftArtwork(url: product.artworkURL).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(product.displayName).font(.headline)
                        Text(product.description).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    CreditAmount(amount: product.unitPriceMinor, font: .headline)
                }
                if let recipient {
                    if store.environment == nil {
                        Text("Continue with Apple to get credits or verify your existing balance.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Continue with Apple") { showWallet = true }.buttonStyle(GiftPrimaryButtonStyle())
                    } else if balance == nil {
                        GiftNotice(text: "Your credit balance couldn’t load. Try again before sending.", isError: true)
                        Button("Reload balance") { Task { await refreshBalance() } }.buttonStyle(GiftPrimaryButtonStyle())
                    } else if missing > 0 {
                        Text(missing == 1 ? "You need 1 more credit to send this." : "You need \(missing) more credits to send this.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Get credits") { showWallet = true }.buttonStyle(GiftPrimaryButtonStyle())
                            .accessibilityIdentifier("giftGetMoreCredits")
                    } else {
                        Button {
                            guard let environment = store.environment else { return }
                            Task {
                                await delivery.send(product: product, recipientID: recipient.id, environment: environment,
                                                    contextType: contextType, contextID: contextID)
                                await refreshBalance()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if delivery.isSending { ProgressView().tint(theme.onAccent) }
                                Text(delivery.isSending ? "Sending…" : "Send to \(recipient.name)")
                            }
                        }.buttonStyle(GiftPrimaryButtonStyle())
                            .accessibilityIdentifier("giftConfirmSend")
                            .accessibilityLabel("Send \(product.displayName) to \(recipient.name) for \(product.unitPriceMinor) credits")
                            .disabled(delivery.isSending || store.environment == nil || balance == nil)
                    }
                } else {
                    Button("Choose who gets it") { showRecipients = true }.buttonStyle(GiftPrimaryButtonStyle())
                }
            }.padding(16).frame(maxWidth: .infinity).background(.regularMaterial)
        }
    }
    private func load() async {
        let run = UUID(); catalogLoad = run
        loading = true; error = nil
        defer { if catalogLoad == run { loading = false } }
        let browsing = store.catalogEnvironment
        let items = await store.catalogProducts()
        guard catalogLoad == run, store.catalogEnvironment == browsing, !Task.isCancelled else { return }
        switch items { case .success(let value): productCursor = value.last?.id; products = ordered(value); hasMore = value.count == 30; case .failure(let failure): error = failure.message }
        await refreshBalance()
    }
    private func moreProducts() async {
        guard let cursor = productCursor else { return }
        let run = catalogLoad; let browsing = store.catalogEnvironment
        let response = await store.catalogProducts(before: cursor)
        guard run == catalogLoad, store.catalogEnvironment == browsing, !Task.isCancelled else { return }
        switch response {
        case .success(let next):
            productCursor = next.last?.id
            let existing = Set(products.map(\.id))
            products = ordered(products + next.filter { !existing.contains($0.id) }); hasMore = next.count == 30
        case .failure(let failure): error = failure.message
        }
    }
    private func ordered(_ items: [GiftProduct]) -> [GiftProduct] {
        items.sorted { $0.unitPriceMinor == $1.unitPriceMinor ? $0.id < $1.id : $0.unitPriceMinor < $1.unitPriceMinor }
    }
    private func refreshBalance() async {
        guard let environment = store.environment else { balance = nil; return }
        let response = await store.commerce.balance(environment: environment)
        guard store.environment == environment, !Task.isCancelled else { return }
        switch response { case .success(let value): balance = value; case .failure: balance = nil }
    }
}

public struct CommerceWalletView: View {
    @ObservedObject private var store: AppleGiftStore
    @State private var inventory: [GiftInventoryItem] = []
    @State private var viewedGift: GiftInventoryItem?
    @State private var hasMore = false
    @State private var balance: CommerceBalance?
    @State private var error: String?
    @State private var buying: String?
    @Environment(\.dismiss) private var dismiss
    public init(store: AppleGiftStore) { self.store = store }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CreditBalanceCard(credits: balance?.availableMinor, caption: "Use credits to send gifts.")
                Text("Get credits").font(.title3.bold()).padding(.top, 10)
                if store.isLoading && store.offers.isEmpty { ProgressView("Loading credit packs…").frame(maxWidth: .infinity, minHeight: 80) }
                ForEach(store.offers) { offer in
                    CreditPackRow(credits: offer.pack.creditsPerUnit, name: offer.pack.displayName, price: offer.displayPrice,
                                  isBuying: buying == offer.id) {
                        Task { buying = offer.id; await store.purchase(offer); buying = nil }
                    }
                    .disabled(store.isLoading || store.isPurchasing || !store.enabled)
                }
                if store.offers.isEmpty && !store.isLoading && store.message == nil {
                    Text("Credit packs are not available yet.").font(.subheadline).foregroundStyle(.secondary)
                }
                if let message = store.message { GiftNotice(text: message) }
                if store.needsAppStoreConnection {
                    Text("Choose a credit pack to continue with Apple. Already have credits? Check your Apple account to load your balance.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { Task { await store.connectToAppStore(); await refresh() } } label: {
                        HStack(spacing: 8) {
                            if store.isLoading { ProgressView() }
                            Text(store.isLoading ? "Checking Apple account…" : "Check Apple account")
                        }
                    }
                        .buttonStyle(GiftOutlineButtonStyle())
                        .disabled(store.isLoading || store.isPurchasing)
                        .accessibilityIdentifier("commerceConnectAppStore")
                } else if store.offers.isEmpty && !store.isLoading {
                    Button("Reload credit packs") { Task { await store.start(); await refresh() } }
                        .buttonStyle(GiftOutlineButtonStyle())
                        .disabled(store.isPurchasing)
                }
                Text("Your gifts").font(.title3.bold()).padding(.top, 14)
                if inventory.isEmpty {
                    Text("Gifts people send you will appear here.").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        ForEach(inventory) { item in
                            Button { viewedGift = item } label: {
                                GiftCard(name: item.productSnapshot.displayName, count: item.availableQuantity) {
                                    GiftArtwork(url: item.productSnapshot.artworkURL)
                                }
                            }.buttonStyle(.plain)
                            .accessibilityLabel("\(item.productSnapshot.displayName), \(item.availableQuantity) owned")
                        }
                    }
                }
                if hasMore { Button("More gifts") { Task { await moreInventory() } }.buttonStyle(GiftOutlineButtonStyle()).frame(maxWidth: .infinity) }
                if let error { GiftNotice(text: error, isError: true) }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Payments are handled by Apple. Credits do not expire and cannot be transferred or withdrawn as cash.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Missing a purchase? Check again") { Task { await store.retryUnfinished(); await refresh() } }
                        .font(.footnote.weight(.semibold))
                        .disabled(store.isLoading || store.isPurchasing || store.environment == nil)
                        .accessibilityIdentifier("commerceCheckPending")
                }.padding(.top, 14)
            }.padding(.horizontal, 18).padding(.vertical, 16)
        }.navigationTitle("Credits & gifts")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task { if store.environment == nil && !store.isLoading && !store.needsAppStoreConnection { await store.start() }; await refresh() }
        .onChange(of: store.fulfillmentRevision) { _ in Task { await refresh() } }
        .onChange(of: store.environment) { _ in balance = nil; inventory = []; hasMore = false; Task { await refresh() } }
        .sheet(item: $viewedGift) { item in GiftPresentationView(gift: item.productSnapshot, title: "Your gift") }
    }
    private func moreInventory() async {
        guard let environment = store.environment, let last = inventory.last else { return }
        let response = await store.commerce.inventory(environment: environment, before: last.id)
        guard store.environment == environment, !Task.isCancelled else { return }
        switch response {
        case .success(let next): inventory += next; hasMore = next.count == 30
        case .failure(let failure): error = failure.message
        }
    }
    private func refresh() async {
        guard let environment = store.environment else { balance = nil; inventory = []; return }
        async let wallet = store.commerce.balance(environment: environment)
        async let owned = store.commerce.inventory(environment: environment)
        let (walletResult, ownedResult) = await (wallet, owned)
        guard store.environment == environment, !Task.isCancelled else { return }
        error = nil
        switch walletResult { case .success(let value): balance=value; case .failure(let failure): balance=nil; error=failure.message }
        switch ownedResult { case .success(let value): inventory=value; hasMore = value.count == 30; case .failure(let failure): error=failure.message }
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
    private let message: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var player: AVPlayer?
    public init(gift: GiftSnapshot, title: String = "Your gift", message: String = "A little appreciation, yours to keep.") { self.gift = gift; self.title = title; self.message = message }
    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(gift.displayName).font(.largeTitle.bold())
                GiftArtwork(url: gift.artworkURL).frame(maxWidth: 300, maxHeight: 300)
                if let player { VideoPlayer(player: player).frame(height: 220) }
                else if let animation = gift.animationURL, !reduceMotion {
                    Button("Play gift animation") {
                        let video = AVPlayer(url: animation); video.isMuted = true; player = video; video.play()
                    }.buttonStyle(GiftOutlineButtonStyle())
                }
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(title)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }.onDisappear { player?.pause(); player = nil }
    }
}
