import XCTest
@testable import ScaleMuleCore

final class AuthStateManagerTests: XCTestCase {
    func testInitialState() async {
        let manager = AuthStateManager()
        let state = await manager.state
        XCTAssertEqual(state, .unknown)
    }

    func testTransition() async {
        let manager = AuthStateManager()
        await manager.transition(to: .loading)
        let state = await manager.state
        XCTAssertEqual(state, .loading)
    }

    func testStreamYieldsCurrentState() async {
        let manager = AuthStateManager()
        await manager.transition(to: .unauthenticated)

        let stream = await manager.stream()
        var states: [AuthState] = []

        for await state in stream {
            states.append(state)
            if states.count == 1 { break }
        }

        XCTAssertEqual(states.first, .unauthenticated)
    }
}
