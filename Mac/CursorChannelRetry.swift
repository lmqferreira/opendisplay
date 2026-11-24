import Foundation

struct CursorChannelRetry {
    static let maximumAttempts = 3
    static let retryDelay: TimeInterval = 1

    private(set) var attempts = 0

    mutating func confirmed() {
        attempts = 0
    }

    mutating func nextDelay() -> TimeInterval? {
        guard attempts < Self.maximumAttempts else { return nil }
        attempts += 1
        return Self.retryDelay
    }

    mutating func reset() {
        attempts = 0
    }
}
