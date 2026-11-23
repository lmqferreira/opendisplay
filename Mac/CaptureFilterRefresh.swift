import Foundation

enum CaptureFilterRefreshVariant: String {
    case display
    case applications
}

enum CaptureFilterRefreshError: Error, LocalizedError, Equatable {
    case unavailable
    case busy
    case changed
    case missingDisplay

    var errorDescription: String? {
        switch self {
        case .unavailable: return "No active display capture to refresh."
        case .busy: return "A capture refresh is already running."
        case .changed: return "The display capture changed during the refresh. Try again."
        case .missingDisplay: return "The captured display is no longer available."
        }
    }
}

/// Confined to the sender's pipeline lock; a retired request cannot finish a
/// newer stream's refresh or publish success after capture was replaced.
struct CaptureFilterRefreshGate {
    struct Target: Equatable {
        let displayID: UInt32
        let generation: UInt64
    }

    struct Request: Equatable {
        let id: UInt64
        let target: Target
    }

    private var target: Target?
    private var pending: Request?
    private var nextID: UInt64 = 0

    mutating func activate(displayID: UInt32, generation: UInt64) {
        target = Target(displayID: displayID, generation: generation)
        pending = nil
    }

    mutating func invalidate() {
        target = nil
        pending = nil
    }

    mutating func begin() throws -> Request {
        guard let target else { throw CaptureFilterRefreshError.unavailable }
        guard pending == nil else { throw CaptureFilterRefreshError.busy }
        nextID &+= 1
        let request = Request(id: nextID, target: target)
        pending = request
        return request
    }

    func isCurrent(_ request: Request) -> Bool {
        pending == request && target == request.target
    }

    @discardableResult
    mutating func finish(_ request: Request) -> Bool {
        guard isCurrent(request) else { return false }
        pending = nil
        return true
    }
}
