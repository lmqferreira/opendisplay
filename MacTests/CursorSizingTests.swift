import CoreGraphics
import XCTest

final class CursorSizingTests: XCTestCase {
    private let image = CGSize(width: 24, height: 32)
    private let hotspot = CGPoint(x: 3, y: 5)
    private let display = CGSize(width: 1024, height: 1366)

    private func geometry(scale: Double = 1, display: CGSize? = nil,
                          hotspot: CGPoint? = nil) throws -> CursorSpriteGeometry {
        try CursorSpriteGeometry(imageSize: image, hotspot: hotspot ?? self.hotspot,
                                 displaySize: display ?? self.display, scale: scale)
    }

    func testDefaultMatchesExistingCursorDimensionsAndHotspot() throws {
        let cursor = try geometry()
        XCTAssertEqual(cursor.normalizedSize.width, 24.0 / 1024, accuracy: 1e-12)
        XCTAssertEqual(cursor.normalizedSize.height, 32.0 / 1366, accuracy: 1e-12)
        XCTAssertEqual(cursor.anchor, CGPoint(x: 3.0 / 24, y: 5.0 / 32))
    }

    func testEnlargementPreservesAspectRatioAndHotspot() throws {
        let original = try geometry()
        for scale in [1.0, 1.25, 1.6, 2.0, 4.0] {
            let cursor = try geometry(scale: scale)
            XCTAssertEqual(cursor.normalizedSize.width, original.normalizedSize.width * scale,
                           accuracy: 1e-12)
            XCTAssertEqual(cursor.normalizedSize.height, original.normalizedSize.height * scale,
                           accuracy: 1e-12)
            XCTAssertEqual(cursor.anchor, original.anchor)
        }
    }

    func testReceiverHotspotRemainsAtCursorPositionAtEverySize() throws {
        let position = CGPoint(x: 0.4, y: 0.6)
        for scale in [1.0, 1.6, 4.0] {
            let cursor = try geometry(scale: scale)
            let origin = CGPoint(x: position.x - cursor.anchor.x * cursor.normalizedSize.width,
                                 y: position.y - cursor.anchor.y * cursor.normalizedSize.height)
            XCTAssertEqual(origin.x + cursor.anchor.x * cursor.normalizedSize.width,
                           position.x, accuracy: 1e-12)
            XCTAssertEqual(origin.y + cursor.anchor.y * cursor.normalizedSize.height,
                           position.y, accuracy: 1e-12)
        }
    }

    func testPortraitLandscapeAndHiDPIUseLogicalDisplayBounds() throws {
        for bounds in [display, CGSize(width: 1366, height: 1024),
                       CGSize(width: 2048, height: 2732), CGSize(width: 800, height: 600)] {
            let cursor = try geometry(scale: 2, display: bounds)
            XCTAssertEqual(cursor.normalizedSize.width * bounds.width, image.width * 2, accuracy: 1e-12)
            XCTAssertEqual(cursor.normalizedSize.height * bounds.height, image.height * 2, accuracy: 1e-12)
        }
    }

    func testSpriteDeduplicationIncludesSizeHeightHotspotAndBitmap() throws {
        let data = Data([1, 2, 3])
        let original = CursorSpriteSnapshot(bitmap: data, geometry: try geometry())
        XCTAssertEqual(original, CursorSpriteSnapshot(bitmap: data, geometry: try geometry()))
        XCTAssertNotEqual(original, CursorSpriteSnapshot(bitmap: data, geometry: try geometry(scale: 1.6)))
        XCTAssertNotEqual(original, CursorSpriteSnapshot(
            bitmap: data, geometry: try geometry(display: CGSize(width: 1024, height: 1200))))
        XCTAssertNotEqual(original, CursorSpriteSnapshot(
            bitmap: data, geometry: try geometry(hotspot: CGPoint(x: 4, y: 5))))
        XCTAssertNotEqual(original, CursorSpriteSnapshot(bitmap: Data([4, 5, 6]), geometry: try geometry()))
    }

    func testRejectsInvalidScaleAndGeometry() {
        for scale in [0.0, 0.99, 4.01, -.infinity, .infinity, .nan] {
            XCTAssertThrowsError(try geometry(scale: scale))
        }
        for invalid in [CGSize.zero, CGSize(width: -1, height: 1),
                        CGSize(width: CGFloat.infinity, height: 1),
                        CGSize(width: 1, height: CGFloat.nan)] {
            XCTAssertThrowsError(try CursorSpriteGeometry(
                imageSize: invalid, hotspot: hotspot, displaySize: display, scale: 1))
            XCTAssertThrowsError(try geometry(display: invalid))
        }
        XCTAssertThrowsError(try geometry(hotspot: CGPoint(x: CGFloat.nan, y: 0)))
        XCTAssertThrowsError(try CursorSpriteGeometry(
            imageSize: CGSize(width: 0.01, height: 32),
            hotspot: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 0),
            displaySize: display, scale: 1))
    }
}

final class CursorSizeStoreTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "CursorSizeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testMissingPreferencePreservesDefaultAndResetRemovesOverride() throws {
        try withDefaults { defaults in
            XCTAssertEqual(try CursorSizeStore.load(key: "k", from: defaults), 1)
            try CursorSizeStore.save(1.6, key: "k", to: defaults)
            XCTAssertEqual(try CursorSizeStore.load(key: "k", from: defaults), 1.6)
            try CursorSizeStore.save(1, key: "k", to: defaults)
            XCTAssertNil(defaults.object(forKey: "k"))
            XCTAssertEqual(try CursorSizeStore.load(key: "k", from: defaults), 1)
        }
    }

    func testIdentitySurvivesTransportAndSerialChangesWhenInstallIDExists() throws {
        XCTAssertEqual(CursorSizeStore.key(installID: "ABC", serial: 7), "cursorSize.ABC")
        XCTAssertEqual(CursorSizeStore.key(installID: "ABC", serial: 7),
                       CursorSizeStore.key(installID: "ABC", serial: 99))
        XCTAssertEqual(CursorSizeStore.key(installID: nil, serial: 0x4f53),
                       "cursorSize.serial-00004f53")
        try withDefaults { defaults in
            let iPad = CursorSizeStore.key(installID: "iPad", serial: 7)
            let phone = CursorSizeStore.key(installID: "phone", serial: 8)
            try CursorSizeStore.save(2, key: iPad, to: defaults)
            XCTAssertEqual(try CursorSizeStore.load(key: iPad, from: defaults), 2)
            XCTAssertEqual(try CursorSizeStore.load(key: phone, from: defaults), 1)
        }
    }

    func testAcceptedRangeRoundTrips() throws {
        try withDefaults { defaults in
            for scale in [1.0, 1.05, 1.6, 2.0, 3.5, 4.0] {
                try CursorSizeStore.save(scale, key: "k", to: defaults)
                XCTAssertEqual(try CursorSizeStore.load(key: "k", from: defaults), scale)
            }
        }
    }

    func testInvalidWriteDoesNotReplaceExistingValue() throws {
        try withDefaults { defaults in
            try CursorSizeStore.save(2, key: "k", to: defaults)
            for scale in [0.0, 4.1, -.infinity, .infinity, .nan] {
                XCTAssertThrowsError(try CursorSizeStore.save(scale, key: "k", to: defaults))
                XCTAssertEqual(try CursorSizeStore.load(key: "k", from: defaults), 2)
            }
        }
    }

    func testCorruptStoredValuesAreReportedInsteadOfSilentlyCoerced() throws {
        try withDefaults { defaults in
            for value: Any in ["2", true, false, 0.0, 4.1, ["scale": 2]] {
                defaults.set(value, forKey: "k")
                XCTAssertThrowsError(try CursorSizeStore.load(key: "k", from: defaults))
            }
        }
    }
}
