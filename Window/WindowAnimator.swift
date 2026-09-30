import AppKit
import ApplicationServices

// Only active animations hold leases. Concurrent windows of one app share a lease.
final class WindowAnimator {
    private struct Lease {
        let application: AXUIElement
        var users: Int
    }

    private var leases: [pid_t: Lease] = [:]
    private static let enhancedUI = "AXEnhancedUserInterface" as CFString

    static func isElectron(_ application: NSRunningApplication) -> Bool {
        guard let url = application.bundleURL, let bundle = Bundle(url: url) else { return false }
        return bundle.object(forInfoDictionaryKey: "ElectronAsarIntegrity") != nil
            || FileManager.default.fileExists(atPath: url.appendingPathComponent(
                "Contents/Frameworks/Electron Framework.framework"
            ).path)
    }

    func resizeCentered(_ window: AccessibleWindow, application: AXUIElement, pid: pid_t,
                        from start: CGRect, to target: CGRect) async {
        guard !Task.isCancelled, window.canResize else { return }
        let leased = acquire(application, pid: pid)
        defer { if leased { release(pid) } }

        guard window.setSize(target.size) == .success else { return }
        var actual = window.frame
        if actual?.size == start.size {
            guard await pause(40_000_000) else { return }
            actual = window.frame
        }
        // A writable AXSize can still be constrained by the app. Do not move a
        // window that rejected the resize, or compensate beyond its size limits.
        guard !Task.isCancelled, let actual,
              actual.size != start.size,
              window.canResize else { return }
        window.setPosition(CGPoint(x: target.midX - actual.width / 2,
                                   y: target.midY - actual.height / 2))
    }

    func move(_ window: AccessibleWindow, application: AXUIElement, pid: pid_t,
              from start: CGRect, to target: CGRect, electron: Bool, maximized: Bool) async {
        guard !Task.isCancelled else { return }
        let leased = acquire(application, pid: pid)
        defer { if leased { release(pid) } }

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && start != target {
            var animationStart = start
            if electron {
                // Chromium relayouts on every size write; animate only its position.
                window.setSize(target.size)
                guard await pause(40_000_000) else { return }
                animationStart = window.frame ?? start
            }

            let startTime = ProcessInfo.processInfo.systemUptime
            var nextFrameTime = startTime
            var lastPosition: CGPoint?
            while !Task.isCancelled {
                let progress = min((ProcessInfo.processInfo.systemUptime - startTime) / 0.20, 1)
                if progress >= 1 { break }
                let frame = animationStart.interpolated(to: target, progress: 1 - pow(1 - progress, 3))
                if electron {
                    let position = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded())
                    if position != lastPosition {
                        window.setPosition(position)
                        lastPosition = position
                    }
                } else {
                    window.setFrame(frame)
                }
                nextFrameTime += 1.0 / 60.0
                let now = ProcessInfo.processInfo.systemUptime
                // Sample real time after slow AX calls; never replay stale frames.
                if nextFrameTime <= now { nextFrameTime = now + 1.0 / 60.0 }
                guard await pause(UInt64((nextFrameTime - now) * 1_000_000_000)) else { return }
            }
        }
        await commit(window, target: target, maximized: maximized)
    }

    private func commit(_ window: AccessibleWindow, target: CGRect, maximized: Bool) async {
        var request = target
        for _ in 0..<5 {
            guard !Task.isCancelled else { return }
            window.setSize(request.size)
            guard await pause(16_000_000) else { return }
            window.setPosition(request.origin)
            guard await pause(16_000_000) else { return }
            window.setSize(request.size)
            guard await pause(40_000_000) else { return }
            guard let actual = window.frame else { return }
            if maximized ? actual.aligns(with: target) : actual.matches(target, tolerance: 0.5) {
                return
            }
            // Compensate for apps that consistently apply a smaller AX frame.
            request = request.correctingResidual(actual: actual, target: target)
        }
    }

    private func pause(_ nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func acquire(_ application: AXUIElement, pid: pid_t) -> Bool {
        if var lease = leases[pid] {
            lease.users += 1
            leases[pid] = lease
            return true
        }
        guard application.attribute("AXEnhancedUserInterface") as? Bool == true,
              AXUIElementSetAttributeValue(application, Self.enhancedUI, kCFBooleanFalse) == .success else {
            return false
        }
        leases[pid] = Lease(application: application, users: 1)
        return true
    }

    private func release(_ pid: pid_t) {
        guard var lease = leases[pid] else { return }
        lease.users -= 1
        if lease.users == 0 {
            AXUIElementSetAttributeValue(lease.application, Self.enhancedUI, kCFBooleanTrue)
            leases.removeValue(forKey: pid)
        } else {
            leases[pid] = lease
        }
    }
}
