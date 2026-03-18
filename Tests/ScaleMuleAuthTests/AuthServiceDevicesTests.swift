import XCTest
import ScaleMuleTestHelpers
@testable import ScaleMuleCore
@testable import ScaleMuleAuth

final class AuthServiceDevicesTests: XCTestCase {
    func testListDevices() async {
        let (app, _) = createTestClient()
        let auth = AuthService(client: app.client)

        let creds = CredentialSet(sessionToken: "sess_123", sessionExpiresAt: Date().addingTimeInterval(3600))
        try? await app.sessionManager.setCredentials(creds)

        MockURLProtocol.requestHandler = { _ in
            TestFixtures.envelopedResponse(json: TestFixtures.devicesListJSON)
        }

        let result = await auth.devices.list()

        let devices = assertApiSuccess(result)
        XCTAssertEqual(devices?.total, 1)
        XCTAssertEqual(devices?.devices.first?.name, "iPhone")
        XCTAssertEqual(devices?.devices.first?.trusted, true)
    }
}
