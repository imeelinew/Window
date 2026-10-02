import AppKit
import ApplicationServices

final class WindowController {
    // One record owns both tracking and animation; transient records leave on completion.
    private final class State {
        let pid: pid_t
        let application: AXUIElement
        let electron: Bool
        var maximized = false
        var requested: CGRect
        var observed: CGRect
        var animation: Task<Void, Never>?
        var generation = 0

        init(_ application: NSRunningApplication, frame: CGRect) {
            pid = application.processIdentifier
            self.application = AXUIElementCreateApplication(pid)
            electron = WindowAnimator.isElectron(application)
            requested = frame
            observed = frame
        }

        func cancelAnimation() {
            generation &+= 1
            animation?.cancel()
            animation = nil
        }
    }

    private var windows: [AccessibleWindow: State] = [:]
    private let animator = WindowAnimator()

    deinit {
        for state in windows.values { state.animation?.cancel() }
    }

    var hasMaximizedWindows: Bool { windows.values.contains { $0.maximized } }

    func moveFocusedWindow(to placement: WindowPlacement) {
        guard let (application, window, frame, screen) = focusedWindow() else { return }

        let state = windows[window] ?? State(application, frame: frame)
        windows[window] = state
        state.maximized = placement == .maximize
        state.observed = frame
        animate(window, state: state, from: frame, to: placement.frame(in: screen.workArea))
    }

    @discardableResult
    func resizeFocusedWindow(_ axis: WindowResize, by amount: CGFloat) -> Bool {
        guard let (application, window, frame, screen) = focusedWindow(), window.canResize else { return false }
        let existing = windows[window]
        // Each press adjusts the latest request, even before the prior write settles.
        let base: CGRect
        if let existing, existing.animation != nil {
            base = existing.requested
        } else {
            base = frame
        }
        guard let target = axis.frame(from: base, in: screen.workArea, by: amount) else { return false }
        let state = existing ?? State(application, frame: frame)
        windows[window] = state
        state.maximized = false
        state.observed = frame
        animate(window, state: state, from: frame, to: target, centeredResize: true)
        return true
    }

    private func focusedWindow() -> (NSRunningApplication, AccessibleWindow, CGRect, ScreenArea)? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let window = AccessibleWindow.focused(in: AXUIElementCreateApplication(application.processIdentifier)),
              let frame = window.frame,
              let screen = ScreenArea.containing(frame, in: ScreenArea.current) else { return nil }
        return (application, window, frame, screen)
    }

    func adoptMaximizedWindows(of pid: pid_t? = nil) {
        guard AXIsProcessTrusted() else { return }
        let applications: [NSRunningApplication]
        if let pid {
            guard let application = NSRunningApplication(processIdentifier: pid) else { return }
            applications = [application]
        } else {
            applications = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isTerminated
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
        }
        let screens = ScreenArea.current
        for application in applications {
            for window in AccessibleWindow.all(in: AXUIElementCreateApplication(application.processIdentifier)) {
                guard windows[window] == nil, window.isStandardUnminimized,
                      let frame = window.frame,
                      let screen = ScreenArea.containing(frame, in: screens),
                      frame.resemblesMaximized(in: screen) else { continue }
                let state = State(application, frame: frame)
                state.maximized = true
                state.requested = screen.workArea
                windows[window] = state
                if !frame.aligns(with: screen.workArea) {
                    animate(window, state: state, from: frame, to: screen.workArea)
                }
            }
        }
    }

    @discardableResult
    func reconcileMaximizedWindows(respectManualChanges: Bool = true) -> Bool {
        guard AXIsProcessTrusted() else {
            for state in windows.values { state.cancelAnimation() }
            windows.removeAll()
            return true
        }
        let screens = ScreenArea.current
        var settled = true
        for (window, state) in windows where state.maximized {
            guard let frame = window.frame,
                  let screen = ScreenArea.containing(frame, in: screens) else {
                remove(window)
                continue
            }
            let target = screen.workArea
            let targetChanged = !target.matches(state.requested, tolerance: 1)
            if frame.aligns(with: target) {
                if targetChanged { state.cancelAnimation() }
                state.requested = target
                state.observed = frame
                continue
            }
            if respectManualChanges, state.animation == nil, !targetChanged,
               !frame.matches(state.observed, tolerance: 8) {
                remove(window)
                continue
            }
            settled = false
            state.observed = frame
            if targetChanged || state.animation == nil {
                animate(window, state: state, from: frame, to: target)
            }
        }
        return settled
    }

    func removeWindows(of pid: pid_t) {
        for (window, state) in windows where state.pid == pid { remove(window) }
    }

    private func remove(_ window: AccessibleWindow) {
        windows.removeValue(forKey: window)?.cancelAnimation()
    }

    private func animate(_ window: AccessibleWindow, state: State, from start: CGRect, to target: CGRect,
                         centeredResize: Bool = false) {
        state.cancelAnimation()
        state.requested = target
        let generation = state.generation
        let animator = animator
        state.animation = Task { @MainActor [weak self, weak state] in
            guard let state else { return }
            if centeredResize {
                await animator.resizeCentered(window, application: state.application, pid: state.pid,
                                              from: start, to: target)
            } else {
                await animator.move(window, application: state.application, pid: state.pid,
                                    from: start, to: target, electron: state.electron, maximized: state.maximized)
            }
            guard !Task.isCancelled, state.generation == generation, let self else { return }
            state.animation = nil
            if state.maximized {
                if let frame = window.frame { state.observed = frame }
            } else {
                windows.removeValue(forKey: window)
            }
        }
    }
}
