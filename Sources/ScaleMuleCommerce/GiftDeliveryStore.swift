import Foundation
import Combine
import CryptoKit
import ScaleMuleCore

/// Saves the exact operation before sending it. Relaunches and network retries
/// reuse that operation; a new key is created only for another deliberate gift.
@MainActor
public final class GiftDeliveryStore: ObservableObject {
    @Published public private(set) var pending: [SendGiftRequest] = []
    @Published public private(set) var message: String?
    @Published public private(set) var lastDelivered: DigitalGift?
    @Published public private(set) var isSending = false
    private let commerce: CommerceService
    private var file: URL?
    private var generation = UUID()
    private var busy: Set<String> = []
    private let directory: URL

    public init(commerce: CommerceService, storageDirectory: URL? = nil) {
        self.commerce = commerce
        self.directory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ScaleMuleCommerce", isDirectory: true)
    }

    public func start(userID: String) async {
        stop()
        let namespace = commerce.client.configuration.apiKey + ":" + userID
        let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent("gifts-\(digest).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            file = url
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard data.count <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
                pending = try JSONDecoder().decode([SendGiftRequest].self, from: data)
            }
            await retryPending()
        } catch {
            file = nil
            message = "Saved gift deliveries could not be opened. Please restart the app before sending another gift."
        }
    }

    public func stop() {
        generation = UUID(); file = nil; pending = []; busy = []; isSending = false; message = nil; lastDelivered = nil
    }

    public func send(product: GiftProduct, recipientID: String, environment: CommerceEnvironment,
                     contextType: String? = nil, contextID: String? = nil) async {
        guard !isSending else { return }
        // An unresolved send must be retried, not silently turned into a second charge.
        if let old = pending.first(where: { $0.productID == product.id && $0.recipientID == recipientID && $0.contextID == contextID && $0.environment == environment }) {
            await deliver(old); return
        }
        guard pending.count < 100 else { message = "Please finish your pending gift deliveries before sending more."; return }
        let request = SendGiftRequest(productID: product.id, recipientID: recipientID, environment: environment,
            expectedUnitPriceMinor: product.unitPriceMinor, idempotencyKey: UUID().uuidString,
            contextType: contextType, contextID: contextID)
        do {
            try persist(pending + [request])
            pending.append(request)
        } catch { message = "Your gift could not be saved for delivery. No credits were spent."; return }
        await deliver(request)
    }

    public func retryPending() async {
        let run = generation
        for request in pending {
            guard generation == run, !Task.isCancelled else { return }
            await deliver(request)
        }
    }

    private func deliver(_ request: SendGiftRequest) async {
        guard file != nil, !busy.contains(request.idempotencyKey) else { return }
        let run = generation
        busy.insert(request.idempotencyKey); isSending = true; message = nil
        defer { if generation == run { busy.remove(request.idempotencyKey); isSending = !busy.isEmpty } }
        let response = await commerce.sendGift(request)
        guard generation == run else { return }
        switch response {
        case .success(let gift):
            if gift.isDelivered {
                lastDelivered = gift
                message = "Gift sent."
                remove(request)
            } else if gift.status == "failed" {
                message = "This gift was not sent. Check your credit balance and try again."
                remove(request)
            } else {
                message = "Your gift is being delivered. Retry delivery to check its progress; you will not be charged twice."
            }
        case .failure(let error):
            message = error.message
            // Definitive validation/permission failures did not spend credits.
            // Timeouts, server failures and rate limits retain the exact request.
            if let status = error.statusCode, [400,401,403,404,409,422].contains(status) {
                // Authentication failures may be a temporarily expired session.
                if status != 401 { remove(request) }
            }
        }
    }

    private func remove(_ request: SendGiftRequest) {
        let remaining = pending.filter { $0.idempotencyKey != request.idempotencyKey }
        do { try persist(remaining); pending = remaining }
        catch { message = "Delivery status could not be saved. Your next retry will check the same gift safely." }
    }
    private func persist(_ requests: [SendGiftRequest]) throws {
        guard let file else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(requests)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
}
