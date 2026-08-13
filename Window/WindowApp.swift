import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyManager: HotKeyManager?
    private var workspaceMonitor: WorkspaceMonitor?
    private var updateService: UpdateService?
    private var checkForUpdatesItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKeyManager = HotKeyManager()
        workspaceMonitor = WorkspaceMonitor()
        updateService = UpdateService()
        installUpdateMenu()
        AccessibilityPermission.requestIfNeeded()
    }

    private func installUpdateMenu() {
        let checkItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        checkItem.target = self
        checkForUpdatesItem = checkItem

        let appMenu = NSMenu()
        appMenu.addItem(checkItem)
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func checkForUpdates() {
        updateService?.checkForUpdates()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) {
            return updateService?.canCheckForUpdates == true
        }
        return true
    }
}

@main
enum WindowApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

private enum AccessibilityPermission {
    static func requestIfNeeded() {
        guard !AXIsProcessTrusted() else { return }

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
