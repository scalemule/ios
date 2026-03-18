import XCTest
@testable import ScaleMuleCore

final class DateFormattingTests: XCTestCase {
    func testParseISO8601WithFractionalSeconds() {
        let date = DateFormatting.parseISO8601("2026-01-15T10:30:00.000Z")
        XCTAssertNotNil(date)
    }

    func testParseISO8601WithoutFractionalSeconds() {
        let date = DateFormatting.parseISO8601("2026-01-15T10:30:00Z")
        XCTAssertNotNil(date)
    }

    func testParseInvalidDate() {
        let date = DateFormatting.parseISO8601("not-a-date")
        XCTAssertNil(date)
    }
}
