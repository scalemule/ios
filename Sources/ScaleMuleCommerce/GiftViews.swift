import SwiftUI
import AVKit
import ScaleMuleCore

/// A compact gift tray. Checkout is a separate sheet; selecting a gift never spends credits.
public struct GiftPickerView: View {
    @ObservedObject private var store: AppleGiftStore
    @ObservedObject private var delivery: GiftDeliveryStore
    @State private var recipient: GiftRecipient?
    private let loadRecipients: (@MainActor () async throws -> [GiftRecipient])?
    private let contextType: String?
    private let contextID: String?
    @State private var products: [GiftProduct] = []
    @State private var balance: CommerceBalance?
    @State private var balanceEnvironment: CommerceEnvironment?
    @State private var selected: String?
    @State private var error: String?
    @State private var balanceError: String?
    @State private var loading = true
    @State private var loadingBalance = false
    @State private var showWallet = false
    @State private var showRecipients = false
    @State private var hasMore = false
    @State private var productCursor: String?
    @State private var catalogLoad = UUID()
    @State private var balanceLoad = UUID()
    @State private var sent: DigitalGift?
    @Environment(\.giftTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(store: AppleGiftStore, delivery: GiftDeliveryStore, recipientID: String, recipientName: String,
                contextType: String? = nil, contextID: String? = nil) {
        self.store = store; self.delivery = delivery
        self._recipient = State(initialValue: GiftRecipient(id: recipientID, name: recipientName))
        self.loadRecipients = nil; self.contextType = contextType; self.contextID = contextID
    }
    public init(store: AppleGiftStore, delivery: GiftDeliveryStore,
                loadRecipients: @escaping @MainActor () async throws -> [GiftRecipient]) {
        self.store = store; self.delivery = delivery; self._recipient = State(initialValue: nil)
        self.loadRecipients = loadRecipients; self.contextType = nil; self.contextID = nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            recipientHeader.padding(.horizontal, 20).padding(.vertical, 12)
            ScrollView {
                VStack(spacing: 12) {
                    if let sent {
                        HStack(spacing: 10) {
                            GiftArtwork(url: sent.productSnapshot.artworkURL).frame(width: 34, height: 34)
                            Text("\(sent.productSnapshot.displayName) sent to \(recipient?.name ?? "your recipient")")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                        }.foregroundStyle(theme.accent).accessibilityAddTraits(.updatesFrequently)
                    }
                    if loading && products.isEmpty {
                        ProgressView("Loading gifts…").frame(maxWidth: .infinity, minHeight: 160)
                    } else if products.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "gift").font(.largeTitle).foregroundStyle(theme.accent)
                            Text(error == nil ? "No gifts available yet" : "Gifts couldn’t load").font(.headline)
                            Button("Try again") { Task { await load() } }.buttonStyle(GiftOutlineButtonStyle())
                        }.frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 10) {
                            ForEach(products) { product in
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) { selected = product.id; sent = nil }
                                } label: {
                                    GiftTrayTile(name: product.displayName, credits: product.unitPriceMinor, selected: selected == product.id) {
                                        GiftArtwork(url: product.artworkURL)
                                    }
                                }.buttonStyle(.plain).disabled(delivery.isSending)
                                    .accessibilityLabel("\(product.displayName), \(product.unitPriceMinor) credits")
                                    .accessibilityAddTraits(selected == product.id ? .isSelected : [])
                                    .accessibilityIdentifier("giftTile-\(product.sku)")
                            }
                        }
                    }
                    if hasMore { Button("More gifts") { Task { await moreProducts() } }.buttonStyle(GiftOutlineButtonStyle()) }
                    if let error, !products.isEmpty { GiftNotice(text: error, isError: true) }
                    if let message = delivery.message, sent == nil { GiftNotice(text: message) }
                    if !delivery.pending.isEmpty {
                        Button("Retry delivery") { Task { await delivery.retryPending(); await refreshBalance() } }
                            .buttonStyle(GiftOutlineButtonStyle()).disabled(delivery.isSending)
                    }
                }.padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .navigationTitle("Send a gift").giftInlineNavigation()
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .task { async let wallet: Void = refreshBalance(); await load(); await wallet }
        .onChange(of: store.fulfillmentRevision) { _ in Task { await refreshBalance() } }
        .onChange(of: store.walletEnvironment) { _ in
            balance = nil
            Task { async let wallet: Void = refreshBalance(); await load(); await wallet }
        }
        .onChange(of: delivery.lastDelivered?.id) { _ in
            if delivery.lastDelivered?.recipientID == recipient?.id { sent = delivery.lastDelivered }
        }
        .sheet(isPresented: $showWallet, onDismiss: { Task { await refreshBalance() } }) {
            NavigationStack { CommerceWalletView(store: store) }.giftSheet()
        }
        .sheet(isPresented: $showRecipients) {
            if let loadRecipients { GiftRecipientPicker(load: loadRecipients, selectedID: recipient?.id) { recipient = $0; sent = nil } }
        }
    }

    private var recipientHeader: some View {
        HStack(spacing: 10) {
            GiftPersonAvatar(person: recipient).frame(width: 32, height: 32)
            if loadRecipients != nil {
                Button { showRecipients = true } label: {
                    HStack(spacing: 6) {
                        Text(recipient.map { "To \($0.name)" } ?? "Choose a person").font(.headline)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                }.buttonStyle(.plain).disabled(delivery.isSending).accessibilityIdentifier("giftChooseRecipient")
            } else { Text("To \(recipient?.name ?? "your recipient")").font(.headline) }
            Spacer(minLength: 0)
        }
    }
    private var selectedProduct: GiftProduct? { products.first { $0.id == selected } }
    private var needsCredits: Bool {
        guard let product = selectedProduct, let balance else { return false }
        return balance.availableMinor < product.unitPriceMinor
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let balanceError {
                HStack {
                    Text("Credits couldn’t load.").font(.footnote).foregroundStyle(.secondary)
                    Button("Retry") { Task { await refreshBalance() } }.font(.footnote.weight(.semibold))
                }.accessibilityHint(balanceError)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let balance { CreditAmount(amount: balance.availableMinor, font: .subheadline.bold()) }
                    else { Text(loadingBalance ? "Loading credits…" : "Credits").font(.caption).foregroundStyle(.secondary) }
                    Button("Recharge") { showWallet = true }.font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("giftGetCredits")
                }
                Spacer(minLength: 8)
                Button { Task { await sendSelected() } } label: {
                    HStack(spacing: 6) {
                        if delivery.isSending || (recipient != nil && loadingBalance) { ProgressView().tint(theme.onAccent) }
                        Text(delivery.isSending ? "Sending…" : (recipient == nil ? "Choose person" : (needsCredits ? "Recharge" : "Send")))
                        if let product = selectedProduct, !delivery.isSending, !needsCredits, recipient != nil {
                            Text("· \(product.unitPriceMinor)").monospacedDigit()
                        }
                    }
                }.buttonStyle(GiftPillButtonStyle())
                    .disabled(delivery.isSending || (recipient != nil && (selectedProduct == nil || loadingBalance)))
                    .accessibilityIdentifier("giftConfirmSend")
                    .accessibilityLabel(recipient == nil ? "Choose a person" : (selectedProduct.map { "\(needsCredits ? "Recharge to send" : "Send") \($0.displayName), \($0.unitPriceMinor) credits" } ?? "Choose a gift"))
            }
        }.padding(.horizontal, 20).padding(.vertical, 14).background(.regularMaterial)
    }
    private func sendSelected() async {
        // Choosing a recipient is navigation, independent of gifts or wallet loading.
        guard !delivery.isSending else { return }
        guard let recipient else { showRecipients = true; return }
        guard let product = selectedProduct else { return }
        if balance == nil || balanceEnvironment != store.walletEnvironment { await refreshBalance() }
        guard let balance, balanceEnvironment == store.walletEnvironment else { return }
        guard balance.availableMinor >= product.unitPriceMinor else { showWallet = true; return }
        await delivery.send(product: product, recipientID: recipient.id, environment: store.walletEnvironment,
                            contextType: contextType, contextID: contextID)
        await refreshBalance()
    }
    private func load() async {
        let run = UUID(); catalogLoad = run; loading = true; error = nil
        defer { if catalogLoad == run { loading = false } }
        let browsing = store.catalogEnvironment
        let items = await store.catalogProducts()
        guard catalogLoad == run, store.catalogEnvironment == browsing, !Task.isCancelled else { return }
        switch items {
        case .success(let value):
            productCursor = value.last?.id; products = ordered(value); hasMore = value.count == 30
            if !products.contains(where: { $0.id == selected }) { selected = nil }
        case .failure(let failure): error = failure.message
        }
    }
    private func moreProducts() async {
        guard let cursor = productCursor else { return }
        let run = catalogLoad; let browsing = store.catalogEnvironment
        let response = await store.catalogProducts(before: cursor)
        guard run == catalogLoad, store.catalogEnvironment == browsing, productCursor == cursor, !Task.isCancelled else { return }
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
        let run = UUID(); balanceLoad = run; loadingBalance = true
        defer { if balanceLoad == run { loadingBalance = false } }
        let environment = store.walletEnvironment
        let response = await store.balance()
        guard balanceLoad == run, store.walletEnvironment == environment, !Task.isCancelled else { return }
        switch response {
        case .success(let value): balance = value; balanceEnvironment = environment; balanceError = nil
        case .failure(let failure): balance = nil; balanceEnvironment = nil; balanceError = failure.message
        }
    }
}

/// Recharge is deliberately focused: choose a pack, confirm with Apple, return
/// to the selected gift. Received gifts live in ReceivedGiftsView.
public struct CommerceWalletView: View {
    @ObservedObject private var store: AppleGiftStore
    @State private var balance: CommerceBalance?
    @State private var selected: String?
    @State private var balanceError = false
    @State private var balanceLoad = UUID()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    public init(store: AppleGiftStore) { self.store = store }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 8) {
                    Text("Your credits").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if let balance { CreditAmount(amount: balance.availableMinor, font: .title3.bold()) }
                    else if balanceError {
                        Button("Refresh") { Task { await refresh() } }.font(.subheadline.weight(.semibold))
                    }
                }
                Text("A little appreciation goes a long way.").font(.title3.weight(.semibold))
                if store.isLoading && store.offers.isEmpty { ProgressView("Loading credit packs…").frame(maxWidth: .infinity, minHeight: 100) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 3), spacing: 10) {
                    ForEach(store.offers) { offer in
                        Button { selected = offer.id } label: {
                            RechargePackTile(credits: offer.pack.creditsPerUnit, price: offer.displayPrice, selected: selected == offer.id)
                        }.buttonStyle(.plain).disabled(store.isPurchasing)
                    }
                }
                if store.offers.isEmpty && !store.isLoading {
                    Text("Credit packs couldn’t load.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Try again") { Task { await store.start() } }.buttonStyle(GiftOutlineButtonStyle())
                }
                if let message = store.message { GiftNotice(text: message) }
                Text("Credits never expire. Gifts are digital items and can’t be exchanged for cash.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Missing a purchase? Restore credits") { Task { await store.retryUnfinished(); await refresh() } }
                    .font(.footnote.weight(.semibold)).disabled(store.isLoading || store.isPurchasing)
                    .accessibilityIdentifier("commerceCheckPending")
            }.padding(20)
        }
        .navigationTitle("Recharge").giftInlineNavigation()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    guard let offer = store.offers.first(where: { $0.id == selected }) else { return }
                    Task { if await store.purchase(offer) { dismiss() } }
                } label: {
                    HStack(spacing: 8) {
                        if store.isPurchasing { ProgressView() }
                        Text(store.isPurchasing ? "Confirming…" : "Recharge\(selectedOffer.map { " · \($0.displayPrice)" } ?? "")")
                    }
                }.buttonStyle(GiftPrimaryButtonStyle())
                    .disabled(selectedOffer == nil || store.isLoading || store.isPurchasing || !store.enabled)
                    .accessibilityIdentifier("commerceRecharge")
                Text("Secure payment with Apple").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.regularMaterial)
        }
        .task {
            async let wallet: Void = refresh()
            if store.offers.isEmpty && !store.isLoading { await store.start() }
            await wallet
            if selected == nil { selected = store.offers.first?.id }
        }
        .onChange(of: store.offers.map(\.id)) { _ in if selectedOffer == nil { selected = store.offers.first?.id } }
        .onChange(of: store.walletEnvironment) { _ in balance = nil; Task { await refresh() } }
    }
    private var selectedOffer: StoreCreditOffer? { store.offers.first { $0.id == selected } }
    private func refresh() async {
        let run = UUID(); balanceLoad = run
        let environment = store.walletEnvironment
        let response = await store.balance()
        guard balanceLoad == run, store.walletEnvironment == environment, !Task.isCancelled else { return }
        switch response {
        case .success(let value): balance = value; balanceError = false
        case .failure: balance = nil; balanceError = true
        }
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
