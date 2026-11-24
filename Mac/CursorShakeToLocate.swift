import CoreFoundation
import CoreGraphics
import Foundation

/// Gesture thresholds follow the shake-to-locate idea in upstream PR #487.
/// Only transient enlargement is tracked here; the saved device size is the base.
struct CursorShakeToLocate {
    private static let minimumSpeed = 600.0
    private static let minimumMovement = 75.0
    private static let minimumShakeDistance = 525.0
    private static let reversalWindow = 0.35
    private static let requiredReversals = 6
    private static let holdDuration = 0.2
    private static let fadeDuration = 0.1
    private static let maximumSampleGap = 0.25
    private static let maximumJump = 200.0

    private var lastPosition: CGPoint?
    private var lastTime: TimeInterval?
    private var lastDirection: CGPoint?
    private var lastFastMovement: TimeInterval?
    private var reversals = 0
    private var shakeDistance = 0.0
    private var enlargedUntil: TimeInterval = 0
    private var enlargement = 0.0

    mutating func reset() { self = CursorShakeToLocate() }

    mutating func scale(position: CGPoint?, at time: TimeInterval,
                        baseScale: Double, enabled: Bool) throws -> Double {
        try CursorSizing.validate(scale: baseScale)
        let fraction = update(position: position, at: time, enabled: enabled)
        guard fraction > 0 else { return baseScale }
        let maximum = CursorSizing.scaleRange.upperBound
        let raw = baseScale + (maximum - baseScale) * fraction
        let percentStep = CursorSizing.scaleStep * 100
        let rounded = (raw * 100 / percentStep).rounded() * percentStep / 100
        return min(maximum, max(baseScale, rounded))
    }

    private mutating func update(position: CGPoint?, at time: TimeInterval,
                                 enabled: Bool) -> Double {
        guard enabled, let position, position.x.isFinite, position.y.isFinite,
              time.isFinite, time >= 0 else {
            reset()
            return 0
        }
        guard let previous = lastPosition, let previousTime = lastTime else {
            lastPosition = position
            lastTime = time
            return 0
        }
        let dt = time - previousTime
        let dx = Double(position.x - previous.x)
        let dy = Double(position.y - previous.y)
        let distance = hypot(dx, dy)
        // Long gaps and jumps can be sleep/wake, display migration or touch
        // repositioning, not a continuous mouse gesture.
        guard dt > 0, dt <= Self.maximumSampleGap,
              distance.isFinite, distance <= Self.maximumJump else {
            reset()
            lastPosition = position
            lastTime = time
            return 0
        }
        lastPosition = position
        lastTime = time
        if let lastFastMovement, time - lastFastMovement > Self.reversalWindow {
            lastDirection = nil
            reversals = 0
            shakeDistance = 0
        }
        if distance >= Self.minimumMovement, distance / dt >= Self.minimumSpeed {
            shakeDistance += distance
            let direction = CGPoint(x: dx / distance, y: dy / distance)
            if let previousDirection = lastDirection,
               previousDirection.x * direction.x + previousDirection.y * direction.y < -0.5 {
                reversals += 1
            }
            lastDirection = direction
            lastFastMovement = time
            if reversals >= Self.requiredReversals,
               shakeDistance >= Self.minimumShakeDistance {
                enlargedUntil = time + Self.holdDuration
                reversals = 0
                shakeDistance = 0
            }
        }
        if time < enlargedUntil {
            enlargement = min(1, enlargement + dt * 5)
        } else {
            enlargement = max(0, enlargement - dt / Self.fadeDuration)
        }
        if enlargement < 1e-9 { enlargement = 0 }
        if enlargement > 1 - 1e-9 { enlargement = 1 }
        return enlargement
    }
}

enum CursorShakePreferenceStore {
    private static func key(_ cursorKey: String) -> String { cursorKey + ".shakeToLocate" }

    static func load(cursorKey: String, from defaults: UserDefaults = .standard) throws -> Bool {
        guard let stored = defaults.object(forKey: key(cursorKey)) else { return false }
        guard let number = stored as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw CursorSizingError.invalidStoredShakePreference
        }
        return number.boolValue
    }

    static func save(_ enabled: Bool, cursorKey: String, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key(cursorKey))
    }
}
