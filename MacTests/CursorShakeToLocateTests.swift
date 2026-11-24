import CoreGraphics
import XCTest

final class CursorShakeToLocateTests: XCTestCase {
    private let point = CGPoint(x: 100, y: 100)

    private func trigger(_ tracker: inout CursorShakeToLocate, base: Double = 1.7,
                         vertical: Bool = false) throws -> Double {
        _ = try tracker.scale(position: point, at: 0, baseScale: base, enabled: true)
        var result = base
        for index in 1...4 {
            let offset = index % 2 == 0 ? 0.0 : 40.0
            let position = CGPoint(x: 100 + (vertical ? 0 : offset),
                                   y: 100 + (vertical ? offset : 0))
            result = try tracker.scale(position: position, at: Double(index) * 0.04,
                                       baseScale: base, enabled: true)
        }
        return result
    }

    func testRapidReversalsLocateInBothDirectionsThenReturnExactlyToSelectedSize() throws {
        for vertical in [false, true] {
            var tracker = CursorShakeToLocate()
            XCTAssertGreaterThan(try trigger(&tracker, vertical: vertical), 1.7)
            var largest = 1.7
            var result = 1.7
            for index in 5...40 {
                result = try tracker.scale(position: point, at: Double(index) * 0.04,
                                           baseScale: 1.7, enabled: true)
                XCTAssertGreaterThanOrEqual(result, 1.7)
                XCTAssertLessThanOrEqual(result, 4)
                largest = max(largest, result)
            }
            XCTAssertEqual(largest, 4)
            XCTAssertEqual(result, 1.7)
        }
    }

    func testAbsoluteCeilingNeverMultipliesTheSelectedSizeByFour() throws {
        for base in [1.0, 1.7, 2.5, 3.9, 4.0] {
            var tracker = CursorShakeToLocate()
            _ = try trigger(&tracker, base: base)
            var peak = base
            for index in 5...16 {
                let scale = try tracker.scale(position: point, at: Double(index) * 0.04,
                                              baseScale: base, enabled: true)
                XCTAssertLessThanOrEqual(scale, 4)
                XCTAssertGreaterThanOrEqual(scale, base)
                peak = max(peak, scale)
            }
            XCTAssertEqual(peak, 4)
        }
    }

    func testQuickFadeReturnsWithin350MillisecondsAtCursorSamplingRates() throws {
        for fps in [30, 60, 120] {
            var tracker = CursorShakeToLocate()
            _ = try trigger(&tracker)
            let lastShake = 0.16
            var peak = 1.7
            var returnedAt: TimeInterval?
            for frame in 1...fps {
                let time = lastShake + Double(frame) / Double(fps)
                let scale = try tracker.scale(position: point, at: time,
                                              baseScale: 1.7, enabled: true)
                peak = max(peak, scale)
                if scale == 1.7, returnedAt == nil { returnedAt = time }
            }
            XCTAssertEqual(peak, 4)
            XCTAssertLessThanOrEqual(try XCTUnwrap(returnedAt) - lastShake, 0.35)
        }
    }

    func testSmallJitterSlowMovementAndOneWayTravelDoNotTrigger() throws {
        let paths: [[CGPoint]] = [
            (0...10).map { CGPoint(x: 100 + Double($0 % 2) * 0.2, y: 100) },
            (0...10).map { CGPoint(x: 100 + Double($0 % 2) * 4, y: 100) },
            (0...10).map { CGPoint(x: 100 + Double($0) * 20, y: 100) }
        ]
        for path in paths {
            var tracker = CursorShakeToLocate()
            for (index, position) in path.enumerated() {
                XCTAssertEqual(try tracker.scale(position: position, at: Double(index) * 0.04,
                                                baseScale: 1.7, enabled: true), 1.7)
            }
        }

        func testOrdinaryFastTurnsDoNotEnlargeUnlessTheShakeHasSustainedTravel() throws {
            let paths: [[Double]] = [
                [8, 0, 8, 0, 8, 0],                 // rapid but tiny zig-zag
                [22, 0, 22, 0, 22, 0],              // previous 3pt-detector false positive
                [45, 0, 45]                          // too few reversals
            ]
            for xs in paths {
                var tracker = CursorShakeToLocate()
                _ = try tracker.scale(position: point, at: 0, baseScale: 1.7, enabled: true)
                for (index, offset) in xs.enumerated() {
                    XCTAssertEqual(
                        try tracker.scale(
                            position: CGPoint(x: 100 + offset, y: 100),
                            at: Double(index + 1) * 0.04,
                            baseScale: 1.7,
                            enabled: true
                        ),
                        1.7
                    )
                }
            }
        }
    }

    func testSeparatedReversalsDoNotAccumulateAcrossAPause() throws {
        var tracker = CursorShakeToLocate()
        for (time, x) in [(0.0, 100.0), (0.04, 120.0), (0.08, 100.0),
                          (0.28, 100.0), (0.48, 100.0), (0.6, 100.0),
                          (0.64, 120.0), (0.68, 100.0), (0.72, 120.0)] {
            XCTAssertEqual(try tracker.scale(position: CGPoint(x: x, y: 100), at: time,
                                            baseScale: 1.7, enabled: true), 1.7)
        }
    }

    func testDisabledOrOffDisplayResetsEnlargementAndOldGestureHistory() throws {
        for enabled in [false, true] {
            var tracker = CursorShakeToLocate()
            _ = try trigger(&tracker)
            XCTAssertEqual(try tracker.scale(position: enabled ? nil : point, at: 0.2,
                                            baseScale: 1.7, enabled: enabled), 1.7)
            XCTAssertEqual(try tracker.scale(position: point, at: 0.24,
                                            baseScale: 1.7, enabled: true), 1.7)
            XCTAssertEqual(try tracker.scale(position: CGPoint(x: 120, y: 100), at: 0.28,
                                            baseScale: 1.7, enabled: true), 1.7)
        }
    }

    func testSleepGapsClockReversalInvalidSamplesAndLargeJumpsReset() throws {
        let interruptions: [(CGPoint?, Double)] = [
            (point, 10), (point, 0.1), (point, .nan),
            (CGPoint(x: CGFloat.nan, y: 0), 0.2),
            (CGPoint(x: 600, y: 100), 0.2)
        ]
        for (position, time) in interruptions {
            var tracker = CursorShakeToLocate()
            _ = try trigger(&tracker)
            XCTAssertEqual(try tracker.scale(position: position, at: time,
                                            baseScale: 1.7, enabled: true), 1.7)
        }
        var tracker = CursorShakeToLocate()
        _ = try trigger(&tracker)
        tracker.reset()
        XCTAssertEqual(try tracker.scale(position: point, at: 0.2,
                                        baseScale: 1.7, enabled: true), 1.7)
    }

    func testChangingSelectedSizeDuringLocateReturnsToTheNewExactValue() throws {
        var tracker = CursorShakeToLocate()
        _ = try trigger(&tracker)
        var result = 1.85
        for index in 5...40 {
            result = try tracker.scale(position: point, at: Double(index) * 0.04,
                                       baseScale: 1.85, enabled: true)
            XCTAssertGreaterThanOrEqual(result, 1.85)
            XCTAssertLessThanOrEqual(result, 4)
        }
        XCTAssertEqual(result, 1.85)
    }

    func testTransientUpdatesUseFineStepsAndPreserveSpriteHotspot() throws {
        var tracker = CursorShakeToLocate()
        let first = try trigger(&tracker)
        let original = try CursorSpriteGeometry(
            imageSize: CGSize(width: 24, height: 32), hotspot: CGPoint(x: 3, y: 5),
            displaySize: CGSize(width: 1024, height: 1366), scale: 1.7)
        let enlarged = try CursorSpriteGeometry(
            imageSize: CGSize(width: 24, height: 32), hotspot: CGPoint(x: 3, y: 5),
            displaySize: CGSize(width: 1024, height: 1366), scale: first)
        XCTAssertEqual(original.anchor, enlarged.anchor)
        XCTAssertNotEqual(CursorSpriteSnapshot(bitmap: Data([1]), geometry: original),
                          CursorSpriteSnapshot(bitmap: Data([1]), geometry: enlarged))
        var sizes = Set<Double>()
        for index in 5...10 {
            let scale = try tracker.scale(position: point, at: Double(index) * 0.04,
                                          baseScale: 1.7, enabled: true)
            XCTAssertEqual(scale / 0.05, (scale / 0.05).rounded(), accuracy: 1e-9)
            sizes.insert(scale)
        }
        XCTAssertGreaterThan(sizes.count, 3)
    }

    func testInvalidSelectedSizeIsReportedRatherThanClamped() {
        for base in [0.0, 4.1, .infinity, .nan] {
            var tracker = CursorShakeToLocate()
            XCTAssertThrowsError(try tracker.scale(position: point, at: 0,
                                                  baseScale: base, enabled: true))
        }
    }
}

final class CursorShakePreferenceTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "CursorShakePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testShakeIsOptInAndPersistsIndependentlyForEachReceiver() throws {
        try withDefaults { defaults in
            XCTAssertFalse(try CursorShakePreferenceStore.load(cursorKey: "A", from: defaults))
            CursorShakePreferenceStore.save(true, cursorKey: "A", to: defaults)
            XCTAssertTrue(try CursorShakePreferenceStore.load(cursorKey: "A", from: defaults))
            XCTAssertFalse(try CursorShakePreferenceStore.load(cursorKey: "B", from: defaults))
            CursorShakePreferenceStore.save(false, cursorKey: "A", to: defaults)
            XCTAssertFalse(try CursorShakePreferenceStore.load(cursorKey: "A", from: defaults))
        }
    }

    func testShakeCannotChangeSavedManualOrSuggestedSizing() throws {
        try withDefaults { defaults in
            try CursorSizeStore.save(1.7, key: "cursorSize.A", to: defaults)
            CursorShakePreferenceStore.save(true, cursorKey: "cursorSize.A", to: defaults)
            var tracker = CursorShakeToLocate()
            let origin = CGPoint(x: 100, y: 100)
            _ = try tracker.scale(position: origin, at: 0, baseScale: 1.7, enabled: true)
            for index in 1...40 {
                let position = CGPoint(x: 100 + Double(index % 2) * 20, y: 100)
                _ = try tracker.scale(position: position, at: Double(index) * 0.04,
                                      baseScale: 1.7, enabled: true)
            }
            XCTAssertEqual(try CursorSizeStore.load(key: "cursorSize.A", from: defaults), 1.7)
            XCTAssertTrue(CursorSizeStore.hasChoice(key: "cursorSize.A", in: defaults))
        }
    }

    func testCorruptShakePreferencesAreReported() throws {
        try withDefaults { defaults in
            for value: Any in ["true", 1, ["enabled": true]] {
                defaults.set(value, forKey: "A.shakeToLocate")
                XCTAssertThrowsError(try CursorShakePreferenceStore.load(cursorKey: "A", from: defaults))
            }
        }
    }
}
