import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleEntities

final class EntityRecordsServiceTests: XCTestCase {
    private static let visitJSON = """
    {
        "id": "01a21710-4c11-72b0-ad40-05a441fc2b95",
        "entity_id": "pet-1",
        "collection": "health",
        "data": {"type": "vet visit", "note": "Ваксина бяс · 狂犬病疫苗 🐾", "weight_kg": 12.4},
        "version": 2,
        "created_by": "user-a",
        "updated_by": "user-b",
        "created_at": "2026-11-26T10:00:00Z",
        "updated_at": "2026-11-26T11:00:00Z"
    }
    """

    private func signedIn() async -> EntityRecordsService {
        let (app, _) = createTestClient()
        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)
        return EntityRecordsService(client: app.client)
    }

    func testCreateSendsTheChosenIdAndDecodesTheRecord() async {
        let records = await signedIn()
        let id = EntityRecord.newID()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/data/entities/pet-1/health/documents")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["id"] as? String, id)
            XCTAssertEqual((body["data"] as? [String: Any])?["note"] as? String, "Ваксина бяс · 狂犬病疫苗 🐾")
            return TestFixtures.envelopedResponse(json: Self.visitJSON)
        }
        let result = await records.create(
            entityId: "pet-1",
            collection: "health",
            data: ["type": "vet visit", "note": "Ваксина бяс · 狂犬病疫苗 🐾"],
            id: id
        )
        let visit = assertApiSuccess(result)
        XCTAssertEqual(visit?.string("note"), "Ваксина бяс · 狂犬病疫苗 🐾")
        XCTAssertNil(visit?.string("weight_kg"), "not text")
        XCTAssertEqual(visit?.version, 2)
        XCTAssertEqual(visit?.entityId, "pet-1")
        XCTAssertEqual(visit?.createdBy, "user-a")
        XCTAssertEqual(visit?.updatedBy, "user-b")
    }

    func testCreateWithoutAnIdStillSendsOne() async {
        let records = await signedIn()
        MockURLProtocol.requestHandler = { request in
            let sent = self.bodyJSON(request)?["id"] as? String
            XCTAssertNotNil(sent.flatMap { UUID(uuidString: $0) }, "a UUID the retries of this call share")
            return TestFixtures.envelopedResponse(json: Self.visitJSON)
        }
        let created = await records.create(entityId: "pet-1", collection: "health", data: ["a": 1])
        XCTAssertNotNil(assertApiSuccess(created))
    }

    func testNewIdsAreVersion7AndSortByTime() {
        let early = EntityRecord.newID(now: Date(timeIntervalSince1970: 1_700_000_000))
        let late = EntityRecord.newID(now: Date(timeIntervalSince1970: 1_800_000_000))
        for id in [early, late] {
            XCTAssertNotNil(UUID(uuidString: id), id)
            XCTAssertEqual(id, id.lowercased())
            let parts = id.split(separator: "-")
            XCTAssertEqual(parts.map(\.count), [8, 4, 4, 4, 12])
            XCTAssertEqual(parts[2].first, "7", "version 7")
            XCTAssertTrue(["8", "9", "a", "b"].contains(String(parts[3].prefix(1))), "RFC variant")
        }
        XCTAssertLessThan(early, late)
        XCTAssertNotEqual(EntityRecord.newID(), EntityRecord.newID())
        // 1,700,000,000,000 ms = 0x018bcfe56800
        XCTAssertTrue(early.hasPrefix("018bcfe5-6800-7"), early)
    }

    func testListPagesNewestFirst() async {
        let records = await signedIn()
        let seen = Counter()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/data/entities/pet-1/health/documents")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "100")
            let before = query.first { $0.name == "before" }?.value
            if seen.next() == 1 {
                XCTAssertNil(before)
                return TestFixtures.envelopedResponse(json: """
                {"records": [\(Self.visitJSON)], "next_cursor": "01a21710-4c11-72b0-ad40-05a441fc2b95"}
                """)
            }
            XCTAssertEqual(before, "01a21710-4c11-72b0-ad40-05a441fc2b95")
            return TestFixtures.envelopedResponse(json: """
            {"records": [{"id": "older", "data": {}}]}
            """)
        }
        let all = assertApiSuccess(await records.all(entityId: "pet-1", collection: "health"))
        XCTAssertEqual(all?.map(\.id), ["01a21710-4c11-72b0-ad40-05a441fc2b95", "older"])
        XCTAssertEqual(all?.last?.version, 1, "missing fields have defaults")
        XCTAssertEqual(seen.value, 2)
    }

    func testUpdateSendsTheVersionAndAConflictKeepsItsCode() async {
        let records = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/v1/data/entities/pet-1/health/documents/rec-1")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["version"] as? Int, 2)
            let data = body["data"] as? [String: Any]
            XCTAssertEqual(data?["weight_kg"] as? Double, 12.6)
            XCTAssertTrue(data?["clinic"] is NSNull, "a removed field is sent as null")
            return TestFixtures.mockResponse(statusCode: 409, json: """
            {"success": false, "error": {"code": "ENTITY_RECORD_VERSION_CONFLICT", "message": "Someone else changed this in the meantime. Load it again and repeat your change."}, "meta": {}}
            """)
        }
        let result = await records.update(
            entityId: "pet-1",
            collection: "health",
            id: "rec-1",
            data: ["weight_kg": 12.6, "clinic": NSNull()],
            version: 2
        )
        let error = assertApiFailure(result)
        XCTAssertEqual(error?.rawCode, EntityErrorCode.recordVersionConflict)
        XCTAssertEqual(error?.message, "Someone else changed this in the meantime. Load it again and repeat your change.")
    }

    func testGetAndDelete() async {
        let records = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/data/entities/pet-1/health/documents/rec-1")
            if request.httpMethod == "DELETE" {
                return TestFixtures.envelopedResponse(json: "{\"deleted\": true}")
            }
            XCTAssertEqual(request.httpMethod, "GET")
            return TestFixtures.envelopedResponse(json: Self.visitJSON)
        }
        let loaded = await records.get(entityId: "pet-1", collection: "health", id: "rec-1")
        XCTAssertNotNil(assertApiSuccess(loaded))
        let removed = await records.delete(entityId: "pet-1", collection: "health", id: "rec-1")
        XCTAssertNotNil(assertApiSuccess(removed))
    }

    func testAPersonWhoNoLongerManagesTheEntityGetsNotFound() async {
        let records = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 404, json: """
            {"success": false, "error": {"code": "ENTITY_NOT_FOUND", "message": "This was not found, or you no longer have access to it."}, "meta": {}}
            """)
        }
        let error = assertApiFailure(await records.list(entityId: "pet-1", collection: "health"))
        XCTAssertEqual(error?.rawCode, EntityErrorCode.notFound)
        XCTAssertEqual(error?.statusCode, 404)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
