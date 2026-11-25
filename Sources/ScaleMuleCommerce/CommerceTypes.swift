import Foundation
import ScaleMuleCore

public enum CommerceEnvironment: String, Codable, Sendable { case production = "Production", sandbox = "Sandbox" }
public struct GiftConfiguration: Decodable, Sendable {
    public let enabled: Bool
    public let currencyCode: String?
    public let sandboxEnabled: Bool?
    enum CodingKeys: String, CodingKey { case enabled, currencyCode = "currency_code", sandboxEnabled = "sandbox_enabled" }
}
public struct GiftProduct: Decodable, Identifiable, Sendable {
    public let id: String
    public let sku: String
    public let displayName: String
    public let description: String
    public let kind: String
    public let artworkURL: URL
    public let animationURL: URL?
    public let version: Int64
    public let currencyCode: String
    public let unitPriceMinor: Int64
    enum CodingKeys: String, CodingKey {
        case id, sku, description, kind, version
        case displayName = "display_name", artworkURL = "artwork_url", animationURL = "animation_url"
        case currencyCode = "currency_code", unitPriceMinor = "unit_price_minor"
    }
}
public struct GiftSnapshot: Decodable, Sendable {
    public let displayName: String
    public let artworkURL: URL
    public let animationURL: URL?
    public let kind: String
    enum CodingKeys: String, CodingKey { case kind, displayName = "display_name", artworkURL = "artwork_url", animationURL = "animation_url" }
}
public struct DigitalGift: Decodable, Identifiable, Sendable {
    public let id: String
    public let senderID: String
    public let recipientID: String
    public let productID: String
    public let environment: CommerceEnvironment
    public let quantity: Int
    public let totalMinor: Int64
    public let currencyCode: String
    public let status: String
    public let productSnapshot: GiftSnapshot
    public let createdAt: String
    public let deliveredAt: String?
    public var isDelivered: Bool { status == "delivered" }
    public var needsAttention: Bool { status == "needs_attention" }
    enum CodingKeys: String, CodingKey {
        case id, quantity, status, environment
        case senderID = "sender_id", recipientID = "recipient_id", productID = "product_id"
        case totalMinor = "total_minor", currencyCode = "currency_code", productSnapshot = "product_snapshot"
        case createdAt = "created_at", deliveredAt = "delivered_at"
    }
}
public struct GiftInventoryItem: Decodable, Identifiable, Sendable {
    public let id: String
    public let giftID: String
    public let productID: String
    public let quantity: Int
    public let consumedQuantity: Int
    public let productSnapshot: GiftSnapshot
    public var availableQuantity: Int { max(0, quantity - consumedQuantity) }
    enum CodingKeys: String, CodingKey { case id, quantity, giftID = "gift_id", productID = "product_id", consumedQuantity = "consumed_quantity", productSnapshot = "product_snapshot" }
}
public struct CommerceBalance: Decodable, Sendable {
    public let id: String
    public let currencyCode: String
    public let availableMinor: Int64
    public let heldMinor: Int64
    enum CodingKeys: String, CodingKey { case id, currencyCode = "currency_code", availableMinor = "available_minor", heldMinor = "held_minor" }
}
public struct CreditPack: Decodable, Identifiable, Sendable {
    public let productID: String
    public let displayName: String
    public let creditsPerUnit: Int64
    public var id: String { productID }
    enum CodingKeys: String, CodingKey { case productID = "product_id", displayName = "display_name", creditsPerUnit = "credits_per_unit" }
}
public struct ApplePurchaseContext: Decodable, Sendable {
    public let enabled: Bool
    public let environment: CommerceEnvironment?
    public let currencyCode: String?
    public let bundleID: String?
    public let appAccountToken: UUID?
    public let products: [CreditPack]
    enum CodingKeys: String, CodingKey { case enabled, environment, products, currencyCode = "currency_code", bundleID = "bundle_id", appAccountToken = "app_account_token" }
}
public struct AppleCreditPurchase: Decodable, Identifiable, Sendable {
    public let id: String
    public let transactionID: String
    public let productID: String
    public let environment: CommerceEnvironment
    public let creditsMinor: Int64
    public let refundedMinor: Int64
    public let currencyCode: String
    public let status: String
    public var isFulfilled: Bool { ["credited", "refunded", "partially_refunded"].contains(status) }
    enum CodingKeys: String, CodingKey { case id, status, environment, transactionID = "transaction_id", productID = "product_id", creditsMinor = "credits_minor", refundedMinor = "refunded_minor", currencyCode = "currency_code" }
}

/// Keep this request and its key when retrying. A new key is a new purchase.
public struct SendGiftRequest: Codable, Sendable {
    public let productID: String
    public let recipientID: String
    public let quantity: Int
    public let environment: CommerceEnvironment
    public let expectedUnitPriceMinor: Int64
    public let idempotencyKey: String
    public let contextType: String?
    public let contextID: String?
    public init(productID: String, recipientID: String, quantity: Int = 1, environment: CommerceEnvironment,
                expectedUnitPriceMinor: Int64, idempotencyKey: String, contextType: String? = nil, contextID: String? = nil) {
        self.productID=productID;self.recipientID=recipientID;self.quantity=quantity;self.environment=environment
        self.expectedUnitPriceMinor=expectedUnitPriceMinor;self.idempotencyKey=idempotencyKey;self.contextType=contextType;self.contextID=contextID
    }
    enum CodingKeys: String, CodingKey { case quantity, environment, productID = "product_id", recipientID = "recipient_id", expectedUnitPriceMinor = "expected_unit_price_minor", idempotencyKey = "idempotency_key", contextType = "context_type", contextID = "context_id" }
}

public struct InventoryConsumption: Decodable, Sendable {
    public let remainingQuantity: Int
    enum CodingKeys: String, CodingKey { case remainingQuantity = "remaining_quantity" }
}
