import CoreFoundation
import CoreGraphics
import Foundation

enum CursorSizing {
    static let scaleRange = 1.0...4.0
    static let defaultScale = 1.0
    static let scaleStep = 0.05

    static func sameScale(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 1e-9
    }

    static func validate(scale: Double) throws {
        guard scale.isFinite, scaleRange.contains(scale) else {
            throw CursorSizingError.invalidScale
        }
    }
}

enum CursorSizingError: Error, LocalizedError {
    case invalidScale
    case invalidStoredScale
    case invalidStoredModel
    case invalidImageSize
    case invalidDisplaySize
    case invalidHotspot

    var errorDescription: String? {
        switch self {
        case .invalidScale: return "cursor size must be between 100% and 400%"
        case .invalidStoredScale: return "saved cursor size is not a number between 100% and 400%"
        case .invalidStoredModel: return "saved receiver model is invalid"
        case .invalidImageSize: return "cursor image dimensions must be positive and finite"
        case .invalidDisplaySize: return "cursor display dimensions must be positive and finite"
        case .invalidHotspot: return "cursor hotspot must be finite"
        }
    }
}

enum CursorSizeStore {
    static func key(installID: String?, serial: UInt32) -> String {
        "cursorSize." + (installID ?? String(format: "serial-%08x", serial))
    }

    static func load(key: String, from defaults: UserDefaults = .standard) throws -> Double {
        guard let stored = defaults.object(forKey: key) else { return CursorSizing.defaultScale }
        guard let number = stored as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              CursorSizing.scaleRange.contains(number.doubleValue) else {
            throw CursorSizingError.invalidStoredScale
        }
        return number.doubleValue
    }

    static func hasChoice(key: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) != nil || defaults.bool(forKey: key + ".chosen")
    }

    static func save(_ scale: Double, key: String, to defaults: UserDefaults = .standard) throws {
        try CursorSizing.validate(scale: scale)
        if scale == CursorSizing.defaultScale {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(scale, forKey: key)
        }
        defaults.set(true, forKey: key + ".chosen")
    }
}

struct CursorSpriteGeometry: Equatable {
    let normalizedSize: CGSize
    let anchor: CGPoint

    init(imageSize: CGSize, hotspot: CGPoint, displaySize: CGSize, scale: Double) throws {
        try CursorSizing.validate(scale: scale)
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else {
            throw CursorSizingError.invalidImageSize
        }
        guard displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0 else {
            throw CursorSizingError.invalidDisplaySize
        }
        guard hotspot.x.isFinite, hotspot.y.isFinite else {
            throw CursorSizingError.invalidHotspot
        }
        let size = CGSize(width: imageSize.width / displaySize.width * scale,
                          height: imageSize.height / displaySize.height * scale)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw CursorSizingError.invalidDisplaySize
        }
        normalizedSize = size
        // The anchor is a fraction of the original sprite, not the enlarged
        // bounds: changing size must not move the click point.
        let anchor = CGPoint(x: hotspot.x / imageSize.width, y: hotspot.y / imageSize.height)
        guard anchor.x.isFinite, anchor.y.isFinite else {
            throw CursorSizingError.invalidHotspot
        }
        self.anchor = anchor
    }
}

struct CursorSpriteSnapshot: Equatable {
    let bitmap: Data
    let geometry: CursorSpriteGeometry
}
