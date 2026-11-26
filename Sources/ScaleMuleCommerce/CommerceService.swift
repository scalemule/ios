import Foundation
import ScaleMuleCore

/// Catalog owns gifts and inventory; Money Billing verifies StoreKit purchases;
/// Money Assets owns the ledger. Apps use only their API key and user session.
public final class CommerceService: ServiceModule, @unchecked Sendable {
    public let client: HTTPClient
    public required init(client: HTTPClient) { self.client = client }
    public convenience init(app: ScaleMuleApp) { self.init(client: app.client) }
    private let catalog = "/v1/catalog/goods"
    private let billing = "/v1/money/billing/app-store"

    public func configuration() async -> ApiResponse<GiftConfiguration> {
        await client.request(RequestOptions(method: .get, path: catalog + "/config"))
    }
    public func products(environment: CommerceEnvironment, before: String? = nil) async -> ApiResponse<[GiftProduct]> {
        await read(path: catalog + "/products", query: query(environment, before))
    }
    public func balance(environment: CommerceEnvironment) async -> ApiResponse<CommerceBalance> {
        await read(path: catalog + "/balance", query: query(environment))
    }
    public func sendGift(_ request: SendGiftRequest) async -> ApiResponse<DigitalGift> {
        do {
            let body = try JSONEncoder().encode(request)
            return await client.request(RequestOptions(method: .post, path: catalog + "/gifts", idempotent: true, rawBody: body, contentType: "application/json"))
        } catch { return .failure(ApiError(code: .validationError, message: "The gift could not be prepared.")) }
    }
    public func gift(id: String) async -> ApiResponse<DigitalGift> {
        await client.request(RequestOptions(method: .get, path: catalog + "/gifts/" + Self.segment(id)))
    }
    public func history(environment: CommerceEnvironment, before: String? = nil) async -> ApiResponse<[DigitalGift]> {
        await read(path: catalog + "/gifts", query: query(environment, before))
    }
    public func inventory(environment: CommerceEnvironment, before: String? = nil) async -> ApiResponse<[GiftInventoryItem]> {
        await read(path: catalog + "/inventory", query: query(environment, before))
    }
    public func consume(inventoryID: String, quantity: Int, idempotencyKey: String) async -> ApiResponse<InventoryConsumption> {
        await client.request(RequestOptions(method: .post, path: catalog + "/inventory/" + Self.segment(inventoryID) + "/consume",
            body: ["quantity": quantity, "idempotency_key": idempotencyKey], idempotent: true))
    }
    public func purchaseContext(environment: CommerceEnvironment) async -> ApiResponse<ApplePurchaseContext> {
        await client.request(RequestOptions(method: .get, path: billing + "/context", query: query(environment)))
    }
    public func submitAppleTransaction(signedTransaction: String) async -> ApiResponse<AppleCreditPurchase> {
        await client.request(RequestOptions(method: .post, path: billing + "/transactions", body: ["signed_transaction": signedTransaction], idempotent: true))
    }
    public func purchases(environment: CommerceEnvironment, before: String? = nil) async -> ApiResponse<[AppleCreditPurchase]> {
        await client.request(RequestOptions(method: .get, path: billing + "/transactions", query: query(environment, before)))
    }
    private func query(_ environment: CommerceEnvironment, _ before: String? = nil) -> [String:String] {
        var result = ["environment": environment.rawValue, "limit": "30"]
        if let before { result["before"] = before }
        return result
    }
    private func read<T: Decodable & Sendable>(path: String, query: [String: String]) async -> ApiResponse<T> {
        let client = client
        return await Self.withReadDeadline {
            await client.request(RequestOptions(method: .get, path: path, query: query, retryable: false))
        }
    }

    /// Bound interactive reads; payment submissions retain their durable retry path.
    static func withReadDeadline<T: Sendable>(seconds: Double = 12,
        operation: @escaping @Sendable () async -> ApiResponse<T>) async -> ApiResponse<T> {
        await withTaskGroup(of: ApiResponse<T>.self) { group in
            group.addTask { await operation() }
            group.addTask {
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return .failure(ApiError(code: .networkError, message: "Request cancelled.")) }
                return .failure(ApiError(code: .timeout, message: "This is taking longer than expected. Please try again."))
            }
            let response = await group.next() ?? .failure(ApiError(code: .timeout, message: "Please try again."))
            group.cancelAll()
            return response
        }
    }
    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? ""
    }
}
