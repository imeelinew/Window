import Foundation

enum KeyRepeat {
    // Deadlines use a monotonic clock, so AX work does not add to every frame's delay.
    static func frames(perform: @MainActor (TimeInterval) -> Bool) async {
        let interval = 1.0 / 60.0
        var previous = ProcessInfo.processInfo.systemUptime
        var deadline = previous + interval
        do {
            while !Task.isCancelled {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining > 0 {
                    try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                // Bound catch-up after a stalled AX call instead of making a large jump.
                let elapsed = min(now - previous, 0.1)
                previous = now
                guard perform(elapsed) else { return }
                deadline += interval
                let finished = ProcessInfo.processInfo.systemUptime
                if deadline <= finished {
                    // Skip missed frames; never send a burst of obsolete positions.
                    deadline += (floor((finished - deadline) / interval) + 1) * interval
                }
            }
        } catch {
            // Release or a direction change cancels the pending frame immediately.
        }
    }

    static func start(every interval: TimeInterval,
                      perform: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard !Task.isCancelled, perform() else { return }
                }
            } catch {
                // Releasing the shortcut cancels the next repeat.
            }
        }
    }
}
