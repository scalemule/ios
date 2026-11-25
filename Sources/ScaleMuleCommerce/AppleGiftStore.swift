import Foundation
import Combine
import StoreKit
import OSLog
import ScaleMuleCore

public struct StoreCreditOffer: Identifiable, Sendable {
    public let pack: CreditPack
    public let product: StoreKit.Product
    public var id: String { product.id }
    /// Apple's localized price is the only price displayed at checkout.
    public var displayPrice: String { product.displayPrice }
}

/// A reusable StoreKit 2 checkout and fulfillment coordinator. Start after sign-in,
/// stop on sign-out, and call retryUnfinished when the app returns to the foreground.
/// Transactions remain unfinished until ScaleMule durably confirms wallet delivery.
@MainActor
public final class AppleGiftStore: ObservableObject {
    @Published public private(set) var offers: [StoreCreditOffer] = []
    @Published public private(set) var environment: CommerceEnvironment?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isPurchasing = false
    @Published public private(set) var pendingTransactions: Set<UInt64> = []
    @Published public private(set) var message: String?
    @Published public private(set) var fulfillmentRevision = 0
    @Published public private(set) var enabled = false
    @Published public private(set) var needsAppStoreConnection = false
    public let commerce: CommerceService
    private var context: ApplePurchaseContext?
    private var checkoutContexts: [CommerceEnvironment: ApplePurchaseContext] = [:]
    private var generation = UUID()
    private var listener: Task<Void, Never>?
    private var processing: Set<UInt64> = []

    private let appEnvironment: (Bool) async throws -> CommerceEnvironment
    private let loadProducts: ([String]) async throws -> [StoreKit.Product]
    private let bundleID: String?
    private let log = Logger(subsystem: "com.scalemule.sdk", category: "Commerce")

    public init(commerce: CommerceService) {
        self.commerce = commerce
        self.appEnvironment = Self.verifiedAppEnvironment
        self.loadProducts = { try await StoreKit.Product.products(for: $0) }
        self.bundleID = Bundle.main.bundleIdentifier
    }

    // Internal dependency injection keeps recovery tests independent of an Apple account.
    init(commerce: CommerceService, bundleID: String? = Bundle.main.bundleIdentifier,
         loadProducts: @escaping ([String]) async throws -> [StoreKit.Product] = { try await StoreKit.Product.products(for: $0) },
         appEnvironment: @escaping (Bool) async throws -> CommerceEnvironment) {
        self.commerce = commerce
        self.appEnvironment = appEnvironment
        self.loadProducts = loadProducts
        self.bundleID = bundleID
    }
    deinit { listener?.cancel() }

    public func start() async {
        await load(refreshAppTransaction: false)
    }

    /// Call only from a user action: Apple may present its authentication sheet.
    public func connectToAppStore() async {
        await load(refreshAppTransaction: true)
    }

    /// Public catalog browsing is independent of Apple sign-in. Production is
    /// only the catalog being browsed, never an inferred wallet/payment environment.
    public var catalogEnvironment: CommerceEnvironment { environment ?? .production }

    public func catalogProducts(before: String? = nil) async -> ApiResponse<[GiftProduct]> {
        await commerce.products(environment: catalogEnvironment, before: before)
    }

    private static func verifiedAppEnvironment(refresh: Bool) async throws -> CommerceEnvironment {
        let result = try await (refresh ? AppTransaction.refresh() : AppTransaction.shared)
        guard case .verified(let app) = result, app.bundleID == Bundle.main.bundleIdentifier else {
            throw CommerceError.unverified
        }
        if app.environment == .production { return .production }
        if app.environment == .sandbox { return .sandbox }
        throw CommerceError.localStoreUnsupported
    }

    private func load(refreshAppTransaction: Bool) async {
        guard !isLoading, !isPurchasing else { return }
        stop()
        let run = generation
        isLoading = true
        defer { if generation == run { isLoading = false } }
        var phase = StartupPhase.appVerification
        do {
            do {
                let verified = try await appEnvironment(refreshAppTransaction)
                guard generation == run, !Task.isCancelled else { return }
                environment = verified
            } catch {
                guard generation == run, !Task.isCancelled else { return }
                // A missing app-download receipt must not prevent Product.purchase
                // from presenting Apple's own purchase/sign-in sheet. Explicitly
                // unverified or local StoreKit receipts are still rejected.
                if error is CommerceError { throw error }
                needsAppStoreConnection = true
                if refreshAppTransaction {
                    message = "Apple couldn’t verify this installation. You can still browse gifts and choose a credit pack to continue with Apple."
                }
                record(error, operation: phase.rawValue)
            }
            phase = .configuration
            // If Apple hasn't identified the environment, checkout is available
            // only for products enabled identically in BOTH environments. We do
            // not choose a wallet or label a test installation as production.
            let environments: [CommerceEnvironment] = environment.map { [$0] } ?? [.production, .sandbox]
            for candidate in environments {
                let response = await commerce.purchaseContext(environment: candidate)
                guard generation == run, !Task.isCancelled else { return }
                switch response {
                case .failure(let error): throw error
                case .success(let value):
                    guard Self.validContext(value, environment: candidate, bundleID: bundleID) else { throw CommerceError.configuration }
                    checkoutContexts[candidate] = value
                }
            }
            guard let primary = checkoutContexts[environment ?? .production] else { throw CommerceError.configuration }
            context = primary
            let packs: [CreditPack]
            if environment == nil {
                guard let review = checkoutContexts[.sandbox], Self.matchingIdentity(primary, review) else { throw CommerceError.configuration }
                enabled = primary.enabled && review.enabled
                packs = Self.sharedPacks(primary, review)
            } else {
                enabled = primary.enabled
                packs = primary.products
            }
            listener = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard !Task.isCancelled, let self, self.generation == run else { return }
                    await self.fulfill(result, generation: run)
                }
            }
            phase = .products
            let products = try await loadProducts(enabled ? packs.map(\.productID) : [])
            guard generation == run, !Task.isCancelled else { return }
            let mapped = Dictionary(products.filter { $0.type == .consumable }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            offers = packs.compactMap { pack in mapped[pack.productID].map { StoreCreditOffer(pack: pack, product: $0) } }
            log.info("Commerce credit packs loaded count=\(self.offers.count) verifiedEnvironment=\(self.environment != nil)")
            if enabled && offers.isEmpty { message = "Credit packs are not available from the App Store yet." }
            await retryUnfinished()
        } catch {
            guard generation == run, !Task.isCancelled else { return }
            if phase == .appVerification { needsAppStoreConnection = (error as? CommerceError) != .localStoreUnsupported }
            message = Self.startupMessage(error, phase: phase)
            record(error, operation: phase.rawValue)
        }
    }

    enum StartupPhase: String { case appVerification, configuration, products }

    static func validContext(_ context: ApplePurchaseContext, environment: CommerceEnvironment, bundleID: String?) -> Bool {
        bundleID != nil && context.bundleID == bundleID && context.environment == environment && context.appAccountToken != nil && context.currencyCode != nil
    }

    static func matchingIdentity(_ first: ApplePurchaseContext, _ second: ApplePurchaseContext) -> Bool {
        first.bundleID == second.bundleID && first.appAccountToken == second.appAccountToken && first.currencyCode == second.currencyCode
    }

    static func sharedPacks(_ production: ApplePurchaseContext, _ sandbox: ApplePurchaseContext) -> [CreditPack] {
        guard production.enabled, sandbox.enabled, matchingIdentity(production, sandbox) else { return [] }
        return production.products.filter { pack in
            sandbox.products.contains { $0.productID == pack.productID && $0.creditsPerUnit == pack.creditsPerUnit }
        }
    }

    static func startupMessage(_ error: Error, phase: StartupPhase) -> String {
        if let error = error as? CommerceError { return error.localizedDescription }
        switch phase {
        case .appVerification:
            return "Apple couldn’t verify this installation. Check your Apple account and try again."
        case .configuration:
            return "We couldn’t load the purchase settings. Please try again."
        case .products:
            return "Apple couldn’t load the credit packs. Please try again."
        }
    }

    // Record codes only, never credentials, receipts, or NSError userInfo contents.
    private func record(_ error: Error, operation: String) {
        var current = error as NSError
        for _ in 0..<3 {
            log.error("Commerce request failed operation=\(operation, privacy: .public) domain=\(current.domain, privacy: .public) code=\(current.code)")
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
    }

    public func stop() {
        generation = UUID(); listener?.cancel(); listener = nil
        context = nil; checkoutContexts = [:]; environment = nil; offers = []; pendingTransactions = []; processing = []
        isLoading = false; isPurchasing = false; message = nil; enabled = false
        needsAppStoreConnection = false
    }

    public func purchase(_ offer: StoreCreditOffer) async {
        guard enabled, !isLoading, !isPurchasing, let token = context?.appAccountToken,
              offers.contains(where: { $0.id == offer.id }) else { return }
        let run = generation
        isPurchasing = true; message = nil
        defer { if generation == run { isPurchasing = false } }
        do {
            let result = try await offer.product.purchase(options: [.appAccountToken(token)])
            guard generation == run else { return }
            switch result {
            case .success(let verification): await fulfill(verification, generation: run)
            case .pending: message = "Your purchase is awaiting approval. Credits will arrive once Apple approves it."
            case .userCancelled: break
            @unknown default: message = "The purchase is still being processed."
            }
        } catch {
            guard generation == run else { return }
            message = "Apple couldn’t complete the purchase. Check pending purchases before trying again."
            record(error, operation: "purchase")
        }
    }

    public func retryUnfinished() async {
        let run = generation
        guard context != nil else { return }
        for await result in StoreKit.Transaction.unfinished {
            guard generation == run, !Task.isCancelled else { return }
            await fulfill(result, generation: run)
        }
    }

    private func fulfill(_ result: VerificationResult<StoreKit.Transaction>, generation run: UUID) async {
        guard generation == run, case .verified(let transaction) = result else {
            if generation == run { message = "Apple could not verify this purchase. No credits have been added." }
            return
        }
        // Another signed-in account's purchase stays unfinished for its owner.
        guard let transactionEnvironment = Self.commerceEnvironment(transaction.environment),
              environment == nil || environment == transactionEnvironment,
              let transactionContext = checkoutContexts[transactionEnvironment],
              transaction.appBundleID == bundleID,
              transaction.appAccountToken == transactionContext.appAccountToken,
              transaction.productType == .consumable, !processing.contains(transaction.id) else { return }
        processing.insert(transaction.id); pendingTransactions.insert(transaction.id)
        defer { if generation == run { processing.remove(transaction.id) } }
        let response = await commerce.submitAppleTransaction(signedTransaction: result.jwsRepresentation)
        guard generation == run, !Task.isCancelled else { return }
        switch response {
        case .success(let purchase):
            guard Self.canFinish(purchase, transactionID: String(transaction.id), productID: transaction.productID, environment: transactionEnvironment),
                  environment == nil || environment == transactionEnvironment else {
                message = "Your purchase is saved. Credits are still being confirmed; you can retry without buying again."
                return
            }
            await transaction.finish()
            guard generation == run else { return }
            // Only a verified Apple purchase and matching durable server result
            // can establish an environment when the app receipt is unavailable.
            context = transactionContext; enabled = transactionContext.enabled
            environment = transactionEnvironment; needsAppStoreConnection = false
            pendingTransactions.remove(transaction.id); fulfillmentRevision += 1
            message = purchase.status == "credited" ? "Credits added." : "Your App Store refund has been applied."
        case .failure(let error):
            message = "Your purchase has not been lost. \(error.message) Retry to confirm it without buying again."
        }
    }

    static func canFinish(_ purchase: AppleCreditPurchase, transactionID: String, productID: String, environment: CommerceEnvironment?) -> Bool {
        purchase.isFulfilled && purchase.transactionID == transactionID && purchase.productID == productID && purchase.environment == environment
    }

    static func commerceEnvironment(_ environment: StoreKit.AppStore.Environment) -> CommerceEnvironment? {
        if environment == .production { return .production }
        if environment == .sandbox { return .sandbox }
        return nil
    }
}

enum CommerceError: LocalizedError, Equatable {
    case unverified, configuration, localStoreUnsupported
    var errorDescription: String? {
        switch self {
        case .unverified: return "Apple could not verify this app. Tap Check Apple account to try again."
        case .configuration: return "Purchases are not configured for this app yet."
        case .localStoreUnsupported: return "Use an App Store Sandbox account or TestFlight to test server-verified purchases. Local StoreKit transactions cannot buy server credits."
        }
    }
}
