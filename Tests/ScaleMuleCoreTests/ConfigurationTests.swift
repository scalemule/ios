import XCTest
@testable import ScaleMuleCore

final class ConfigurationTests: XCTestCase {
    func testDefaultConfiguration() {
        let config = Configuration(apiKey: "pk_test_123")
        XCTAssertEqual(config.apiKey, "pk_test_123")
        XCTAssertEqual(config.environment, .production)
        XCTAssertEqual(config.baseURL.absoluteString, "https://api.scalemule.com")
        XCTAssertEqual(config.maxRetries, 2)
        XCTAssertEqual(config.timeoutInterval, 30)
        XCTAssertFalse(config.debug)
    }

    func testDevEnvironment() {
        let config = Configuration(apiKey: "pk_test_123", environment: .development)
        XCTAssertEqual(config.baseURL.absoluteString, "https://api-dev.scalemule.com")
    }

    func testCustomBaseURL() {
        let url = URL(string: "https://custom.example.com")!
        let config = Configuration(apiKey: "pk_test_123", customBaseURL: url)
        XCTAssertEqual(config.environment, .custom)
        XCTAssertEqual(config.baseURL, url)
    }
}
