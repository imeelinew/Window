import AppKit
import ApplicationServices

enum WindowController {
    enum Placement {
        case maximize
        case leftHalf
        case rightHalf
        case centered(width: CGFloat, height: CGFloat)
    }

    static func moveFocusedWindow(to placement: Placement) {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let window = focusedWindow(of: application.processIdentifier),
              let currentFrame = frame(of: window),
              let screen = screen(containing: currentFrame) else {
            return
        }

        let availableFrame = accessibilityFrame(for: screen)
        let targetFrame: CGRect

        switch placement {
        case .maximize:
            targetFrame = availableFrame
        case .leftHalf:
            targetFrame = CGRect(
                x: availableFrame.minX,
                y: availableFrame.minY,
                width: floor(availableFrame.width / 2),
                height: availableFrame.height
            )
        case .rightHalf:
            let leftWidth = floor(availableFrame.width / 2)
            targetFrame = CGRect(
                x: availableFrame.minX + leftWidth,
                y: availableFrame.minY,
                width: availableFrame.width - leftWidth,
                height: availableFrame.height
            )
        case let .centered(width, height):
            targetFrame = CGRect(
                x: (availableFrame.midX - width / 2).rounded(),
                y: (availableFrame.midY - height / 2).rounded(),
                width: width,
                height: height
            )
        }

        set(frame: targetFrame, of: window)
    }

    static func hideOtherApplications() {
        guard let current = NSWorkspace.shared.frontmostApplication else { return }

        minimizeOtherWindows(of: current.processIdentifier)

        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy == .regular && application != current {
            application.hide()
        }
    }

    private static func minimizeOtherWindows(of processIdentifier: pid_t) {
        guard AXIsProcessTrusted(),
              let focusedWindow = focusedWindow(of: processIdentifier) else {
            return
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
              let windows = value as? [AXUIElement] else {
            return
        }

        for window in windows where !CFEqual(window, focusedWindow) {
            AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanTrue
            )
        }
    }

    private static func focusedWindow(of processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
              let value else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, of: window),
              let size = sizeAttribute(kAXSizeAttribute, of: window) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(_ attribute: String, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value as! AXValue?,
              AXValueGetType(axValue) == .cgPoint else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ attribute: String, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value as! AXValue?,
              AXValueGetType(axValue) == .cgSize else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func screen(containing frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { accessibilityFullFrame(for: $0).contains(center) }
            ?? NSScreen.main
    }

    private static func accessibilityFullFrame(for screen: NSScreen) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return screen.frame }
        let frame = screen.frame
        return CGRect(
            x: frame.minX,
            y: primaryScreen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private static func accessibilityFrame(for screen: NSScreen) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first else { return screen.visibleFrame }
        let frame = screen.visibleFrame
        return CGRect(
            x: frame.minX,
            y: primaryScreen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private static func set(frame: CGRect, of window: AXUIElement) {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return
        }

        // Moving first prevents the current screen's edge constraints from limiting resizing.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    }
}
