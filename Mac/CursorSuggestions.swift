import CoreFoundation
import CoreGraphics
import Foundation

struct CursorReferenceMetrics {
    let logicalSize: CGSize
    let physicalMillimeters: CGSize
    let pointerScale: Double

    static func current() -> Result<CursorReferenceMetrics, CursorSuggestionUnavailable> {
        let display = CGMainDisplayID()
        guard CGDisplayIsBuiltin(display) != 0 else { return .failure(.referenceDisplay) }
        var millimeters = CGDisplayScreenSize(display)
        let rotation = CGDisplayRotation(display)
        if rotation == 90 || rotation == 270 {
            millimeters = CGSize(width: millimeters.height, height: millimeters.width)
        }
        guard let value = UserDefaults(suiteName: "com.apple.universalaccess")?
            .object(forKey: "mouseDriverCursorSize") as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else {
            return .failure(.pointerScale)
        }
        return .success(CursorReferenceMetrics(logicalSize: CGDisplayBounds(display).size,
                                               physicalMillimeters: millimeters,
                                               pointerScale: value.doubleValue))
    }
}

enum CursorSuggestionUnavailable: Error, Equatable {
    case identifyingDevice, unknownModel, panelMismatch, receiverIdentity
    case referenceDisplay, referenceGeometry, pointerScale, displayGeometry, outsideRange
    case mirrorMode, capturedCursor

    var explanation: String {
        switch self {
        case .identifyingDevice: return "Connect this iPad by USB once to identify its model."
        case .unknownModel: return "This model has no verified physical-display profile."
        case .panelMismatch: return "The reported panel does not match the identified model."
        case .receiverIdentity: return "The receiver does not provide a stable device identity."
        case .referenceDisplay: return "The main Mac display must be a built-in display."
        case .referenceGeometry: return "Reliable physical Mac display measurements are unavailable."
        case .pointerScale: return "The current macOS pointer enlargement is unavailable."
        case .displayGeometry: return "The extended display geometry is not ready or does not match the panel."
        case .outsideRange: return "A physical match is outside the supported 100–400% range."
        case .mirrorMode: return "Physical-size suggestions are available in Extend mode."
        case .capturedCursor: return "Suggestions require the low-latency local cursor."
        }
    }
}

struct CursorSizeSuggestion: Equatable {
    let scale: Double
    let unroundedScale: Double
    let profileName: String

    var percentage: String { String(format: "%.0f%%", scale * 100) }
}

enum CursorSuggestionState: Equatable {
    case available(CursorSizeSuggestion)
    case unavailable(CursorSuggestionUnavailable)
}

enum CursorSuggestionCalculator {
    // Apple: https://support.apple.com/111979 — 2732×2048 at 264 PPI.
    private static let verifiedModels = ["iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8"]

    static func suggest(model: String, panelPixels: CGSize, desktopPoints: CGSize,
                        reference: CursorReferenceMetrics) -> CursorSuggestionState {
        guard verifiedModels.contains(model) else { return .unavailable(.unknownModel) }
        let portrait = panelPixels.width < panelPixels.height
        let expected = portrait ? CGSize(width: 2048, height: 2732) : CGSize(width: 2732, height: 2048)
        guard panelPixels == expected else { return .unavailable(.panelMismatch) }
        guard positive(reference.logicalSize), positive(reference.physicalMillimeters) else {
            return .unavailable(.referenceGeometry)
        }
        guard reference.pointerScale.isFinite, CursorSizing.scaleRange.contains(reference.pointerScale) else {
            return .unavailable(.pointerScale)
        }
        guard positive(desktopPoints),
              abs((desktopPoints.width / desktopPoints.height) / (panelPixels.width / panelPixels.height) - 1) <= 0.01 else {
            return .unavailable(.displayGeometry)
        }

        let logicalPPI = CGSize(width: reference.logicalSize.width / reference.physicalMillimeters.width * 25.4,
                                height: reference.logicalSize.height / reference.physicalMillimeters.height * 25.4)
        // CGDisplayScreenSize can fabricate millimeters using a 72-DPI
        // assumption when display metadata is absent. Never auto-size from it.
        guard abs(logicalPPI.width - 72) > 0.5, abs(logicalPPI.height - 72) > 0.5 else {
            return .unavailable(.referenceGeometry)
        }
        let targetMillimeters = CGSize(width: panelPixels.width / 264 * 25.4,
                                       height: panelPixels.height / 264 * 25.4)
        let horizontal = reference.pointerScale * reference.physicalMillimeters.width
            / reference.logicalSize.width * desktopPoints.width / targetMillimeters.width
        let vertical = reference.pointerScale * reference.physicalMillimeters.height
            / reference.logicalSize.height * desktopPoints.height / targetMillimeters.height
        guard horizontal.isFinite, vertical.isFinite, horizontal > 0, vertical > 0,
              abs(horizontal / vertical - 1) <= 0.01 else {
            return .unavailable(.referenceGeometry)
        }
        let raw = (horizontal + vertical) / 2
        guard CursorSizing.scaleRange.contains(raw) else { return .unavailable(.outsideRange) }
        let percentStep = CursorSizing.scaleStep * 100
        let rounded = (raw * 100 / percentStep).rounded() * percentStep / 100
        return .available(CursorSizeSuggestion(scale: rounded, unroundedScale: raw,
                                               profileName: "iPad Pro 12.9-inch (3rd generation)"))
    }

    private static func positive(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

enum CursorDeviceModelStore {
    static func load(receiverID: String, from defaults: UserDefaults = .standard) throws -> String? {
        guard let value = defaults.object(forKey: "cursorDeviceModel." + receiverID) else { return nil }
        guard let model = value as? String, model.hasPrefix("iPad"), model.contains(",") else {
            throw CursorSizingError.invalidStoredModel
        }
        return model
    }

    static func save(_ model: String, receiverID: String, to defaults: UserDefaults = .standard) {
        defaults.set(model, forKey: "cursorDeviceModel." + receiverID)
    }
}

enum CursorInitialSuggestionPolicy {
    private static let key = "cursorInitialSuggestionsEligible"

    static func configure(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: key) == nil else { return }
        let previousReceiver = !(defaults.dictionary(forKey: "installIDByUDID") ?? [:]).isEmpty
            || !(defaults.stringArray(forKey: "wifiRemembered") ?? []).isEmpty
            || defaults.dictionaryRepresentation().keys.contains {
                $0.hasPrefix("displayOrigin.") || $0.hasPrefix("displaySize.") || $0.hasPrefix("cursorSize.")
            }
        // Older versions removed an explicit 100% preference. Treat an
        // existing installation conservatively rather than overwriting it.
        defaults.set(!previousReceiver, forKey: key)
    }

    static func canApply(key cursorKey: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key) && !CursorSizeStore.hasChoice(key: cursorKey, in: defaults)
    }
}
