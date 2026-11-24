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
        "Teams controls are hidden from capture")
    private let detailField = NSTextField(labelWithString:
        "The window is still active, but its pixels cannot be shown here.")
    private let moveButton = ProtectedCaptureOverlayActionButton(
        title: "Move to main display"
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        messageField.alignment = .center
        messageField.textColor = .white
        messageField.lineBreakMode = .byTruncatingTail
        detailField.alignment = .center
        detailField.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        detailField.lineBreakMode = .byWordWrapping
        detailField.maximumNumberOfLines = 2
        messageField.lineBreakMode = .byWordWrapping
        messageField.maximumNumberOfLines = 2
        moveButton.target = self
        moveButton.action = #selector(moveToMain)
        addSubview(messageField)
        addSubview(detailField)
        addSubview(moveButton)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    @objc private func moveToMain() {
        onMoveToMain?()
    }

    override func layout() {
        super.layout()
        let buttonSize = NSSize(width: min(220, max(bounds.width - 32, 120)), height: 34)
        moveButton.frame = NSRect(
            x: (bounds.width - buttonSize.width) / 2,
            y: 14,
            width: buttonSize.width,
            height: buttonSize.height
        )
        messageField.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        messageField.frame = NSRect(
            x: 16, y: bounds.height - 38, width: bounds.width - 32, height: 22
        )
        detailField.font = NSFont.systemFont(ofSize: 11)
        detailField.frame = NSRect(
            x: 24, y: bounds.height - 64, width: bounds.width - 48, height: 24
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.055, green: 0.06, blue: 0.075, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        NSColor(calibratedWhite: 0.34, alpha: 1).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                     xRadius: 9, yRadius: 9).withLineWidth(3).stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ProtectedCaptureOverlayActionButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .shadowlessSquare
        isBordered = false
        font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        setButtonType(.momentaryPushIn)
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isHighlighted
            ? NSColor(calibratedRed: 0.88, green: 0.56, blue: 0.02, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.66, blue: 0.08, alpha: 1)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 0.06, alpha: 1)
            ]
        )
        let titleRect = attributedTitle.boundingRect(
            with: bounds.size, options: [.usesLineFragmentOrigin])
        attributedTitle.draw(in: NSRect(
            x: (bounds.width - titleRect.width) / 2,
            y: (bounds.height - titleRect.height) / 2,
            width: titleRect.width,
            height: titleRect.height
        ))
    }
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
