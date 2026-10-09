import CoreGraphics
import XCTest

final class CursorSuggestionsTests: XCTestCase {
    private let panel = CGSize(width: 2048, height: 2732)
    private let desktop = CGSize(width: 1024, height: 1366)
    private let reference = CursorReferenceMetrics(
        logicalSize: CGSize(width: 1728, height: 1117),
        physicalMillimeters: CGSize(width: 344.24470071231616, height: 222.52391822665348),
        pointerScale: 1.622791519434629)

    private func calculate(model: String = "iPad8,5", panel: CGSize? = nil,
                           desktop: CGSize? = nil,
                           reference: CursorReferenceMetrics? = nil) -> CursorSuggestionState {
        CursorSuggestionCalculator.suggest(model: model, panelPixels: panel ?? self.panel,
                                          desktopPoints: desktop ?? self.desktop,
                                          reference: reference ?? self.reference)
    }

    func testIndependentlyMeasuredSetupSuggests170Percent() throws {
        for model in ["iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8"] {
            guard case .available(let suggestion) = calculate(model: model) else {
                return XCTFail("Verified model did not produce a suggestion")
            }
            XCTAssertEqual(suggestion.unroundedScale, 1.6800664890061365, accuracy: 1e-10)
            XCTAssertEqual(suggestion.scale, 1.7, accuracy: 1e-10)
            XCTAssertEqual(suggestion.percentage, "170%")
        }
    }

    func testPortraitAndLandscapeHaveTheSamePhysicalCursorSize() {
        guard case .available(let portrait) = calculate(),
              case .available(let landscape) = calculate(panel: CGSize(width: 2732, height: 2048),
                                                         desktop: CGSize(width: 1366, height: 1024)) else {
            return XCTFail("Both orientations should have suggestions")
        }
        XCTAssertEqual(portrait.scale, landscape.scale)
        XCTAssertEqual(portrait.unroundedScale, landscape.unroundedScale, accuracy: 1e-10)
        XCTAssertTrue(CursorSizing.sameScale(portrait.scale, 1.7 + 1e-15))
        XCTAssertFalse(CursorSizing.sameScale(portrait.scale, 1.75))
    }

    func testActualLogicalDesktopSizeParticipatesInCalculation() {
        guard case .available(let normal) = calculate(),
              case .available(let native) = calculate(desktop: CGSize(width: 2048, height: 2732)) else {
            return XCTFail("Valid canvases did not produce suggestions")
        }
        XCTAssertEqual(native.unroundedScale, normal.unroundedScale * 2, accuracy: 1e-10)
        XCTAssertEqual(native.scale, 3.35, accuracy: 1e-10)
    }

    func testUnknownModelsAndMismatchedNativePanelsAreNotGuessed() {
        XCTAssertEqual(calculate(model: "iPad14,5"), .unavailable(.unknownModel))
        XCTAssertEqual(calculate(panel: CGSize(width: 1536, height: 2048)),
                       .unavailable(.panelMismatch))
    }

    func testRejectsNonfiniteAndMissingGeometry() {
        for invalid in [CGSize.zero, CGSize(width: CGFloat.nan, height: 1),
                        CGSize(width: 1, height: CGFloat.infinity)] {
            XCTAssertEqual(calculate(reference: CursorReferenceMetrics(
                logicalSize: invalid, physicalMillimeters: reference.physicalMillimeters,
                pointerScale: reference.pointerScale)), .unavailable(.referenceGeometry))
            XCTAssertEqual(calculate(reference: CursorReferenceMetrics(
                logicalSize: reference.logicalSize, physicalMillimeters: invalid,
                pointerScale: reference.pointerScale)), .unavailable(.referenceGeometry))
            XCTAssertEqual(calculate(desktop: invalid), .unavailable(.displayGeometry))
        }
    }

    func testRejectsUnavailableOrInvalidPointerEnlargement() {
        for scale in [0.0, 0.99, 4.1, .infinity, .nan] {
            XCTAssertEqual(calculate(reference: CursorReferenceMetrics(
                logicalSize: reference.logicalSize,
                physicalMillimeters: reference.physicalMillimeters, pointerScale: scale)),
                           .unavailable(.pointerScale))
        }
    }

    func testRejectsCoreGraphics72DPIFallback() {
        let fallback = CGSize(width: reference.logicalSize.width / 72 * 25.4,
                              height: reference.logicalSize.height / 72 * 25.4)
        XCTAssertEqual(calculate(reference: CursorReferenceMetrics(
            logicalSize: reference.logicalSize, physicalMillimeters: fallback,
            pointerScale: reference.pointerScale)), .unavailable(.referenceGeometry))
    }

    func testRejectsInconsistentAxesAndLetterboxedAspect() {
        XCTAssertEqual(calculate(reference: CursorReferenceMetrics(
            logicalSize: reference.logicalSize,
            physicalMillimeters: CGSize(width: reference.physicalMillimeters.width, height: 300),
            pointerScale: reference.pointerScale)), .unavailable(.referenceGeometry))
        XCTAssertEqual(calculate(desktop: CGSize(width: 1728, height: 1117)),
                       .unavailable(.displayGeometry))
    }

    func testDoesNotClampAnOutOfRangePhysicalMatchIntoASuccess() {
        XCTAssertEqual(calculate(desktop: CGSize(width: 3072, height: 4098)),
                       .unavailable(.outsideRange))
        let small = CursorReferenceMetrics(
            logicalSize: reference.logicalSize,
            physicalMillimeters: CGSize(width: 172.12235035615808, height: 111.26195911332674),
            pointerScale: 1)
        XCTAssertEqual(calculate(reference: small), .unavailable(.outsideRange))
    }
}

final class CursorInitialSuggestionTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "CursorInitialSuggestionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testFreshInstallationCanApplyOnlyOncePerReceiver() throws {
        try withDefaults { defaults in
            CursorInitialSuggestionPolicy.configure(in: defaults)
            XCTAssertTrue(CursorInitialSuggestionPolicy.canApply(key: "cursorSize.A", in: defaults))
            try CursorSizeStore.save(1.7, key: "cursorSize.A", to: defaults)
            XCTAssertFalse(CursorInitialSuggestionPolicy.canApply(key: "cursorSize.A", in: defaults))
            XCTAssertTrue(CursorInitialSuggestionPolicy.canApply(key: "cursorSize.B", in: defaults))
        }
    }

    func testDelayedModelDataCannotOverwriteAManualChoice() throws {
        try withDefaults { defaults in
            CursorInitialSuggestionPolicy.configure(in: defaults)
            try CursorSizeStore.save(1.75, key: "cursorSize.A", to: defaults)
            XCTAssertFalse(CursorInitialSuggestionPolicy.canApply(key: "cursorSize.A", in: defaults))
            XCTAssertEqual(try CursorSizeStore.load(key: "cursorSize.A", from: defaults), 1.75)
        }
    }

    func testExplicit100PercentRemainsAChoiceAfterResetAndRelaunch() throws {
        try withDefaults { defaults in
            CursorInitialSuggestionPolicy.configure(in: defaults)
            try CursorSizeStore.save(1, key: "cursorSize.A", to: defaults)
            XCTAssertNil(defaults.object(forKey: "cursorSize.A"))
            XCTAssertTrue(CursorSizeStore.hasChoice(key: "cursorSize.A", in: defaults))
            CursorInitialSuggestionPolicy.configure(in: defaults)
            XCTAssertFalse(CursorInitialSuggestionPolicy.canApply(key: "cursorSize.A", in: defaults))
        }
    }

    func testExistingInstallationsKeepTheirLegacy100PercentDefault() throws {
        let evidence: [(String, Any)] = [
            ("installIDByUDID", ["usb-device": "receiver"]),
            ("wifiRemembered", ["iPad"]),
            ("displayOrigin.receiver", [0, 0]),
            ("displaySize.receiver", "moreSpace"),
            ("cursorSize.receiver", 1.75)
        ]
        for (key, value) in evidence {
            try withDefaults { defaults in
                defaults.set(value, forKey: key)
                CursorInitialSuggestionPolicy.configure(in: defaults)
                XCTAssertFalse(CursorInitialSuggestionPolicy.canApply(key: "cursorSize.new", in: defaults), key)
            }
        }
    }

    func testEligibilityIsNotRecomputedAfterTheFirstConnection() throws {
        try withDefaults { defaults in
            CursorInitialSuggestionPolicy.configure(in: defaults)
            defaults.set(["usb-device": "receiver"], forKey: "installIDByUDID")
            CursorInitialSuggestionPolicy.configure(in: defaults)
            XCTAssertTrue(CursorInitialSuggestionPolicy.canApply(key: "cursorSize.new", in: defaults))
        }
    }

    func testExistingOrCorruptStoredChoicesAreNeverAutoOverwritten() throws {
        try withDefaults { defaults in
            CursorInitialSuggestionPolicy.configure(in: defaults)
            defaults.set("invalid", forKey: "cursorSize.A")
            XCTAssertFalse(CursorInitialSuggestionPolicy.canApply(key: "cursorSize.A", in: defaults))
            defaults.set(1.7, forKey: "cursorSize.B")
            XCTAssertFalse(CursorInitialSuggestionPolicy.canApply(key: "cursorSize.B", in: defaults))
        }
    }

    func testExistingInstallCanStillApplyTheSuggestionExplicitly() throws {
        try withDefaults { defaults in
            defaults.set(["iPad"], forKey: "wifiRemembered")
            CursorInitialSuggestionPolicy.configure(in: defaults)
            try CursorSizeStore.save(1.7, key: "cursorSize.A", to: defaults)
            XCTAssertEqual(try CursorSizeStore.load(key: "cursorSize.A", from: defaults), 1.7)
        }
    }

    func testHardwareProfileCacheIsPerReceiverAndRejectsCorruption() throws {
        try withDefaults { defaults in
            CursorDeviceModelStore.save("iPad8,5", receiverID: "A", to: defaults)
            XCTAssertEqual(try CursorDeviceModelStore.load(receiverID: "A", from: defaults), "iPad8,5")
            XCTAssertNil(try CursorDeviceModelStore.load(receiverID: "B", from: defaults))
            defaults.set(123, forKey: "cursorDeviceModel.B")
            XCTAssertThrowsError(try CursorDeviceModelStore.load(receiverID: "B", from: defaults))
        }
    }
}
