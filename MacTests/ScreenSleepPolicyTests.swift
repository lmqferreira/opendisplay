import XCTest

final class ScreenSleepPolicyTests: XCTestCase {
    func testScreenSleepTearsDownOnlyActiveSessions() {
        XCTAssertFalse(ScreenSleepPolicy.shouldTearDown(activeSessions: 0, screenSlept: true))
        XCTAssertFalse(ScreenSleepPolicy.shouldTearDown(activeSessions: 1, screenSlept: false))
        XCTAssertTrue(ScreenSleepPolicy.shouldTearDown(activeSessions: 1, screenSlept: true))
        XCTAssertTrue(ScreenSleepPolicy.shouldTearDown(activeSessions: 3, screenSlept: true))
    }
}
