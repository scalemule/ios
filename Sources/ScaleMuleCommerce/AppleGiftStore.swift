import Foundation
import Combine
import StoreKit
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
    public let commerce: CommerceService
    private var context: ApplePurchaseContext?
    private var generation = UUID()
    private var listener: Task<Void, Never>?
    private var processing: Set<UInt64> = []

    public init(commerce: CommerceService) { self.commerce = commerce }
    deinit { listener?.cancel() }

    public func start() async {
        stop()
        let run = generation
        isLoading = true
        defer { if generation == run { isLoading = false } }
        do {
            let appResult = try await AppTransaction.shared
            guard case .verified(let app) = appResult else { throw CommerceError.unverified }
            let environment: CommerceEnvironment
            if app.environment == .production { environment = .production }
            else if app.environment == .sandbox { environment = .sandbox }
            else { throw CommerceError.localStoreUnsupported }
            let response = await commerce.purchaseContext(environment: environment)
            guard generation == run, !Task.isCancelled else { return }
            switch response {
            case .failure(let error): throw error
            case .success(let context):
                guard context.appAccountToken != nil,
                      context.bundleID == Bundle.main.bundleIdentifier,
                      context.environment == environment else { throw CommerceError.configuration }
                self.context = context; self.environment = environment; enabled = context.enabled
                listener = Task { [weak self] in
                    for await result in StoreKit.Transaction.updates {
                        guard !Task.isCancelled, let self, self.generation == run else { return }
                        await self.fulfill(result, generation: run)
                    }
                }
                let products = try await StoreKit.Product.products(for: context.products.map(\.productID))
                guard generation == run, !Task.isCancelled else { return }
                let mapped = Dictionary(uniqueKeysWithValues: products.filter { $0.type == .consumable }.map { ($0.id, $0) })
                offers = context.products.compactMap { pack in mapped[pack.productID].map { StoreCreditOffer(pack: pack, product: $0) } }
                if context.enabled && offers.isEmpty { message = "Credit packs are not available from the App Store yet." }
                await retryUnfinished()
            }
        } catch {
            guard generation == run else { return }
            message = error.localizedDescription
        }
    }

    public func stop() {
        generation = UUID(); listener?.cancel(); listener = nil
        context = nil; environment = nil; offers = []; pendingTransactions = []; processing = []
        isLoading = false; isPurchasing = false; message = nil; enabled = false
    }

    public func purchase(_ offer: StoreCreditOffer) async {
        guard enabled, !isPurchasing, let token = context?.appAccountToken,
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
        } catch { if generation == run { message = error.localizedDescription } }
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
        guard transaction.appAccountToken == context?.appAccountToken,
              transaction.productType == .consumable, !processing.contains(transaction.id) else { return }
        processing.insert(transaction.id); pendingTransactions.insert(transaction.id)
        defer { if generation == run { processing.remove(transaction.id) } }
        let response = await commerce.submitAppleTransaction(signedTransaction: result.jwsRepresentation)
        guard generation == run, !Task.isCancelled else { return }
        switch response {
        case .success(let purchase):
            guard Self.canFinish(purchase, transactionID: String(transaction.id), productID: transaction.productID, environment: environment) else {
                message = "Your purchase is saved. Credits are still being confirmed; you can retry without buying again."
                return
            }
            await transaction.finish()
            guard generation == run else { return }
            pendingTransactions.remove(transaction.id); fulfillmentRevision += 1
            message = purchase.status == "credited" ? "Credits added." : "Your App Store refund has been applied."
        case .failure(let error):
            message = "Your purchase has not been lost. \(error.message) Retry to confirm it without buying again."
        }
    }

    static func canFinish(_ purchase: AppleCreditPurchase, transactionID: String, productID: String, environment: CommerceEnvironment?) -> Bool {
        purchase.isFulfilled && purchase.transactionID == transactionID && purchase.productID == productID && purchase.environment == environment
    }
}

private enum CommerceError: LocalizedError {
    case unverified, configuration, localStoreUnsupported
    var errorDescription: String? {
        switch self {
        case .unverified: return "Apple could not verify this app's purchase environment. Please try again."
        case .configuration: return "Purchases are not configured for this app yet."
        case .localStoreUnsupported: return "Use an App Store Sandbox account or TestFlight to test server-verified purchases. Local StoreKit transactions cannot buy server credits."
        }
    }
}
