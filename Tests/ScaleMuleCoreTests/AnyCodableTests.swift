import XCTest
@testable import ScaleMuleCore

final class AnyCodableTests: XCTestCase {
    func testEncodeDecodePrimitives() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let values: [AnyCodable] = [
            AnyCodable("hello"),
            AnyCodable(42),
            AnyCodable(3.14),
            AnyCodable(true),
        ]

        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(AnyCodable.self, from: data)
            XCTAssertEqual(value, decoded)
        }
    }

    func testDecodeNull() throws {
        let data = "null".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(decoded.value is NSNull)
    }

    func testEquality() {
        XCTAssertEqual(AnyCodable("a"), AnyCodable("a"))
        XCTAssertNotEqual(AnyCodable("a"), AnyCodable("b"))
        XCTAssertEqual(AnyCodable(1), AnyCodable(1))
        XCTAssertNotEqual(AnyCodable(1), AnyCodable(2))
    }
}
