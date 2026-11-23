import CoreGraphics
import XCTest

final class ProtectedCaptureOverlayTests: XCTestCase {
    private func window(
        id: CGWindowID = 1,
        owner: String = "Microsoft Teams",
        bounds: CGRect = CGRect(x: 1800, y: 40, width: 334, height: 120),
        layer: Int = 19,
        sharing: Int = 0,
        onscreen: Bool = true
    ) -> ProtectedCaptureOverlayWindow {
        ProtectedCaptureOverlayWindow(
            id: id, processID: 123, owner: owner, bounds: bounds, layer: layer,
            sharingState: sharing, alpha: 1, isOnscreen: onscreen
        )
    }

    func testProtectedTeamsOverlayOnTargetDisplayIsDetectedAndClipped() {
        let display = CGRect(x: 1728, y: 0, width: 1024, height: 1366)
        let result = ProtectedCaptureOverlayDetector.teamsOverlays(
            windows: [window(bounds: CGRect(x: 1700, y: 40, width: 334, height: 120))],
            displayBounds: display
        )
        XCTAssertEqual(result, [
            ProtectedCaptureOverlay(
                windowID: 1,
                processID: 123,
                sourceBounds: CGRect(x: 1700, y: 40, width: 334, height: 120),
                captureBounds: CGRect(x: 1728, y: 40, width: 306, height: 120),
                windowLayer: 19
            )
        ])
    }

    func testNormalTeamsAndOtherProtectedWindowsAreNotBlocked() {
        let display = CGRect(x: 1728, y: 0, width: 1024, height: 1366)
        let result = ProtectedCaptureOverlayDetector.teamsOverlays(
            windows: [
                window(id: 1, sharing: 1),
                window(id: 2, owner: "Another App"),
                window(id: 3, onscreen: false),
                window(id: 4, layer: 0)
            ],
            displayBounds: display
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testTeamsFixtureAndTeamsWebViewPrefixesUseTheSameDetector() {
        let display = CGRect(x: 1728, y: 0, width: 1024, height: 1366)
        let result = ProtectedCaptureOverlayDetector.teamsOverlays(
            windows: [
                window(id: 1, owner: "Microsoft Teams Capture Fixture"),
                window(id: 2, owner: "Unrelated Teams Helper")
            ],
            displayBounds: display
        )
        XCTAssertEqual(result.map(\.windowID), [1])
    }

    func testSameProtectedWindowOutsideTargetDisplayIsIgnored() {
        let result = ProtectedCaptureOverlayDetector.teamsOverlays(
            windows: [window(bounds: CGRect(x: 100, y: 40, width: 334, height: 120))],
            displayBounds: CGRect(x: 1728, y: 0, width: 1024, height: 1366)
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testCGCoordinatesConvertToAppKitCoordinates() {
        XCTAssertEqual(
            ProtectedCaptureOverlayDetector.appKitFrame(
                from: CGRect(x: 1828, y: 33, width: 334, height: 120),
                mainDisplayHeight: 1117
            ),
            CGRect(x: 1828, y: 964, width: 334, height: 120)
        )
    }
}
