import AppKit
import ApplicationServices

final class WorkspaceMonitor: NSObject {
    private static let dockIdentifier = "com.apple.dock"
    private let windows: WindowController
    private var layout = ScreenArea.current
    private var settlingTask: Task<Void, Never>?
    private var dockConnectionTask: Task<Void, Never>?
    private var dockObserver: AXObserver?
    private var dockItems: [AXUIElement] = []

    init(windows: WindowController) {
        self.windows = windows
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            center.addObserver(self, selector: #selector(applicationChanged), name: name, object: nil)
        }
        ensureDockConnection()
        windows.adoptMaximizedWindows()
    }

    deinit {
        settlingTask?.cancel()
        dockConnectionTask?.cancel()
        if let dockObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(dockObserver), .commonModes)
        }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func screenChanged(_ notification: Notification) {
        ensureDockConnection()
        windows.adoptMaximizedWindows()
        let changed = updateLayout()
        if changed { windows.reconcileMaximizedWindows(respectManualChanges: false) }
        settle(reconcile: changed, environmentChanged: changed)
    }

    @objc private func applicationChanged(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let terminated = notification.name == NSWorkspace.didTerminateApplicationNotification
        if terminated, let application { windows.removeWindows(of: application.processIdentifier) }
        if application?.bundleIdentifier == Self.dockIdentifier {
            disconnectDock()
        }
        ensureDockConnection()

        let becameAvailable = notification.name == NSWorkspace.didActivateApplicationNotification
            || notification.name == NSWorkspace.didUnhideApplicationNotification
        windows.adoptMaximizedWindows(of: becameAvailable ? application?.processIdentifier : nil)
        settle(reconcile: becameAvailable)
    }

    private func updateLayout() -> Bool {
        let current = ScreenArea.current
        guard current != layout else { return false }
        layout = current
        return true
    }

    private func settle(reconcile: Bool, environmentChanged: Bool = false) {
        settlingTask?.cancel()
        settlingTask = nil
        guard windows.hasMaximizedWindows else { return }
        // Dock notifications precede the animation. Sample only for this event,
        // for at most three seconds, then release the task completely.
        settlingTask = Task { @MainActor [weak self] in
            var shouldReconcile = reconcile
            var changed = environmentChanged
            var stableSamples = 0
            for _ in 0..<30 {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if updateLayout() {
                    shouldReconcile = true
                    changed = true
                    stableSamples = 0
                    windows.adoptMaximizedWindows()
                } else if shouldReconcile {
                    stableSamples += 1
                }
                if shouldReconcile,
                   windows.reconcileMaximizedWindows(respectManualChanges: !changed),
                   stableSamples >= 4 {
                    settlingTask = nil
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
            }
            self?.settlingTask = nil
        }
    }

    private func ensureDockConnection() {
        guard dockObserver == nil, dockConnectionTask == nil, AXIsProcessTrusted() else { return }
        if connectDock() { return }
        dockConnectionTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                if connectDock() {
                    dockConnectionTask = nil
                    return
                }
            }
            self?.dockConnectionTask = nil
        }
    }

    private func connectDock() -> Bool {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockIdentifier).first else {
            return false
        }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = (application.attribute(kAXChildrenAttribute) as? [AXUIElement])?.first else { return false }
        var reference: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, Self.dockCallback, &reference) == .success,
              let observer = reference else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var observingCreation = false
        for element in [application, list] {
            if AXObserverAddNotification(observer, element, kAXCreatedNotification as CFString, context) == .success {
                observingCreation = true
            }
        }
        guard observingCreation else { return false }
        dockObserver = observer
        for item in list.attribute(kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            observeDestruction(of: item)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        return true
    }

    private func disconnectDock() {
        dockConnectionTask?.cancel()
        dockConnectionTask = nil
        if let dockObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(dockObserver), .commonModes)
        }
        dockObserver = nil
        dockItems.removeAll()
    }

    private func observeDestruction(of item: AXUIElement) {
        guard let dockObserver, !dockItems.contains(where: { CFEqual($0, item) }) else { return }
        let result = AXObserverAddNotification(
            dockObserver, item, kAXUIElementDestroyedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if result == .success || result == .notificationAlreadyRegistered { dockItems.append(item) }
    }

    private static let dockCallback: AXObserverCallback = { _, element, notification, context in
        guard let context else { return }
        let monitor = Unmanaged<WorkspaceMonitor>.fromOpaque(context).takeUnretainedValue()
        if notification == kAXCreatedNotification as CFString {
            monitor.observeDestruction(of: element)
        } else if notification == kAXUIElementDestroyedNotification as CFString {
            monitor.dockItems.removeAll { CFEqual($0, element) }
        }
        monitor.windows.adoptMaximizedWindows()
        monitor.settle(reconcile: false)
    }
}
