import AppKit
import CoreGraphics

struct ProtectedCaptureOverlayWindow: Equatable {
    let id: CGWindowID
    let owner: String
    let bounds: CGRect
    let layer: Int
    let sharingState: Int
    let alpha: Double
    let isOnscreen: Bool
}

struct ProtectedCaptureOverlay: Equatable {
    let windowID: CGWindowID
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
    var message = "Teams controls are protected from screen capture.\nUse the full Teams window; clicks here are blocked."

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.97).setFill()
        bounds.fill()
        NSColor.systemOrange.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)).withLineWidth(4).stroke()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: min(max(bounds.height / 7, 12), 18),
                                      weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ]
        let attributed = NSAttributedString(string: message, attributes: attributes)
        let text = attributed.boundingRect(
            with: NSSize(width: max(bounds.width - 20, 1), height: bounds.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        attributed.draw(in: NSRect(
            x: max(10, (bounds.width - text.width) / 2),
            y: (bounds.height - text.height) / 2,
            width: min(text.width, bounds.width - 20),
            height: text.height
        ))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

private extension NSBezierPath {
    func withLineWidth(_ width: CGFloat) -> NSBezierPath {
        lineWidth = width
        return self
    }
}

@MainActor
final class ProtectedCaptureOverlayController {
    static let shared = ProtectedCaptureOverlayController()

    private var displays: [UUID: CGDirectDisplayID] = [:]
    private var panels: [CGWindowID: NSPanel] = [:]
    private var timer: Timer?

    func start(token: UUID, displayID: CGDirectDisplayID) {
        displays[token] = displayID
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
        let active = displays.values.compactMap { displayID -> CGRect? in
            let bounds = CGDisplayBounds(displayID)
            return bounds.isEmpty ? nil : bounds
        }
        let metadata = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let windows = metadata.compactMap { item -> ProtectedCaptureOverlayWindow? in
            guard let id = item[kCGWindowNumber as String] as? Int,
                  let owner = item[kCGWindowOwnerName as String] as? String,
                  let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            return ProtectedCaptureOverlayWindow(
                id: CGWindowID(id),
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
        Log.info("Protected Teams overlay detected: window \(id); showing blocking capture warning")
        return panel
    }
}
