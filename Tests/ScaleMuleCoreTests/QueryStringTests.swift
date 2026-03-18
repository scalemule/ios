import XCTest
@testable import ScaleMuleCore

final class QueryStringTests: XCTestCase {
    func testBuildWithValues() {
        let items = QueryString.build(["page": "1", "per_page": "20"])
        XCTAssertEqual(items.count, 2)
    }

    func testBuildSkipsNils() {
        let items = QueryString.build(["page": "1", "filter": nil])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "page")
    }

    func testBuildEmpty() {
        let items = QueryString.build([:])
        XCTAssertTrue(items.isEmpty)
    }
}
