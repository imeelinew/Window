import AppKit
import ApplicationServices

enum WindowController {
    private static let animationDuration = 0.20
    private static let animationFrameInterval = 1.0 / 60.0
    private static var animationStates: [WindowAnimationState] = []
    private static var managedMaximizedWindows: [ManagedMaximizedWindow] = []

    private struct ManagedMaximizedWindow {
        let window: AXUIElement
        var lastRequestedFrame: CGRect
        var lastObservedFrame: CGRect
    }

    private final class WindowAnimationState {
        let window: AXUIElement
        var task: Task<Void, Never>?
        var generation = 0

        init(window: AXUIElement) {
            self.window = window
        }
    }

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

        if case .maximize = placement {
            manageMaximizedWindow(window, currentFrame: currentFrame, targetFrame: targetFrame)
        } else {
            stopManaging(window)
        }

        animate(window: window, from: currentFrame, to: targetFrame)
    }

    static func refreshManagedMaximizedWindow(respectManualChanges: Bool = true) {
        guard AXIsProcessTrusted() else {
            managedMaximizedWindows.removeAll()
            return
        }

        var retainedWindows: [ManagedMaximizedWindow] = []

        for var managedWindow in managedMaximizedWindows {
            guard let currentFrame = frame(of: managedWindow.window),
                  let screen = screen(containing: currentFrame) else {
                cancelAnimation(for: managedWindow.window)
                continue
            }

            if respectManualChanges,
               !isAnimating(managedWindow.window),
               !approximatelyEqual(
                   currentFrame,
                   managedWindow.lastObservedFrame,
                   tolerance: 8
               ) {
                cancelAnimation(for: managedWindow.window)
                continue
            }

            let targetFrame = accessibilityFrame(for: screen)
            if !approximatelyEqual(
                targetFrame,
                managedWindow.lastRequestedFrame,
                tolerance: 1
            ) {
                managedWindow.lastRequestedFrame = targetFrame
                managedWindow.lastObservedFrame = currentFrame
                retainedWindows.append(managedWindow)
                animate(window: managedWindow.window, from: currentFrame, to: targetFrame)
            } else {
                retainedWindows.append(managedWindow)
            }
        }

        managedMaximizedWindows = retainedWindows
    }

    private static func manageMaximizedWindow(
        _ window: AXUIElement,
        currentFrame: CGRect,
        targetFrame: CGRect
    ) {
        let managedWindow = ManagedMaximizedWindow(
            window: window,
            lastRequestedFrame: targetFrame,
            lastObservedFrame: currentFrame
        )

        if let index = managedWindowIndex(for: window) {
            managedMaximizedWindows[index] = managedWindow
        } else {
            managedMaximizedWindows.append(managedWindow)
        }
    }

    private static func stopManaging(_ window: AXUIElement) {
        managedMaximizedWindows.removeAll { CFEqual($0.window, window) }
        cancelAnimation(for: window)
    }

    private static func managedWindowIndex(for window: AXUIElement) -> Int? {
        managedMaximizedWindows.firstIndex { CFEqual($0.window, window) }
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

    private static func animate(window: AXUIElement, from startFrame: CGRect, to targetFrame: CGRect) {
        let state = animationState(for: window)
        state.task?.cancel()
        state.generation &+= 1
        let generation = state.generation

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              startFrame != targetFrame else {
            set(frame: targetFrame, of: window)
            synchronizeManagedFrame(for: window)
            state.task = nil
            removeAnimationState(state)
            return
        }

        state.task = Task { @MainActor in
            let startTime = ProcessInfo.processInfo.systemUptime
            var nextFrameTime = startTime

            while !Task.isCancelled {
                let currentTime = ProcessInfo.processInfo.systemUptime
                let elapsed = currentTime - startTime
                let progress = min(elapsed / animationDuration, 1)
                let easedProgress = 1 - pow(1 - progress, 3)

                if progress >= 1 {
                    set(frame: targetFrame, of: window)
                    break
                }

                set(
                    frame: interpolate(from: startFrame, to: targetFrame, progress: easedProgress),
                    of: window,
                    reassertPosition: false
                )

                nextFrameTime += animationFrameInterval
                let delay = nextFrameTime - ProcessInfo.processInfo.systemUptime
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    await Task.yield()
                }
            }

            if generation == state.generation {
                state.task = nil
                synchronizeManagedFrame(for: window)
                removeAnimationState(state)
            }
        }
    }

    private static func animationState(for window: AXUIElement) -> WindowAnimationState {
        if let state = animationStates.first(where: { CFEqual($0.window, window) }) {
            return state
        }

        let state = WindowAnimationState(window: window)
        animationStates.append(state)
        return state
    }

    private static func isAnimating(_ window: AXUIElement) -> Bool {
        animationStates.contains { CFEqual($0.window, window) && $0.task != nil }
    }

    private static func cancelAnimation(for window: AXUIElement) {
        guard let state = animationStates.first(where: { CFEqual($0.window, window) }) else {
            return
        }
        state.task?.cancel()
        state.task = nil
        removeAnimationState(state)
    }

    private static func removeAnimationState(_ state: WindowAnimationState) {
        animationStates.removeAll { $0 === state }
    }

    private static func synchronizeManagedFrame(for window: AXUIElement) {
        guard let index = managedWindowIndex(for: window),
              let actualFrame = frame(of: window) else {
            return
        }
        managedMaximizedWindows[index].lastObservedFrame = actualFrame
    }

    private static func interpolate(from start: CGRect, to target: CGRect, progress: Double) -> CGRect {
        func value(from start: CGFloat, to target: CGFloat) -> CGFloat {
            start + (target - start) * progress
        }

        return CGRect(
            x: value(from: start.minX, to: target.minX),
            y: value(from: start.minY, to: target.minY),
            width: value(from: start.width, to: target.width),
            height: value(from: start.height, to: target.height)
        )
    }

    private static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func set(
        frame: CGRect,
        of window: AXUIElement,
        reassertPosition: Bool = true
    ) {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            return
        }

        // Moving first prevents the current screen's edge constraints from limiting resizing.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        if reassertPosition {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
    }
}
