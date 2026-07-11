import AppKit

final class WorkspaceMonitor: NSObject {
    private var refreshTask: Task<Void, Never>?

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
    }

    deinit {
        refreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        WindowController.refreshManagedMaximizedWindow(respectManualChanges: false)
        scheduleSettlingRefreshes()
    }

    @objc private func workspaceApplicationsDidChange(_ notification: Notification) {
        scheduleSettlingRefreshes()
    }

    private func scheduleSettlingRefreshes() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            // Dock resizing is animated. Sample briefly after the event, then return to idle.
            for _ in 0..<12 {
                guard !Task.isCancelled else { return }
                WindowController.refreshManagedMaximizedWindow()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
