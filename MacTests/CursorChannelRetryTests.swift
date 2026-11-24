import XCTest

final class CursorChannelRetryTests: XCTestCase {
    func testRetriesAreFinite() {
        var retry = CursorChannelRetry()
        for expected in 1...CursorChannelRetry.maximumAttempts {
            XCTAssertEqual(retry.nextDelay(), CursorChannelRetry.retryDelay)
            XCTAssertEqual(retry.attempts, expected)
        }
        XCTAssertNil(retry.nextDelay())
        XCTAssertEqual(retry.attempts, CursorChannelRetry.maximumAttempts)
    }

    func testConfirmationAndNewSessionResetBudget() {
        var retry = CursorChannelRetry()
        _ = retry.nextDelay()
        _ = retry.nextDelay()
        retry.confirmed()
        XCTAssertEqual(retry.attempts, 0)
        XCTAssertNotNil(retry.nextDelay())
        retry.reset()
        XCTAssertEqual(retry.attempts, 0)
        XCTAssertNotNil(retry.nextDelay())
    }
}
