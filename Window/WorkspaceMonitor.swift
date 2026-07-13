import AppKit
import ApplicationServices

final class WorkspaceMonitor: NSObject {
    private static let dockBundleIdentifier = "com.apple.dock"
    private static let settlingInterval: UInt64 = 100_000_000
    private static let maximumSettlingSamples = 30
    private static let requiredStableSamples = 4

    private enum SettlingMode {
        case waitForScreenLayoutChange
        case reconcileManagedWindows
    }

    private struct ScreenLayout: Equatable {
        private struct ScreenState: Equatable {
            let displayIdentifier: UInt32
            let frame: CGRect
            let visibleFrame: CGRect
        }

        private let screens: [ScreenState]

        static var current: ScreenLayout {
            let states = NSScreen.screens.enumerated().map { index, screen in
                let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
                let displayIdentifier = (
                    screen.deviceDescription[screenNumberKey] as? NSNumber
                )?.uint32Value ?? UInt32(index)

                return ScreenState(
                    displayIdentifier: displayIdentifier,
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame
                )
            }
            .sorted { $0.displayIdentifier < $1.displayIdentifier }

            return ScreenLayout(screens: states)
        }
    }

    private var refreshTask: Task<Void, Never>?
    private var dockConnectionTask: Task<Void, Never>?
    private var lastScreenLayout = ScreenLayout.current
    private var dockObserver: AXObserver?
    private var observedDockItems: [AXUIElement] = []

    override init() {
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationsDidChange),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationsDidChange),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(managedApplicationBecameAvailable),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(managedApplicationBecameAvailable),
            name: NSWorkspace.didUnhideApplicationNotification,
            object: nil
        )

        reconnectToDock()
        WindowController.adoptExistingMaximizedWindows()
    }

    deinit {
        refreshTask?.cancel()
        dockConnectionTask?.cancel()
        disconnectFromDock()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        ensureDockConnection()
        WindowController.adoptExistingMaximizedWindows()
        let currentLayout = ScreenLayout.current
        let layoutChanged = currentLayout != lastScreenLayout

        if layoutChanged {
            lastScreenLayout = currentLayout
            WindowController.refreshManagedMaximizedWindow(respectManualChanges: false)
        }

        scheduleSettlingRefreshes(
            mode: layoutChanged ? .reconcileManagedWindows : .waitForScreenLayoutChange,
            environmentalChangeAlreadyObserved: layoutChanged
        )
    }

    @objc private func workspaceApplicationsDidChange(_ notification: Notification) {
        let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication

        if notification.name == NSWorkspace.didTerminateApplicationNotification,
           let application {
            WindowController.stopManagingWindows(of: application.processIdentifier)
        }

        if application?.bundleIdentifier == Self.dockBundleIdentifier {
            reconnectToDock()
        } else {
            ensureDockConnection()
        }

        WindowController.adoptExistingMaximizedWindows()
        // An app appearing or disappearing can add or remove a Dock tile. Wait for
        // NSScreen.visibleFrame to actually change before touching managed windows.
        scheduleSettlingRefreshes(mode: .waitForScreenLayoutChange)
    }

    @objc private func managedApplicationBecameAvailable(_ notification: Notification) {
        ensureDockConnection()
        let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
        ] as? NSRunningApplication
        WindowController.adoptExistingMaximizedWindows(
            of: application?.processIdentifier
        )
        guard WindowController.hasManagedMaximizedWindows else { return }

        // A hidden or off-Space window can temporarily reject AX frame writes.
        // Activation/unhide is a bounded opportunity to finish a prior request.
        scheduleSettlingRefreshes(mode: .reconcileManagedWindows)
    }

    private func scheduleSettlingRefreshes(
        mode: SettlingMode,
        environmentalChangeAlreadyObserved: Bool = false
    ) {
        refreshTask?.cancel()
        guard WindowController.hasManagedMaximizedWindows else {
            refreshTask = nil
            return
        }

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            var shouldReconcile = mode == .reconcileManagedWindows
            var environmentalChangeObserved = environmentalChangeAlreadyObserved
            var stableSamples = 0

            for _ in 0..<Self.maximumSettlingSamples {
                guard !Task.isCancelled else { return }

                let currentLayout = ScreenLayout.current
                if currentLayout != lastScreenLayout {
                    lastScreenLayout = currentLayout
                    shouldReconcile = true
                    environmentalChangeObserved = true
                    stableSamples = 0
                    WindowController.adoptExistingMaximizedWindows()
                } else if shouldReconcile {
                    stableSamples += 1
                }

                if shouldReconcile {
                    let allWindowsSettled = WindowController.refreshManagedMaximizedWindow(
                        respectManualChanges: !environmentalChangeObserved
                    )

                    if allWindowsSettled,
                       stableSamples >= Self.requiredStableSamples {
                        return
                    }
                }

                try? await Task.sleep(nanoseconds: Self.settlingInterval)
            }
        }
    }

    private func reconnectToDock() {
        dockConnectionTask?.cancel()
        disconnectFromDock()

        dockConnectionTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for _ in 0..<10 {
                guard !Task.isCancelled else { return }
                if connectToDock() {
                    dockConnectionTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: Self.settlingInterval)
            }
            dockConnectionTask = nil
        }
    }

    private func ensureDockConnection() {
        guard dockObserver == nil, dockConnectionTask == nil else { return }
        reconnectToDock()
    }

    private func connectToDock() -> Bool {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.dockBundleIdentifier
              ).first else {
            return false
        }

        let dockApplication = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            dockApplication,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
              let dockList = (childrenValue as? [AXUIElement])?.first else {
            return false
        }

        var observer: AXObserver?
        guard AXObserverCreate(
            dock.processIdentifier,
            Self.dockObserverCallback,
            &observer
        ) == .success,
              let observer else {
            return false
        }

        dockObserver = observer
        let context = Unmanaged.passUnretained(self).toOpaque()

        for element in [dockApplication, dockList] {
            AXObserverAddNotification(
                observer,
                element,
                kAXCreatedNotification as CFString,
                context
            )
        }

        var dockItemsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            dockList,
            kAXChildrenAttribute as CFString,
            &dockItemsValue
        ) == .success,
           let dockItems = dockItemsValue as? [AXUIElement] {
            for dockItem in dockItems {
                observeDockItemDestruction(dockItem, context: context)
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        return true
    }

    private func disconnectFromDock() {
        guard let dockObserver else {
            observedDockItems.removeAll()
            return
        }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(dockObserver),
            .commonModes
        )
        self.dockObserver = nil
        observedDockItems.removeAll()
    }

    private func observeDockItemDestruction(
        _ dockItem: AXUIElement,
        context: UnsafeMutableRawPointer
    ) {
        guard let dockObserver,
              !observedDockItems.contains(where: { CFEqual($0, dockItem) }) else {
            return
        }

        let result = AXObserverAddNotification(
            dockObserver,
            dockItem,
            kAXUIElementDestroyedNotification as CFString,
            context
        )
        if result == .success || result == .notificationAlreadyRegistered {
            observedDockItems.append(dockItem)
        }
    }

    private func dockAccessibilityDidChange(
        element: AXUIElement,
        notification: CFString,
        context: UnsafeMutableRawPointer
    ) {
        if notification == kAXCreatedNotification as CFString {
            observeDockItemDestruction(element, context: context)
        } else if notification == kAXUIElementDestroyedNotification as CFString {
            observedDockItems.removeAll { CFEqual($0, element) }
        }

        // AX fires at the start of the Dock animation. The bounded settling task
        // waits until visibleFrame reports the new work area, then verifies it.
        WindowController.adoptExistingMaximizedWindows()
        scheduleSettlingRefreshes(mode: .waitForScreenLayoutChange)
    }

    private static let dockObserverCallback: AXObserverCallback = {
        _, element, notification, context in
        guard let context else { return }

        let monitor = Unmanaged<WorkspaceMonitor>
            .fromOpaque(context)
            .takeUnretainedValue()
        monitor.dockAccessibilityDidChange(
            element: element,
            notification: notification,
            context: context
        )
    }
}
