import AppKit
import CoreGraphics

struct ProtectedCaptureOverlayWindow: Equatable {
    let id: CGWindowID
    let processID: pid_t
    let owner: String
    let bounds: CGRect
    let layer: Int
    let sharingState: Int
    let alpha: Double
    let isOnscreen: Bool
}

struct ProtectedCaptureOverlay: Equatable {
    let windowID: CGWindowID
    let processID: pid_t
    let sourceBounds: CGRect
    let captureBounds: CGRect
    let windowLayer: Int
}

enum ProtectedCaptureOverlayDetector {
    static func teamsOverlays(
        windows: [ProtectedCaptureOverlayWindow],
        displayBounds: CGRect
    ) -> [ProtectedCaptureOverlay] {
        var seen = Set<CGWindowID>()
        return windows.compactMap { window in
            guard !seen.contains(window.id),
                  window.owner.hasPrefix("Microsoft Teams"),
                  window.isOnscreen,
                  window.alpha > 0.01,
                  window.layer > 0,
                  window.sharingState == 0 else { return nil }
            let clipped = window.bounds.intersection(displayBounds).integral
            guard clipped.width >= 40, clipped.height >= 24 else { return nil }
            seen.insert(window.id)
            return ProtectedCaptureOverlay(
                windowID: window.id,
                processID: window.processID,
                sourceBounds: window.bounds,
                captureBounds: clipped,
                windowLayer: window.layer
            )
        }
        .sorted { $0.windowID < $1.windowID }
    }

    static func appKitFrame(from cgFrame: CGRect, mainDisplayHeight: CGFloat) -> NSRect {
        NSRect(
            x: cgFrame.minX,
            y: mainDisplayHeight - cgFrame.maxY,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }
}

private final class ProtectedCaptureOverlayView: NSView {
    var onMoveToMain: (() -> Void)?
    private let messageField = NSTextField(labelWithString:
        "Teams controls are protected from capture.")
    private let moveButton = NSButton(
        title: "Move to main display",
        target: nil,
        action: nil
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        messageField.alignment = .center
        messageField.textColor = .white
        messageField.lineBreakMode = .byWordWrapping
        messageField.maximumNumberOfLines = 2
        moveButton.bezelStyle = .rounded
        moveButton.controlSize = .regular
        moveButton.target = self
        moveButton.action = #selector(moveToMain)
        addSubview(messageField)
        addSubview(moveButton)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    @objc private func moveToMain() {
        onMoveToMain?()
    }

    override func layout() {
        super.layout()
        let buttonSize = NSSize(width: min(190, max(bounds.width - 24, 80)), height: 28)
        moveButton.frame = NSRect(
            x: (bounds.width - buttonSize.width) / 2,
            y: 12,
            width: buttonSize.width,
            height: buttonSize.height
        )
        messageField.font = NSFont.systemFont(
            ofSize: min(max(bounds.height / 8, 12), 16), weight: .semibold)
        messageField.frame = NSRect(
            x: 12, y: 46, width: bounds.width - 24, height: max(bounds.height - 56, 20)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.97).setFill()
        bounds.fill()
        NSColor.systemOrange.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)).withLineWidth(4).stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension NSBezierPath {
    func withLineWidth(_ width: CGFloat) -> NSBezierPath {
        lineWidth = width
        return self
    }
}

enum ProtectedCaptureOverlayPreference {
    static let preferenceKey = "warnOnProtectedTeamsWindows"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: preferenceKey)
    }
}

@MainActor
final class ProtectedCaptureOverlayController {
    static let shared = ProtectedCaptureOverlayController()

    private var displays: [UUID: CGDirectDisplayID] = [:]
    private var panels: [CGWindowID: NSPanel] = [:]
    private var timer: Timer?
    private var enabled = ProtectedCaptureOverlayPreference.load()

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        ProtectedCaptureOverlayPreference.save(enabled)
        if enabled {
            schedule()
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            closeAllPanels()
        }
    }

    func start(token: UUID, displayID: CGDirectDisplayID) {
        displays[token] = displayID
        guard enabled else { return }
        schedule()
        refresh()
    }

    func stop(token: UUID, displayID: CGDirectDisplayID) {
        guard displays[token] == displayID else { return }
        displays[token] = nil
        if displays.isEmpty { timer?.invalidate(); timer = nil }
        refresh()
    }

    private func schedule() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
        timer?.tolerance = 0.15
    }

    private func refresh() {
        guard enabled else {
            closeAllPanels()
            return
        }
        let active = displays.values.compactMap { displayID -> CGRect? in
            let bounds = CGDisplayBounds(displayID)
            return bounds.isEmpty ? nil : bounds
        }
        let metadata = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let windows = metadata.compactMap { item -> ProtectedCaptureOverlayWindow? in
            guard let id = item[kCGWindowNumber as String] as? Int,
                  let processID = item[kCGWindowOwnerPID as String] as? pid_t,
                  let owner = item[kCGWindowOwnerName as String] as? String,
                  let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            return ProtectedCaptureOverlayWindow(
                id: CGWindowID(id),
                processID: processID,
                owner: owner,
                bounds: bounds,
                layer: item[kCGWindowLayer as String] as? Int ?? 0,
                sharingState: item[kCGWindowSharingState as String] as? Int
                    ?? 0,
                alpha: item[kCGWindowAlpha as String] as? Double ?? 0,
                isOnscreen: item[kCGWindowIsOnscreen as String] as? Bool
                    ?? true
            )
        }
        var wanted: [CGWindowID: ProtectedCaptureOverlay] = [:]
        for bounds in active {
            for overlay in ProtectedCaptureOverlayDetector.teamsOverlays(
                windows: windows, displayBounds: bounds
            ) {
                wanted[overlay.windowID] = overlay
            }
        }
        let stale = Set(panels.keys).subtracting(wanted.keys)
        for id in stale {
            panels.removeValue(forKey: id)?.close()
        }
        for (id, overlay) in wanted {
            let panel = panels[id] ?? makePanel(for: id)
            if let view = panel.contentView as? ProtectedCaptureOverlayView {
                view.onMoveToMain = { [weak self] in
                    self?.moveOverlayBackToMain(overlay)
                }
            }
            let frame = ProtectedCaptureOverlayDetector.appKitFrame(
                from: overlay.captureBounds,
                mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height
            )
            if panel.level.rawValue < NSWindow.Level(rawValue: overlay.windowLayer).rawValue {
                panel.level = NSWindow.Level(rawValue: overlay.windowLayer + 1)
            }
            panel.setFrame(frame, display: true)
            panel.contentView?.setFrameSize(frame.size)
            panel.contentView?.setNeedsDisplay(panel.contentView!.bounds)
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func makePanel(for id: CGWindowID) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.collectionBehavior = [.stationary]
        panel.contentView = ProtectedCaptureOverlayView(frame: .zero)
        panel.sharingType = .readOnly
        panels[id] = panel
        Log.info("Protected Teams overlay detected: window \(id); showing recovery warning")
        return panel
    }

    private func closeAllPanels() {
        let existing = panels.values
        panels.removeAll()
        for panel in existing { panel.close() }
    }

    private func moveOverlayBackToMain(_ overlay: ProtectedCaptureOverlay) {
        let targetBounds = CGDisplayBounds(CGMainDisplayID())
        let target = NSPoint(
            x: targetBounds.minX + 24,
            y: min(targetBounds.minY + 80, targetBounds.maxY - overlay.sourceBounds.height)
        )
        let app = AXUIElementCreateApplication(overlay.processID)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &windowsValue
        ) == .success, let windows = windowsValue as? [AXUIElement] else {
            Log.info("Could not move protected Teams window: accessibility window list unavailable")
            return
        }

        for window in windows {
            var positionValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                window, kAXPositionAttribute as CFString, &positionValue
            ) == .success, let positionValue else { continue }
            var position = CGPoint.zero
            guard AXValueGetValue(
                positionValue as! AXValue, .cgPoint, &position
            ) else { continue }
            guard abs(position.x - overlay.sourceBounds.minX) <= 2,
                  abs(position.y - overlay.sourceBounds.minY) <= 2 else { continue }
            var targetPosition = target
            let value = AXValueCreate(.cgPoint, &targetPosition)!
            let result = AXUIElementSetAttributeValue(
                window, kAXPositionAttribute as CFString, value
            )
            Log.info(result == .success
                ? "Moved protected Teams window \(overlay.windowID) back to the main display"
                : "Could not move protected Teams window \(overlay.windowID): AX error \(result.rawValue)")
            if result == .success { refresh() }
            return
        }
        Log.info("Could not move protected Teams window \(overlay.windowID): matching AX window not found")
    }
}
