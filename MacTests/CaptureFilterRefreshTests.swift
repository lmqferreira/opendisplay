import XCTest

final class CaptureFilterRefreshTests: XCTestCase {
    func testOnlyActiveCapturesCanRefresh() throws {
        var gate = CaptureFilterRefreshGate()
        XCTAssertThrowsError(try gate.begin()) {
            XCTAssertEqual($0 as? CaptureFilterRefreshError, .unavailable)
        }
        gate.activate(displayID: 16, generation: 1)
        let request = try gate.begin()
        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(request))
        XCTAssertFalse(gate.finish(request))
        XCTAssertThrowsError(try gate.begin()) {
            XCTAssertEqual($0 as? CaptureFilterRefreshError, .unavailable)
        }
    }

    func testOverlappingRequestsWaitForTheCurrentRefreshToFinish() throws {
        var gate = CaptureFilterRefreshGate()
        gate.activate(displayID: 16, generation: 1)
        let first = try gate.begin()
        XCTAssertThrowsError(try gate.begin()) {
            XCTAssertEqual($0 as? CaptureFilterRefreshError, .busy)
        }
        XCTAssertTrue(gate.finish(first))
        let second = try gate.begin()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(gate.finish(first))
        XCTAssertTrue(gate.isCurrent(second))
    }

    func testRetiredCompletionCannotReleaseANewDisplaysRefresh() throws {
        var gate = CaptureFilterRefreshGate()
        gate.activate(displayID: 16, generation: 1)
        let old = try gate.begin()
        gate.invalidate()
        gate.activate(displayID: 17, generation: 3)
        let current = try gate.begin()
        XCTAssertFalse(gate.finish(old))
        XCTAssertTrue(gate.isCurrent(current))
        XCTAssertThrowsError(try gate.begin()) {
            XCTAssertEqual($0 as? CaptureFilterRefreshError, .busy)
        }
        XCTAssertTrue(gate.finish(current))
    }

    func testRebuiltCaptureWithSameDisplayIDRejectsTheOldRequest() throws {
        var gate = CaptureFilterRefreshGate()
        gate.activate(displayID: 16, generation: 1)
        let old = try gate.begin()
        gate.activate(displayID: 16, generation: 2)
        let current = try gate.begin()
        XCTAssertFalse(gate.isCurrent(old))
        XCTAssertFalse(gate.finish(old))
        XCTAssertTrue(gate.isCurrent(current))
        XCTAssertTrue(gate.finish(current))
    }
}
