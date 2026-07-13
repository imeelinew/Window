import AppKit
import ApplicationServices

enum WindowController {
    private static let animationDuration = 0.20
    private static let animationFrameInterval = 1.0 / 60.0
    private static let finalCommitDelay: UInt64 = 16_000_000
    private static let finalVerificationDelay: UInt64 = 40_000_000
    private static let finalCommitAttempts = 5
    private static let edgeAlignmentTolerance: CGFloat = 0.5
    // AX frames exclude part of the system-drawn bottom shadow. Being one point
    // short is visually flush; extending past the work area is never accepted.
    private static let bottomShadowAllowance: CGFloat = 1
    private static var animationStates: [WindowAnimationState] = []
    private static var managedMaximizedWindows: [ManagedMaximizedWindow] = []
    private static var enhancedUILeases: [EnhancedUILease] = []

    private struct ManagedMaximizedWindow {
        let window: AXUIElement
        let processIdentifier: pid_t
        let animationStrategy: AnimationStrategy
        var lastRequestedFrame: CGRect
        var lastObservedFrame: CGRect
    }

    private enum AnimationStrategy {
        case smoothFrame
        case stableSizeThenPosition
    }

    private final class EnhancedUILease {
        let processIdentifier: pid_t
        let application: AXUIElement
        let wasEnabled: Bool
        var count = 1

        init(processIdentifier: pid_t, application: AXUIElement, wasEnabled: Bool) {
            self.processIdentifier = processIdentifier
            self.application = application
            self.wasEnabled = wasEnabled
        }
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
        let animationStrategy = animationStrategy(for: application, placement: placement)
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
            manageMaximizedWindow(
                window,
                processIdentifier: application.processIdentifier,
                strategy: animationStrategy,
                currentFrame: currentFrame,
                targetFrame: targetFrame
            )
        } else {
            stopManaging(window)
        }

        animate(
            window: window,
            from: currentFrame,
            to: targetFrame,
            strategy: animationStrategy
        )
    }

    static var hasManagedMaximizedWindows: Bool {
        !managedMaximizedWindows.isEmpty
    }

    static func adoptExistingMaximizedWindows(
        of processIdentifier: pid_t? = nil
    ) {
        guard AXIsProcessTrusted() else { return }

        let applications: [NSRunningApplication]
        if let processIdentifier,
           let application = NSRunningApplication(
            processIdentifier: processIdentifier
           ) {
            applications = [application]
        } else {
            applications = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular
                    && !$0.isTerminated
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
        }

        for application in applications {
            let applicationElement = AXUIElementCreateApplication(
                application.processIdentifier
            )
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                applicationElement,
                kAXWindowsAttribute as CFString,
                &windowsValue
            ) == .success,
                  let windows = windowsValue as? [AXUIElement] else {
                continue
            }

            for window in windows where managedWindowIndex(for: window) == nil {
                guard isStandardUnminimizedWindow(window),
                      let currentFrame = frame(of: window),
                      let screen = screen(containing: currentFrame) else {
                    continue
                }

                let targetFrame = accessibilityFrame(for: screen)
                guard resemblesMaximizedWindow(
                    currentFrame,
                    targetFrame: targetFrame,
                    fullFrame: accessibilityFullFrame(for: screen)
                ) else {
                    continue
                }

                let strategy = animationStrategy(
                    for: application,
                    placement: .maximize
                )
                manageMaximizedWindow(
                    window,
                    processIdentifier: application.processIdentifier,
                    strategy: strategy,
                    currentFrame: currentFrame,
                    targetFrame: targetFrame
                )

                if !visuallyAlignedWithWorkArea(
                    currentFrame,
                    targetFrame
                ) {
                    animate(
                        window: window,
                        from: currentFrame,
                        to: targetFrame,
                        strategy: strategy
                    )
                }
            }
        }
    }

    @discardableResult
    static func refreshManagedMaximizedWindow(
        respectManualChanges: Bool = true
    ) -> Bool {
        guard AXIsProcessTrusted() else {
            managedMaximizedWindows.removeAll()
            return true
        }

        var retainedWindows: [ManagedMaximizedWindow] = []
        var allWindowsSettled = true

        for var managedWindow in managedMaximizedWindows {
            guard let currentFrame = frame(of: managedWindow.window),
                  let screen = screen(containing: currentFrame) else {
                cancelAnimation(for: managedWindow.window)
                continue
            }

            let targetFrame = accessibilityFrame(for: screen)
            let targetChanged = !approximatelyEqual(
                targetFrame,
                managedWindow.lastRequestedFrame,
                tolerance: 1
            )
            let currentFrameMatchesTarget = visuallyAlignedWithWorkArea(
                currentFrame,
                targetFrame
            )
            let windowIsAnimating = isAnimating(managedWindow.window)

            if currentFrameMatchesTarget {
                if targetChanged && windowIsAnimating {
                    cancelAnimation(for: managedWindow.window)
                }
                managedWindow.lastRequestedFrame = targetFrame
                managedWindow.lastObservedFrame = currentFrame
                retainedWindows.append(managedWindow)
                continue
            }

            if respectManualChanges,
               !windowIsAnimating,
               !targetChanged,
               !approximatelyEqual(
                   currentFrame,
                   managedWindow.lastObservedFrame,
                   tolerance: 8
               ) {
                cancelAnimation(for: managedWindow.window)
                continue
            }

            allWindowsSettled = false
            if targetChanged {
                managedWindow.lastRequestedFrame = targetFrame
            }
            managedWindow.lastObservedFrame = currentFrame
            retainedWindows.append(managedWindow)

            // A target application may temporarily reject AX writes while hidden,
            // changing Spaces, or rebuilding an Electron window. Retry after the
            // prior animation finishes even when the desired frame is unchanged.
            if targetChanged || !windowIsAnimating {
                animate(
                    window: managedWindow.window,
                    from: currentFrame,
                    to: targetFrame,
                    strategy: managedWindow.animationStrategy
                )
            }
        }

        managedMaximizedWindows = retainedWindows
        return allWindowsSettled
    }

    private static func manageMaximizedWindow(
        _ window: AXUIElement,
        processIdentifier: pid_t,
        strategy: AnimationStrategy,
        currentFrame: CGRect,
        targetFrame: CGRect
    ) {
        let managedWindow = ManagedMaximizedWindow(
            window: window,
            processIdentifier: processIdentifier,
            animationStrategy: strategy,
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

    static func stopManagingWindows(of processIdentifier: pid_t) {
        let windows = managedMaximizedWindows
            .filter { $0.processIdentifier == processIdentifier }
            .map(\.window)

        managedMaximizedWindows.removeAll {
            $0.processIdentifier == processIdentifier
        }
        for window in windows {
            cancelAnimation(for: window)
        }
    }

    private static func managedWindowIndex(for window: AXUIElement) -> Int? {
        managedMaximizedWindows.firstIndex { CFEqual($0.window, window) }
    }

    private static func isStandardUnminimizedWindow(_ window: AXUIElement) -> Bool {
        var subroleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success,
              subroleValue as? String == kAXStandardWindowSubrole else {
            return false
        }

        var minimizedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            &minimizedValue
        ) == .success,
           minimizedValue as? Bool == true {
            return false
        }
        return true
    }

    private static func resemblesMaximizedWindow(
        _ frame: CGRect,
        targetFrame: CGRect,
        fullFrame: CGRect
    ) -> Bool {
        let fixedEdgeTolerance: CGFloat = 4
        let maximumDockEdgeDrift: CGFloat = 120
        let dockIsOnLeft = targetFrame.minX - fullFrame.minX > fixedEdgeTolerance
        let dockIsOnRight = fullFrame.maxX - targetFrame.maxX > fixedEdgeTolerance
        let dockIsOnBottom = fullFrame.maxY - targetFrame.maxY > fixedEdgeTolerance

        return abs(frame.minY - targetFrame.minY) <= fixedEdgeTolerance
            && abs(frame.minX - targetFrame.minX) <= (
                dockIsOnLeft ? maximumDockEdgeDrift : fixedEdgeTolerance
            )
            && abs(frame.maxX - targetFrame.maxX) <= (
                dockIsOnRight ? maximumDockEdgeDrift : fixedEdgeTolerance
            )
            && abs(frame.maxY - targetFrame.maxY) <= (
                dockIsOnBottom ? maximumDockEdgeDrift : fixedEdgeTolerance
            )
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

    private static func animate(
        window: AXUIElement,
        from startFrame: CGRect,
        to targetFrame: CGRect,
        strategy: AnimationStrategy
    ) {
        let state = animationState(for: window)
        state.task?.cancel()
        state.generation &+= 1
        let generation = state.generation

        state.task = Task { @MainActor in
            let enhancedUILease = acquireEnhancedUserInterfaceLease(for: window)
            defer { releaseEnhancedUserInterfaceLease(enhancedUILease) }

            if strategy == .stableSizeThenPosition {
                await animateStableSizeThenPosition(
                    window: window,
                    from: startFrame,
                    to: targetFrame
                )
                finishAnimation(state, generation: generation)
                return
            }

            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                || startFrame == targetFrame {
                await commit(frame: targetFrame, to: window)
                finishAnimation(state, generation: generation)
                return
            }

            let startTime = ProcessInfo.processInfo.systemUptime
            var nextFrameTime = startTime

            while !Task.isCancelled {
                let currentTime = ProcessInfo.processInfo.systemUptime
                let elapsed = currentTime - startTime
                let progress = min(elapsed / animationDuration, 1)
                let easedProgress = 1 - pow(1 - progress, 3)

                if progress >= 1 {
                    await commit(frame: targetFrame, to: window)
                    break
                }

                set(
                    frame: interpolate(from: startFrame, to: targetFrame, progress: easedProgress),
                    of: window
                )

                nextFrameTime += animationFrameInterval
                let delay = nextFrameTime - ProcessInfo.processInfo.systemUptime
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    await Task.yield()
                }
            }

            finishAnimation(state, generation: generation)
        }
    }

    private static func animateStableSizeThenPosition(
        window: AXUIElement,
        from startFrame: CGRect,
        to targetFrame: CGRect
    ) async {
        setSize(targetFrame.size, of: window)
        try? await Task.sleep(nanoseconds: finalVerificationDelay)
        guard !Task.isCancelled else { return }

        let actualFrame = frame(of: window) ?? startFrame
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              actualFrame.origin != targetFrame.origin else {
            await commit(frame: targetFrame, to: window)
            return
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        var nextFrameTime = startTime

        while !Task.isCancelled {
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let progress = min(elapsed / animationDuration, 1)
            let easedProgress = 1 - pow(1 - progress, 3)

            if progress >= 1 { break }

            setPosition(
                interpolate(
                    from: actualFrame,
                    to: targetFrame,
                    progress: easedProgress
                ).origin,
                of: window
            )

            nextFrameTime += animationFrameInterval
            let delay = nextFrameTime - ProcessInfo.processInfo.systemUptime
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } else {
                await Task.yield()
            }
        }

        await commit(frame: targetFrame, to: window)
    }

    private static func animationStrategy(
        for application: NSRunningApplication,
        placement: Placement
    ) -> AnimationStrategy {
        guard let bundleURL = application.bundleURL,
              let bundle = Bundle(url: bundleURL),
              bundle.object(forInfoDictionaryKey: "ElectronAsarIntegrity") != nil else {
            return .smoothFrame
        }

        if case .centered = placement {
            return .stableSizeThenPosition
        }
        return .smoothFrame
    }

    private static func acquireEnhancedUserInterfaceLease(
        for window: AXUIElement
    ) -> EnhancedUILease? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(window, &processIdentifier) == .success else { return nil }

        if let lease = enhancedUILeases.first(where: {
            $0.processIdentifier == processIdentifier
        }) {
            lease.count += 1
            return lease
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        let attribute = "AXEnhancedUserInterface" as CFString
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, attribute, &value) == .success else {
            return nil
        }

        let wasEnabled = value as? Bool == true
        if wasEnabled {
            AXUIElementSetAttributeValue(application, attribute, kCFBooleanFalse)
        }
        let lease = EnhancedUILease(
            processIdentifier: processIdentifier,
            application: application,
            wasEnabled: wasEnabled
        )
        enhancedUILeases.append(lease)
        return lease
    }

    private static func releaseEnhancedUserInterfaceLease(_ lease: EnhancedUILease?) {
        guard let lease else { return }
        lease.count -= 1
        guard lease.count == 0 else { return }

        if lease.wasEnabled {
            AXUIElementSetAttributeValue(
                lease.application,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanTrue
            )
        }
        enhancedUILeases.removeAll { $0 === lease }
    }

    private static func finishAnimation(
        _ state: WindowAnimationState,
        generation: Int
    ) {
        guard generation == state.generation else { return }
        state.task = nil
        synchronizeManagedFrame(for: state.window)
        removeAnimationState(state)
    }

    private static func commit(frame targetFrame: CGRect, to window: AXUIElement) async {
        var requestedFrame = targetFrame

        for _ in 0..<finalCommitAttempts {
            guard !Task.isCancelled else { return }

            setSize(requestedFrame.size, of: window)
            try? await Task.sleep(nanoseconds: finalCommitDelay)
            guard !Task.isCancelled else { return }

            setPosition(requestedFrame.origin, of: window)
            try? await Task.sleep(nanoseconds: finalCommitDelay)
            setSize(requestedFrame.size, of: window)
            try? await Task.sleep(nanoseconds: finalVerificationDelay)

            if let actualFrame = frame(of: window) {
                if frameIsSettled(
                    actualFrame,
                    targetFrame: targetFrame,
                    window: window
                ) {
                    return
                }

                // Some Electron windows consistently apply a one-point smaller
                // frame than requested. Feed the measured residual into the next
                // request so the resulting frame, rather than the input value,
                // lands exactly on the desired work-area edges.
                requestedFrame = CGRect(
                    x: requestedFrame.minX + targetFrame.minX - actualFrame.minX,
                    y: requestedFrame.minY + targetFrame.minY - actualFrame.minY,
                    width: max(
                        1,
                        requestedFrame.width + targetFrame.width - actualFrame.width
                    ),
                    height: max(
                        1,
                        requestedFrame.height + targetFrame.height - actualFrame.height
                    )
                )
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
        state.generation &+= 1
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

    private static func visuallyAlignedWithWorkArea(
        _ frame: CGRect,
        _ workArea: CGRect
    ) -> Bool {
        let bottomDelta = frame.maxY - workArea.maxY

        return abs(frame.minX - workArea.minX) <= edgeAlignmentTolerance
            && abs(frame.minY - workArea.minY) <= edgeAlignmentTolerance
            && abs(frame.width - workArea.width) <= edgeAlignmentTolerance
            && bottomDelta <= edgeAlignmentTolerance
            && bottomDelta >= -bottomShadowAllowance
    }

    private static func frameIsSettled(
        _ frame: CGRect,
        targetFrame: CGRect,
        window: AXUIElement
    ) -> Bool {
        if managedWindowIndex(for: window) != nil {
            return visuallyAlignedWithWorkArea(frame, targetFrame)
        }
        return approximatelyEqual(
            frame,
            targetFrame,
            tolerance: edgeAlignmentTolerance
        )
    }

    private static func set(frame: CGRect, of window: AXUIElement) {
        // Size first avoids apps clamping a moved, still-oversized window back onscreen.
        setSize(frame.size, of: window)
        setPosition(frame.origin, of: window)
    }

    @discardableResult
    private static func setPosition(_ position: CGPoint, of window: AXUIElement) -> AXError {
        var position = position
        guard let positionValue = AXValueCreate(.cgPoint, &position) else {
            return .illegalArgument
        }
        return AXUIElementSetAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            positionValue
        )
    }

    @discardableResult
    private static func setSize(_ size: CGSize, of window: AXUIElement) -> AXError {
        var size = size
        guard let sizeValue = AXValueCreate(.cgSize, &size) else {
            return .illegalArgument
        }
        return AXUIElementSetAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            sizeValue
        )
    }

}
