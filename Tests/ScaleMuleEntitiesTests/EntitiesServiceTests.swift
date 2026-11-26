import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleEntities

final class EntitiesServiceTests: XCTestCase {
    private static let petJSON = """
    {
        "id": "019a0000-0000-7000-8000-000000000001",
        "kind": "pet",
        "name": "Мурка 🐈",
        "visibility": "public",
        "attributes": {"species": "cat", "born": "2021-03-04", "weight_kg": 4.2, "tags": ["indoor"]},
        "member_count": 2,
        "version": 3,
        "created_by": "019a0000-0000-7000-8000-0000000000aa",
        "created_at": "2026-11-25T10:00:00Z",
        "updated_at": "2026-11-25T11:00:00Z",
        "my_role": "owner"
    }
    """

    private func signedIn() async -> EntitiesService {
        let (app, _) = createTestClient()
        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)
        return EntitiesService(client: app.client)
    }

    func testCreateSendsTheIdempotencyKeyAndDecodesTheCard() async {
        let entities = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/accounts/entities")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["kind"] as? String, "pet")
            XCTAssertEqual(body["name"] as? String, "Мурка 🐈")
            XCTAssertEqual(body["idempotency_key"] as? String, "form-1")
            XCTAssertEqual((body["attributes"] as? [String: Any])?["species"] as? String, "cat")
            XCTAssertEqual(body["visibility"] as? String, "public")
            return TestFixtures.envelopedResponse(json: Self.petJSON)
        }

        let result = await entities.create(
            kind: "pet",
            name: "Мурка 🐈",
            attributes: ["species": "cat"],
            visibility: .everyone,
            idempotencyKey: "form-1"
        )
        let pet = assertApiSuccess(result)
        XCTAssertEqual(pet?.name, "Мурка 🐈")
        XCTAssertEqual(pet?.myRole, .owner)
        XCTAssertEqual(pet?.isPublic, true)
        XCTAssertEqual(pet?.string("species"), "cat")
        XCTAssertNil(pet?.string("weight_kg"), "not text")
        XCTAssertEqual(pet?.version, 3)
        XCTAssertEqual(pet?.memberCount, 2)
    }

    func testACardFromSomeoneElseHasNoRole() async {
        let entities = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/accounts/entities/pet-1")
            return TestFixtures.envelopedResponse(json: """
            {"id": "pet-1", "kind": "pet", "name": "Rex", "visibility": "public", "attributes": {},
             "member_count": 1, "version": 1, "created_by": "u", "created_at": "t", "updated_at": "t"}
            """)
        }
        let pet = assertApiSuccess(await entities.get(id: "pet-1"))
        XCTAssertNil(pet?.myRole)
        XCTAssertEqual(pet?.attributes.isEmpty, true)
    }

    func testMineFollowsPages() async {
        let entities = await signedIn()
        var calls = 0
        MockURLProtocol.requestHandler = { request in
            calls += 1
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(query.contains(URLQueryItem(name: "kind", value: "pet")))
            if calls == 1 {
                XCTAssertFalse(query.contains { $0.name == "after" })
                return TestFixtures.envelopedResponse(json: """
                {"entities": [\(Self.petJSON)], "next_cursor": "pet:019a0000-0000-7000-8000-000000000001"}
                """)
            }
            XCTAssertTrue(query.contains(URLQueryItem(name: "after", value: "pet:019a0000-0000-7000-8000-000000000001")))
            return TestFixtures.envelopedResponse(json: "{\"entities\": [\(Self.petJSON)]}")
        }
        let all = assertApiSuccess(await entities.allMine(kind: "pet"))
        XCTAssertEqual(all?.count, 2)
        XCTAssertEqual(calls, 2)
    }

    func testLookupSendsDistinctIdsAndSkipsTheCallWhenEmpty() async {
        let entities = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            XCTFail("no ids, no call")
            return TestFixtures.envelopedResponse(json: "{\"entities\": []}")
        }
        let none = await entities.lookup(ids: [])
        XCTAssertEqual(assertApiSuccess(none)?.count, 0)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/accounts/entities/lookup")
            let ids = self.bodyJSON(request)?["ids"] as? [String]
            XCTAssertEqual(ids?.sorted(), ["a", "b"])
            return TestFixtures.envelopedResponse(json: "{\"entities\": [\(Self.petJSON)]}")
        }
        let found = await entities.lookup(ids: ["a", "b", "a"])
        XCTAssertEqual(assertApiSuccess(found)?.count, 1)
    }

    func testUpdateSendsOnlyWhatChangedAndCanRemoveAnAttribute() async {
        let entities = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = self.bodyJSON(request)!
            XCTAssertNil(body["name"])
            XCTAssertNil(body["visibility"])
            XCTAssertEqual(body["version"] as? Int, 3)
            let attributes = body["attributes"] as? [String: Any]
            XCTAssertEqual(attributes?["breed"] as? String, "сибирская")
            XCTAssertTrue(attributes?["born"] is NSNull)
            return TestFixtures.envelopedResponse(json: Self.petJSON)
        }
        let result = await entities.update(
            id: "pet-1",
            attributes: ["breed": "сибирская", "born": NSNull()],
            version: 3
        )
        XCTAssertNotNil(assertApiSuccess(result))
    }

    func testARefusalKeepsItsCodeAndSentence() async {
        let entities = await signedIn()
        MockURLProtocol.requestHandler = { _ in
            TestFixtures.mockResponse(statusCode: 409, json: """
            {"success": false, "error": {"code": "ENTITY_LAST_OWNER", "message": "You are the only owner. Make someone else an owner first."}, "meta": {}}
            """)
        }
        let error = assertApiFailure(await entities.removeMember(entityId: "pet-1", userId: "me"))
        XCTAssertEqual(error?.rawCode, EntityErrorCode.lastOwner)
        XCTAssertEqual(error?.message, "You are the only owner. Make someone else an owner first.")
        XCTAssertEqual(error?.statusCode, 409)
    }

    func testMembersAndRoleChange() async {
        let entities = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/accounts/entities/pet-1/members")
            return TestFixtures.envelopedResponse(json: """
            {"members": [
              {"user_id": "u1", "role": "owner", "added_by": "u1", "joined_at": "2026-11-25T10:00:00Z"},
              {"user_id": "u2", "role": "caretaker", "joined_at": "2026-11-25T10:05:00Z"}
            ]}
            """)
        }
        let people = assertApiSuccess(await entities.members(entityId: "pet-1"))
        XCTAssertEqual(people?.map(\.role), [.owner, EntityRole(rawValue: "caretaker")])
        XCTAssertEqual(people?.last?.role.rank, 0, "a role this version does not know still decodes")

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/v1/accounts/entities/pet-1/members/u2")
            XCTAssertEqual(self.bodyJSON(request)?["role"] as? String, "admin")
            return TestFixtures.envelopedResponse(json: "{\"updated\": true}")
        }
        let changed = await entities.setRole(entityId: "pet-1", userId: "u2", role: .admin)
        XCTAssertTrue(changed.isSuccess)
    }

    func testInviteByLinkAndTheTokenStaysOutOfThePath() async {
        let entities = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/accounts/entities/pet-1/invitations")
            let body = self.bodyJSON(request)!
            XCTAssertEqual(body["role"] as? String, "member")
            XCTAssertNil(body["invitee_user_id"])
            XCTAssertEqual(body["expires_in_hours"] as? Int, 48)
            return TestFixtures.envelopedResponse(json: """
            {"id": "inv-1", "entity_id": "pet-1", "role": "member", "token": "smei_abc", "expires_at": "2026-11-27T10:00:00Z"}
            """)
        }
        let issued = assertApiSuccess(await entities.invite(entityId: "pet-1", role: .member, expiresInHours: 48))
        XCTAssertEqual(issued?.token, "smei_abc")
        XCTAssertNil(issued?.inviteeUserId)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/accounts/entity-invitations/accept")
            XCTAssertFalse(request.url!.absoluteString.contains("smei_abc"))
            XCTAssertEqual(self.bodyJSON(request)?["token"] as? String, "smei_abc")
            return TestFixtures.envelopedResponse(json: "{\"entity\": \(Self.petJSON), \"already_member\": false}")
        }
        let joined = assertApiSuccess(await entities.acceptInvitation(token: "smei_abc"))
        XCTAssertEqual(joined?.alreadyMember, false)
        XCTAssertEqual(joined?.entity.kind, "pet")
    }

    func testReceivedInvitationsAndPreview() async {
        let entities = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/accounts/entity-invitations")
            return TestFixtures.envelopedResponse(json: """
            {"invitations": [{"id": "inv-2", "role": "viewer", "invited_by": "u1", "expires_at": "t", "created_at": "t",
              "entity_id": "pet-1", "kind": "pet", "name": "Rex", "attributes": {"species": "dog"}}]}
            """)
        }
        let received = assertApiSuccess(await entities.receivedInvitations())
        XCTAssertEqual(received?.first?.name, "Rex")
        XCTAssertEqual(received?.first?.role, .viewer)

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/accounts/entity-invitations/preview")
            return TestFixtures.envelopedResponse(json: """
            {"invitation_id": "inv-1", "role": "member", "invited_by": "u1", "expires_at": "t",
             "entity": \(Self.petJSON), "already_member": true}
            """)
        }
        let preview = assertApiSuccess(await entities.previewInvitation(token: "smei_abc"))
        XCTAssertEqual(preview?.alreadyMember, true)
        XCTAssertEqual(preview?.entity.name, "Мурка 🐈")
    }

    func testKinds() async {
        let entities = await signedIn()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/v1/accounts/entity-kinds")
            return TestFixtures.envelopedResponse(json: """
            {"kinds": [{"kind": "pet", "display_name": "Pet", "status": "active", "end_user_create": true,
              "default_visibility": "public", "max_owned_per_user": 20, "max_members": 10,
              "max_pending_invitations": 10, "invitation_ttl_hours": 168, "attributes_max_bytes": 8192}]}
            """)
        }
        let kinds = assertApiSuccess(await entities.kinds())
        XCTAssertEqual(kinds?.first?.kind, "pet")
        XCTAssertEqual(kinds?.first?.maxMembers, 10)
    }

    func testRoleRules() {
        XCTAssertTrue(EntityRole.owner > .admin)
        XCTAssertTrue(EntityRole.admin > .member)
        XCTAssertTrue(EntityRole.member > .viewer)
        XCTAssertTrue(EntityRole.member.canEdit)
        XCTAssertFalse(EntityRole.viewer.canEdit)
        XCTAssertTrue(EntityRole.admin.canManage)
        XCTAssertFalse(EntityRole.member.canManage)
        XCTAssertTrue(EntityRole.owner.canDelete)
        XCTAssertFalse(EntityRole.admin.canDelete)

        XCTAssertTrue(EntityRole.owner.canInvite(as: .admin))
        XCTAssertFalse(EntityRole.owner.canInvite(as: .owner))
        XCTAssertTrue(EntityRole.admin.canInvite(as: .member))
        XCTAssertFalse(EntityRole.admin.canInvite(as: .admin))
        XCTAssertFalse(EntityRole.member.canInvite(as: .viewer))
        XCTAssertFalse(EntityRole.owner.canInvite(as: EntityRole(rawValue: "caretaker")))

        XCTAssertTrue(EntityRole.owner.canChange(someoneWith: .admin))
        XCTAssertFalse(EntityRole.owner.canChange(someoneWith: .owner))
        XCTAssertTrue(EntityRole.admin.canChange(someoneWith: .viewer))
        XCTAssertFalse(EntityRole.admin.canChange(someoneWith: .admin))
    }
}
