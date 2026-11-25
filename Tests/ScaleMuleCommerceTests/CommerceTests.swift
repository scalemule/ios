import XCTest
import ScaleMuleCore
import ScaleMuleTestHelpers
@testable import ScaleMuleCommerce

final class CommerceTests: XCTestCase {
    static let product = #"{"id":"019b0000-0000-7000-8000-000000000001","sku":"wave","display_name":"Wave","description":"A little hello","kind":"both","artwork_url":"https://example.com/wave.png","animation_url":null,"version":1,"currency_code":"COIN","unit_price_minor":10}"#
    static let gift = #"{"id":"019b0000-0000-7000-8000-000000000002","sender_id":"sender","recipient_id":"recipient","product_id":"019b0000-0000-7000-8000-000000000001","environment":"Sandbox","quantity":1,"total_minor":10,"currency_code":"COIN","status":"delivered","product_snapshot":{"display_name":"Wave","artwork_url":"https://example.com/wave.png","animation_url":null,"kind":"both"},"created_at":"2026-11-24T10:00:00Z","delivered_at":"2026-11-24T10:00:01Z"}"#
    private func signedIn() async throws -> CommerceService {
        let (app, _) = createTestClient()
        try await app.sessionManager.setCredentials(CredentialSet(sessionToken: "buyer-session", sessionExpiresAt: Date().addingTimeInterval(3600)))
        return CommerceService(app: app)
    }
    func testGiftUsesAuthenticatedSessionAndStableOperation() async throws {
        let commerce = try await signedIn()
        var sentKeys: [String] = []
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/catalog/goods/gifts")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer buyer-session")
            let body = try JSONSerialization.jsonObject(with: self.body(request)) as! [String:Any]
            sentKeys.append(body["idempotency_key"] as! String)
            XCTAssertEqual(body["environment"] as? String, "Sandbox")
            XCTAssertNil(body["sender_id"])
            return TestFixtures.envelopedResponse(json: Self.gift)
        }
        let request = SendGiftRequest(productID: "gift", recipientID: "recipient", environment: .sandbox, expectedUnitPriceMinor: 10, idempotencyKey: "same-delivery")
        let first = await commerce.sendGift(request)
        let second = await commerce.sendGift(request)
        XCTAssertTrue(first.isSuccess)
        XCTAssertTrue(second.isSuccess)
        XCTAssertEqual(sentKeys, ["same-delivery", "same-delivery"])
    }
    @MainActor
    func testNeverFinishesPendingOrMismatchedAppleTransaction() throws {
        func purchase(_ status: String) throws -> AppleCreditPurchase {
            try JSONDecoder().decode(AppleCreditPurchase.self, from: Data("""
            {"id":"purchase","transaction_id":"123","product_id":"coins","environment":"Sandbox","credits_minor":100,"refunded_minor":0,"currency_code":"COIN","status":"\(status)"}
            """.utf8))
        }
        for status in ["pending", "needs_attention"] { XCTAssertFalse(AppleGiftStore.canFinish(try purchase(status), transactionID: "123", productID: "coins", environment: .sandbox)) }
        XCTAssertTrue(AppleGiftStore.canFinish(try purchase("credited"), transactionID: "123", productID: "coins", environment: .sandbox))
        XCTAssertTrue(AppleGiftStore.canFinish(try purchase("refunded"), transactionID: "123", productID: "coins", environment: .sandbox))
        XCTAssertFalse(AppleGiftStore.canFinish(try purchase("credited"), transactionID: "other", productID: "coins", environment: .sandbox))
        XCTAssertFalse(AppleGiftStore.canFinish(try purchase("credited"), transactionID: "123", productID: "coins", environment: .production))
    }
    @MainActor
    func testGiftIsPersistedBeforeSendingAndReplaySurvivesRelaunch() async throws {
        let commerce = try await signedIn()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = GiftDeliveryStore(commerce: commerce, storageDirectory: directory)
        await queue.start(userID: "buyer")
        var firstKey: String?
        MockURLProtocol.requestHandler = { request in
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            let saved = try JSONDecoder().decode([SendGiftRequest].self, from: Data(contentsOf: files[0]))
            let body = try JSONSerialization.jsonObject(with: self.body(request)) as! [String:Any]
            firstKey = body["idempotency_key"] as? String
            XCTAssertEqual(saved.first?.idempotencyKey, firstKey)
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data(#"{"success":false,"error":{"code":"UNAVAILABLE","message":"Temporary outage"}}"#.utf8))
        }
        let product = try JSONDecoder().decode(GiftProduct.self, from: Data(Self.product.utf8))
        await queue.send(product: product, recipientID: "recipient", environment: .sandbox)
        XCTAssertEqual(queue.pending.count, 1)
        queue.stop()
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: self.body(request)) as! [String:Any]
            XCTAssertEqual(body["idempotency_key"] as? String, firstKey)
            return TestFixtures.envelopedResponse(json: Self.gift)
        }
        let relaunched = GiftDeliveryStore(commerce: commerce, storageDirectory: directory)
        await relaunched.start(userID: "buyer")
        XCTAssertTrue(relaunched.pending.isEmpty)
        XCTAssertTrue(relaunched.lastDelivered?.isDelivered == true)
    }
    @MainActor
    func testUnavailableAppTransactionOffersExplicitRecoveryWithoutGuessingEnvironment() async throws {
        let commerce = try await signedIn()
        var refreshRequests: [Bool] = []
        MockURLProtocol.requestHandler = { _ in
            XCTFail("No server request is allowed before Apple verifies the environment")
            throw URLError(.badServerResponse)
        }
        let store = AppleGiftStore(commerce: commerce) { refresh in
            refreshRequests.append(refresh)
            throw NSError(domain: "SKInternalErrorDomain", code: 14)
        }
        await store.start()
        XCTAssertEqual(refreshRequests, [false])
        XCTAssertTrue(store.needsAppStoreConnection)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.enabled)
        XCTAssertNil(store.environment)
        XCTAssertTrue(store.offers.isEmpty)
        XCTAssertTrue(store.message?.contains("Connect to App Store") == true)
        XCTAssertFalse(store.message?.contains("SKInternalErrorDomain") == true)

        // Only this explicit action is permitted to request Apple's sign-in sheet.
        await store.connectToAppStore()
        XCTAssertEqual(refreshRequests, [false, true])
        XCTAssertTrue(store.needsAppStoreConnection)
        store.stop()
        XCTAssertFalse(store.needsAppStoreConnection)
        XCTAssertNil(store.message)
    }

    @MainActor
    func testLogoutDuringAppleVerificationDiscardsResultAndConcurrentStart() async throws {
        let commerce = try await signedIn()
        let started = expectation(description: "Apple verification started")
        var continuation: CheckedContinuation<CommerceEnvironment, Error>?
        var attempts = 0
        MockURLProtocol.requestHandler = { _ in
            XCTFail("The old account must not start a purchase context after logout")
            throw URLError(.badServerResponse)
        }
        let store = AppleGiftStore(commerce: commerce) { _ in
            attempts += 1
            return try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let initial = Task { await store.start() }
        await fulfillment(of: [started], timeout: 2)
        await store.start()
        XCTAssertEqual(attempts, 1)
        store.stop()
        continuation?.resume(returning: .sandbox)
        await initial.value
        XCTAssertNil(store.environment)
        XCTAssertNil(store.message)
        XCTAssertFalse(store.needsAppStoreConnection)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testStartupMessagesDistinguishConnectionFromCatalogFailure() {
        let error = NSError(domain: "SKInternalErrorDomain", code: 14)
        XCTAssertTrue(AppleGiftStore.startupMessage(error, phase: .appVerification).contains("Connect to App Store"))
        XCTAssertFalse(AppleGiftStore.startupMessage(error, phase: .products).contains("Connect to App Store"))
        XCTAssertFalse(AppleGiftStore.startupMessage(error, phase: .configuration).contains("SKInternalErrorDomain"))
    }

    func testGiftRecipientChoicesExcludeSelfBlockedPeopleAndDuplicateIdentities() {
        let people = [
            GiftRecipient(id: "ME", name: "Me"),
            GiftRecipient(id: "blocked", name: "Blocked"),
            GiftRecipient(id: "friend", name: "Мая 🌸"),
            GiftRecipient(id: "FRIEND", name: "Duplicate"),
            GiftRecipient(id: "other", name: "東京 👋"),
            GiftRecipient(id: "", name: "Missing ID")
        ]
        let choices = GiftRecipient.eligible(people, currentUserID: "me", blockedIDs: ["BLOCKED"])
        XCTAssertEqual(choices.map(\.id), ["friend", "other"])
        XCTAssertEqual(choices.map(\.name), ["Мая 🌸", "東京 👋"])
        XCTAssertTrue(GiftRecipient.eligible([people[0]], currentUserID: "me").isEmpty)
    }

    private func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
}
