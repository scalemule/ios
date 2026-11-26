import XCTest
import StoreKit
@testable import ScaleMuleCore
import ScaleMuleTestHelpers
@testable import ScaleMuleCommerce

final class CommerceTests: XCTestCase {
    static let product = #"{"id":"019b0000-0000-7000-8000-000000000001","sku":"wave","display_name":"Wave","description":"A little hello","kind":"both","artwork_url":"https://example.com/wave.png","animation_url":null,"version":1,"currency_code":"COIN","unit_price_minor":10}"#
    static let gift = #"{"id":"019b0000-0000-7000-8000-000000000002","sender_id":"sender","recipient_id":"recipient","product_id":"019b0000-0000-7000-8000-000000000001","environment":"Sandbox","quantity":1,"total_minor":10,"currency_code":"COIN","status":"delivered","product_snapshot":{"display_name":"Wave","artwork_url":"https://example.com/wave.png","animation_url":null,"kind":"both"},"created_at":"2026-11-24T10:00:00Z","delivered_at":"2026-11-24T10:00:01Z"}"#
    private func signedIn() async throws -> CommerceService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let keychain = KeychainStorage(service: "com.scalemule.commerce.tests." + UUID().uuidString)
        let manager = SessionManager(keychain: keychain)
        try await manager.setCredentials(CredentialSet(sessionToken: "buyer-session", sessionExpiresAt: Date().addingTimeInterval(3600)))
        addTeardownBlock { await manager.clear() }
        return CommerceService(client: HTTPClient(config: Configuration(apiKey: "pk_test_commerce", environment: .development, maxRetries: 0),
            sessionManager: manager, workspaceContext: WorkspaceContext(), urlSession: session))
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
    private func contextJSON(_ environment: String, enabled: Bool = true,
                             token: String = "019b0000-1234-7000-8000-000000000001", credits: Int = 100) -> String {
        """
        {"enabled":\(enabled),"environment":"\(environment)","currency_code":"FHC","bundle_id":"com.example.gifts","app_account_token":"\(token)","products":[{"product_id":"credits.100","display_name":"100 Credits","credits_per_unit":\(credits)}]}
        """
    }

    @MainActor
    func testWalletReadsAuthenticatedLedgerWithoutAppleAccount() async throws {
        let commerce = try await signedIn()
        for ledger in [CommerceEnvironment.production, .sandbox] {
            MockURLProtocol.requestHandler = { request in
                XCTAssertEqual(request.url?.path, "/v1/catalog/goods/balance")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer buyer-session")
                XCTAssertTrue(request.url?.query?.contains("environment=\(ledger.rawValue)") == true)
                return TestFixtures.envelopedResponse(json: "{\"id\":\"wallet\",\"currency_code\":\"FHC\",\"available_minor\":80,\"held_minor\":0}")
            }
            let store = AppleGiftStore(commerce: commerce, walletEnvironment: ledger) { _ in
                XCTFail("Reading app credits must not call Apple verification")
                throw URLError(.userAuthenticationRequired)
            }
            guard case .success(let balance) = await store.balance() else { return XCTFail("Wallet did not load") }
            XCTAssertEqual(balance.availableMinor, 80)
            XCTAssertEqual(store.walletEnvironment, ledger)
            XCTAssertNil(store.environment, "A read does not verify or credit an Apple purchase")
        }
    }

    @MainActor
    func testReceivedCollectionStartsWithoutAppleAndRetriesFailureAsRealEmpty() async throws {
        let commerce = try await signedIn()
        let model = ReceivedGiftsModel(commerce: commerce)
        model.start(userID: "me", environment: .sandbox)
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        await model.refresh()
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasLoaded, "Failed reads are not empty collections")
        XCTAssertNotNil(model.errorMessage)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/catalog/goods/gifts")
            XCTAssertTrue(request.url?.query?.contains("environment=Sandbox") == true)
            return TestFixtures.envelopedResponse(json: "[]")
        }
        await model.refresh()
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.gifts.isEmpty)
    }

    func testInteractiveReadDeadlineCancelsStalledRequestAndAllowsRetry() async {
        let start = Date()
        let result: ApiResponse<Int> = await CommerceService.withReadDeadline(seconds: 0.03) {
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { return .failure(ApiError(code: .networkError, message: "Cancelled")) }
            return .success(42)
        }
        guard case .failure(let error) = result else { return XCTFail("Stalled request should time out") }
        XCTAssertEqual(error.code, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let retry: ApiResponse<Int> = await CommerceService.withReadDeadline { .success(42) }
        guard case .success(let value) = retry else { return XCTFail("Retry should succeed") }
        XCTAssertEqual(value, 42)
    }

    @MainActor
    func testMissingAppReceiptStillLoadsCreditPacksWithoutChoosingWalletEnvironment() async throws {
        let commerce = try await signedIn()
        var refreshRequests: [Bool] = []
        var contexts: [String] = []
        var productRequests: [[String]] = []
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/money/billing/app-store/context")
            let environment = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "environment" }!.value!
            contexts.append(environment)
            return TestFixtures.envelopedResponse(json: self.contextJSON(environment))
        }
        let store = AppleGiftStore(commerce: commerce, bundleID: "com.example.gifts", loadProducts: { ids in
            productRequests.append(ids); return []
        }) { refresh in
            refreshRequests.append(refresh)
            throw NSError(domain: "SKInternalErrorDomain", code: 14)
        }
        await store.start()
        XCTAssertEqual(refreshRequests, [], "Opening checkout does not request an app-download receipt")
        XCTAssertEqual(contexts, ["Production", "Sandbox"])
        XCTAssertEqual(productRequests, [["credits.100"]])
        XCTAssertFalse(store.needsAppStoreConnection)
        XCTAssertTrue(store.enabled)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.environment, "Product loading never verifies a purchase")
        XCTAssertEqual(store.walletEnvironment, .production)
        XCTAssertTrue(store.offers.isEmpty)
        XCTAssertFalse(store.message?.contains("SKInternalErrorDomain") == true)
        await store.connectToAppStore()
        XCTAssertEqual(refreshRequests, [true], "Only a legacy explicit action refreshes Apple's app transaction")
        XCTAssertNil(store.environment)
        store.stop()
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(store.needsAppStoreConnection)
        XCTAssertNil(store.message)
    }

    @MainActor
    func testCatalogCanBeBrowsedWithoutStartingAppleVerificationOrReadingBalance() async throws {
        let commerce = try await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/catalog/goods/products")
            XCTAssertTrue(request.url?.query?.contains("environment=Production") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer buyer-session")
            return TestFixtures.envelopedResponse(json: "[" + Self.product + "]")
        }
        let store = AppleGiftStore(commerce: commerce) { _ in
            XCTFail("Catalog browsing must not depend on Apple account verification")
            throw URLError(.userAuthenticationRequired)
        }
        let response = await store.catalogProducts()
        guard case .success(let gifts) = response else { return XCTFail("Catalog did not load") }
        XCTAssertEqual(gifts.first?.displayName, "Wave")
        XCTAssertNil(store.environment)
        XCTAssertFalse(store.enabled)
    }

    @MainActor
    func testUnverifiedEnvironmentNeverEnablesCheckoutInOnlyOneEnvironment() async throws {
        let commerce = try await signedIn()
        var requested: [String] = []
        MockURLProtocol.requestHandler = { request in
            let env = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "environment" }!.value!
            return TestFixtures.envelopedResponse(json: self.contextJSON(env, enabled: env == "Production"))
        }
        let store = AppleGiftStore(commerce: commerce, bundleID: "com.example.gifts", loadProducts: { ids in requested += ids; return [] }) { _ in
            throw URLError(.userAuthenticationRequired)
        }
        await store.start()
        XCTAssertFalse(store.enabled)
        XCTAssertTrue(requested.isEmpty)
        XCTAssertNil(store.environment)
        store.stop()
    }

    @MainActor
    func testCheckoutBootstrapRejectsDifferentAccountBindings() async throws {
        let commerce = try await signedIn()
        MockURLProtocol.requestHandler = { request in
            let env = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "environment" }!.value!
            let token = env == "Production" ? "019b0000-1234-7000-8000-000000000001" : "019b0000-1234-7000-8000-000000000002"
            return TestFixtures.envelopedResponse(json: self.contextJSON(env, token: token))
        }
        let store = AppleGiftStore(commerce: commerce, bundleID: "com.example.gifts", loadProducts: { _ in
            XCTFail("Account mismatch must never reach StoreKit products"); return []
        }) { _ in throw URLError(.userAuthenticationRequired) }
        await store.start()
        XCTAssertFalse(store.enabled)
        XCTAssertNil(store.environment)
        XCTAssertTrue(store.offers.isEmpty)
        store.stop()
    }

    @MainActor
    func testCheckoutPacksRequireMatchingCreditQuantitiesAndVerifiedEnvironmentMapping() throws {
        let production = try JSONDecoder().decode(ApplePurchaseContext.self, from: Data(contextJSON("Production").utf8))
        let sandbox = try JSONDecoder().decode(ApplePurchaseContext.self, from: Data(contextJSON("Sandbox", credits: 999).utf8))
        XCTAssertTrue(AppleGiftStore.sharedPacks(production, sandbox).isEmpty)
        XCTAssertFalse(AppleGiftStore.validContext(production, environment: .sandbox, bundleID: "com.example.gifts"))
        XCTAssertFalse(AppleGiftStore.validContext(production, environment: .production, bundleID: "com.other.app"))
        XCTAssertFalse(AppleGiftStore.validContext(production, environment: .production, bundleID: nil))
        XCTAssertEqual(AppleGiftStore.commerceEnvironment(.production), .production)
        XCTAssertEqual(AppleGiftStore.commerceEnvironment(.sandbox), .sandbox)
        XCTAssertNil(AppleGiftStore.commerceEnvironment(.xcode))
    }

    @MainActor
    func testExplicitlyUnverifiedAndLocalReceiptsCannotBootstrapCheckout() async throws {
        let commerce = try await signedIn()
        MockURLProtocol.requestHandler = { _ in
            XCTFail("An invalid receipt must not bootstrap checkout")
            throw URLError(.badServerResponse)
        }
        for error in [CommerceError.unverified, .localStoreUnsupported] {
            let store = AppleGiftStore(commerce: commerce) { _ in throw error }
            await store.connectToAppStore()
            XCTAssertFalse(store.enabled)
            XCTAssertNil(store.environment)
            XCTAssertTrue(store.offers.isEmpty)
            store.stop()
        }
    }

    @MainActor
    func testLogoutDuringCheckoutBootstrapDiscardsOldAccountContext() async throws {
        let commerce = try await signedIn()
        let started = expectation(description: "context started")
        let release = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { _ in
            started.fulfill()
            guard release.wait(timeout: .now() + 3) == .success else { throw URLError(.timedOut) }
            return TestFixtures.envelopedResponse(json: self.contextJSON("Production"))
        }
        let store = AppleGiftStore(commerce: commerce, bundleID: "com.example.gifts", loadProducts: { _ in
            XCTFail("Old account must not load products after logout"); return []
        }) { _ in throw URLError(.userAuthenticationRequired) }
        let initial = Task { await store.start() }
        await fulfillment(of: [started], timeout: 2)
        store.stop()
        release.signal()
        await initial.value
        XCTAssertNil(store.environment)
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(store.needsAppStoreConnection)
        XCTAssertFalse(store.isLoading)
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
        let initial = Task { await store.connectToAppStore() }
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
        XCTAssertTrue(AppleGiftStore.startupMessage(error, phase: .appVerification).contains("Check your Apple account"))
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
        let ownID = "019b0000-1234-7000-8000-000000000001"
        let compactID = ownID.replacingOccurrences(of: "-", with: "").uppercased()
        XCTAssertTrue(GiftRecipient.eligible([GiftRecipient(id: compactID, name: "Me")], currentUserID: ownID).isEmpty)
        XCTAssertTrue(GiftRecipient.eligible([GiftRecipient(id: compactID, name: "Blocked")], currentUserID: "another", blockedIDs: [ownID]).isEmpty)
    }

    private func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    private func gift(id: String, sender: String, recipient: String, status: String = "delivered") throws -> DigitalGift {
        try JSONDecoder().decode(DigitalGift.self, from: Data("""
        {"id":"\(id)","sender_id":"\(sender)","recipient_id":"\(recipient)","product_id":"p","environment":"Sandbox","quantity":1,"total_minor":20,"currency_code":"FHC","status":"\(status)","product_snapshot":{"display_name":"Coffee","artwork_url":"https://example.com/coffee.png","kind":"both"},"created_at":"2026-11-25T08:07:47.681Z","delivered_at":"2026-11-25T08:07:47.888123Z"}
        """.utf8))
    }
    @MainActor
    func testReceivedGiftsAreOnlyDeliveredGiftsFromOthersNewestFirst() throws {
        let me = "019D0E79-7B2E-7EB3-99DB-153B557F16CC"
        let all = [
            try gift(id: "01a211bf-0000-7000-8000-000000000001", sender: "other", recipient: "019d0e79-7b2e-7eb3-99db-153b557f16cc"),
            try gift(id: "01a211bf-0000-7000-8000-000000000003", sender: "other", recipient: "019d0e79-7b2e-7eb3-99db-153b557f16cc"),
            try gift(id: "01a211bf-0000-7000-8000-000000000002", sender: "019d0e79-7b2e-7eb3-99db-153b557f16cc", recipient: "other"),
            try gift(id: "01a211bf-0000-7000-8000-000000000004", sender: "other", recipient: "019d0e79-7b2e-7eb3-99db-153b557f16cc", status: "pending"),
            try gift(id: "01a211bf-0000-7000-8000-000000000003", sender: "other", recipient: "019d0e79-7b2e-7eb3-99db-153b557f16cc"),
        ]
        let received = ReceivedGiftsModel.received(all, userID: me)
        XCTAssertEqual(received.map(\.id), ["01a211bf-0000-7000-8000-000000000003", "01a211bf-0000-7000-8000-000000000001"])
        XCTAssertEqual(ReceivedGiftsModel.unseen(received, after: nil).count, 2)
        XCTAssertEqual(ReceivedGiftsModel.unseen(received, after: "01A211BF-0000-7000-8000-000000000001").map(\.id), ["01a211bf-0000-7000-8000-000000000003"])
        XCTAssertTrue(ReceivedGiftsModel.unseen(received, after: "01a211bf-0000-7000-8000-000000000003").isEmpty)
    }
    @MainActor
    func testNewGiftIsAnnouncedOnceAndRememberedAcrossRelaunch() async throws {
        let commerce = try await signedIn()
        let suite = "received-gifts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var newest = "01a211bf-0000-7000-8000-000000000001"
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/catalog/goods/gifts")
            XCTAssertTrue(request.url?.query?.contains("environment=Sandbox") == true)
            return TestFixtures.envelopedResponse(json: "[{\"id\":\"\(newest)\",\"sender_id\":\"friend\",\"recipient_id\":\"me\",\"product_id\":\"p\",\"environment\":\"Sandbox\",\"quantity\":1,\"total_minor\":20,\"currency_code\":\"FHC\",\"status\":\"delivered\",\"product_snapshot\":{\"display_name\":\"Coffee\",\"artwork_url\":\"https://example.com/coffee.png\",\"kind\":\"both\"},\"created_at\":\"2026-11-25T08:07:47.681Z\",\"delivered_at\":null}]")
        }
        let model = ReceivedGiftsModel(commerce: commerce, defaults: defaults)
        await model.refresh(environment: .sandbox)
        XCTAssertFalse(model.hasLoaded, "Nothing loads before sign-in starts the model")
        model.start(userID: "me")
        await model.refresh(environment: .sandbox)
        XCTAssertEqual(model.unseen.map(\.id), [newest])
        model.markSeen()
        XCTAssertTrue(model.unseen.isEmpty)

        let relaunched = ReceivedGiftsModel(commerce: commerce, defaults: defaults)
        relaunched.start(userID: "me")
        await relaunched.refresh(environment: .sandbox)
        XCTAssertEqual(relaunched.gifts.count, 1)
        XCTAssertTrue(relaunched.unseen.isEmpty, "A gift already shown is not announced again")

        newest = "01a211bf-0000-7000-8000-000000000009"
        await relaunched.refresh(environment: .sandbox)
        XCTAssertEqual(relaunched.unseen.map(\.id), [newest])
        // Another account on the same device has its own record.
        let other = ReceivedGiftsModel(commerce: commerce, defaults: defaults)
        other.start(userID: "someone-else")
        await other.refresh(environment: .sandbox)
        XCTAssertTrue(other.gifts.isEmpty)
    }
    func testGiftSentencesAndDates() throws {
        XCTAssertEqual(GiftText.sent("Plamen", gift: "Coffee"), "Plamen sent you a Coffee")
        XCTAssertEqual(GiftText.sent("Мария", gift: "Ice Cream"), "Мария sent you an Ice Cream")
        XCTAssertEqual(GiftText.sent("太郎 🎁", gift: "The World"), "太郎 🎁 sent you The World")
        let delivered = try XCTUnwrap(try gift(id: "g", sender: "a", recipient: "b").arrivedDate)
        XCTAssertEqual(delivered.timeIntervalSince1970, 1795594067, accuracy: 1)
        XCTAssertNotNil(DigitalGift.date("2026-11-25T08:07:47Z"))
        XCTAssertEqual(GiftText.from("Plamen", date: delivered, now: delivered.addingTimeInterval(-5)), "From Plamen · just now")
        XCTAssertEqual(GiftText.from("Plamen", date: nil), "From Plamen")
    }

    func testACreditPackNameThatOnlyRepeatsItsNumberIsLeftOut() {
        XCTAssertFalse(CreditPackRow.nameAddsSomething("100 Firehosy Credits", credits: 100))
        XCTAssertFalse(CreditPackRow.nameAddsSomething("1,200 Credits", credits: 1200))
        XCTAssertFalse(CreditPackRow.nameAddsSomething("  ", credits: 100))
        XCTAssertTrue(CreditPackRow.nameAddsSomething("Best value", credits: 500))
        XCTAssertTrue(CreditPackRow.nameAddsSomething("Starter pack 2", credits: 100))
    }
    @MainActor
    func testCollectionPagesPast150SentGiftsAndRefreshKeepsOlderPages() async throws {
        let commerce = try await signedIn()
        let model = ReceivedGiftsModel(commerce: commerce)
        model.start(userID: "me")
        let pages = (0..<6).map { page in
            (0..<30).map { offset in
                let number = 1000 - page * 30 - offset
                let receiver = page == 5 ? "me" : "friend"
                let sender = page == 5 ? "friend" : "me"
                return Self.gift.replacingOccurrences(of: "019b0000-0000-7000-8000-000000000002", with: String(format: "%04d", number))
                    .replacingOccurrences(of: "\"sender\"", with: "\"\(sender)\"")
                    .replacingOccurrences(of: "\"recipient\"", with: "\"\(receiver)\"")
            }
        }
        MockURLProtocol.requestHandler = { request in
            let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before" }?.value
            let page = before.flatMap(Int.init).map { (1000 - $0 + 1) / 30 } ?? 0
            let rows = page < pages.count ? pages[page] : []
            return TestFixtures.envelopedResponse(json: "[" + rows.joined(separator: ",") + "]")
        }
        await model.refresh(environment: .sandbox)
        XCTAssertTrue(model.gifts.isEmpty)
        XCTAssertTrue(model.hasMore, "An outgoing-heavy history must not hide older incoming gifts forever")
        await model.loadMore()
        XCTAssertEqual(model.gifts.count, 30)
        await model.loadMore()
        XCTAssertFalse(model.hasMore)
        await model.refresh(environment: .sandbox)
        XCTAssertEqual(model.gifts.count, 30, "Refreshing recent history preserves already loaded older pages")
        XCTAssertFalse(model.hasMore)
    }

    @MainActor
    func testDismissalOnlyAcknowledgesPresentedGiftsIncludingLateDelivery() async throws {
        let commerce = try await signedIn()
        let suite = "gift-exact-seen-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var ids = ["0002"]
        MockURLProtocol.requestHandler = { _ in
            let rows = ids.map { Self.gift.replacingOccurrences(of: "019b0000-0000-7000-8000-000000000002", with: $0) }
            return TestFixtures.envelopedResponse(json: "[" + rows.joined(separator: ",") + "]")
        }
        let model = ReceivedGiftsModel(commerce: commerce, defaults: defaults)
        model.start(userID: "recipient")
        await model.refresh(environment: .sandbox)
        let shown = model.unseen.map(\.id)
        ids = ["0003", "0002", "0001"] // newer arrival + an older gift delivered late
        await model.refresh(environment: .sandbox)
        model.markSeen(giftIDs: shown)
        XCTAssertEqual(model.unseen.map(\.id), ["0003", "0001"])
        let relaunched = ReceivedGiftsModel(commerce: commerce, defaults: defaults)
        relaunched.start(userID: "recipient")
        await relaunched.refresh(environment: .sandbox)
        XCTAssertEqual(relaunched.unseen.map(\.id), ["0003", "0001"])
    }

    @MainActor
    func testFailedRefreshKeepsCollectionAndEnvironmentChangeClearsIt() async throws {
        let commerce = try await signedIn()
        let model = ReceivedGiftsModel(commerce: commerce)
        model.start(userID: "recipient")
        MockURLProtocol.requestHandler = { _ in TestFixtures.envelopedResponse(json: "[" + Self.gift + "]") }
        await model.refresh(environment: .sandbox)
        XCTAssertEqual(model.gifts.count, 1)
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data(#"{"success":false,"error":{"code":"FORBIDDEN","message":"Unavailable"}}"#.utf8))
        }
        await model.refresh(environment: .sandbox)
        XCTAssertEqual(model.gifts.count, 1)
        XCTAssertNotNil(model.errorMessage)
        await model.refresh(environment: .production)
        XCTAssertTrue(model.gifts.isEmpty, "Sandbox gifts must not leak into Production")
        XCTAssertFalse(model.hasLoaded)
        model.start(userID: "other")
        XCTAssertTrue(model.unseen.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

}
