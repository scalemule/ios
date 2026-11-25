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
        await client.request(RequestOptions(method: .get, path: catalog + "/products", query: query(environment, before)))
    }
    public func balance(environment: CommerceEnvironment) async -> ApiResponse<CommerceBalance> {
        await client.request(RequestOptions(method: .get, path: catalog + "/balance", query: query(environment)))
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
        await client.request(RequestOptions(method: .get, path: catalog + "/gifts", query: query(environment, before)))
    }
    public func inventory(environment: CommerceEnvironment, before: String? = nil) async -> ApiResponse<[GiftInventoryItem]> {
        await client.request(RequestOptions(method: .get, path: catalog + "/inventory", query: query(environment, before)))
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
    private static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? ""
    }
}
