import XCTest
@testable import ScriberCore
import ScriberShared

final class SmokeTests: XCTestCase {
    func testSessionStateAliveness() {
        XCTAssertFalse(SessionState().isAlive())
        XCTAssertTrue(SessionState(heartbeat: Date()).isAlive())
    }
}
