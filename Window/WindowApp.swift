import AppKit
import ApplicationServices
import Sparkle

@main
enum WindowApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let windows = WindowController()
    private var hotKeys: HotKeyManager?
    private var workspace: WorkspaceMonitor?
    private var updater: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary)
        }
        hotKeys = HotKeyManager(windows: windows)
        workspace = WorkspaceMonitor(windows: windows)
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        item.target = self
        let appMenu = NSMenu()
        appMenu.addItem(item)
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let menu = NSMenu()
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    @objc private func checkForUpdates() {
        guard updater?.updater.canCheckForUpdates == true else { return }
        updater?.checkForUpdates(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates) || updater?.updater.canCheckForUpdates == true
    }
}
