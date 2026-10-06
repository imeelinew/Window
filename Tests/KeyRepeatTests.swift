import Foundation

@main
struct KeyRepeatTests {
    @MainActor static func main() async throws {
        try await testImmediateCadenceAndCancellation()
        try await testTap()
        try await testReleaseWhileRepeating()
        try await testSwitchDirection()
        await testFrameCadence()
        try await testFrameCancellation()
        await testSlowFrameSkipsBacklog()
        print("Key repeat: all checks passed")
    }

    @MainActor static func testFrameCadence() async {
        var frames = 0
        var elapsedTime = 0.0
        let start = ProcessInfo.processInfo.systemUptime
        await KeyRepeat.frames { elapsed in
            precondition(elapsed > 0 && elapsed <= 0.1)
            elapsedTime += elapsed
            frames += 1
            return elapsedTime < 0.5
        }
        let duration = ProcessInfo.processInfo.systemUptime - start
        precondition(frames >= 15, "Continuous movement must not use the old 10 Hz cadence")
        precondition(abs(duration - elapsedTime) < 0.02, "Movement distance must use real elapsed time")
        print(String(format: "Movement scheduler: %.1f updates/sec", Double(frames) / duration))
    }

    @MainActor static func testFrameCancellation() async throws {
        var count = 0
        let task = Task { @MainActor in
            await KeyRepeat.frames { _ in count += 1; return true }
        }
        try await Task.sleep(nanoseconds: 75_000_000)
        precondition(count > 0)
        task.cancel()
        await task.value
        let stoppedCount = count
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(count == stoppedCount, "Release must stop movement with no final snap")
    }

    @MainActor static func testSlowFrameSkipsBacklog() async {
        var times: [TimeInterval] = []
        await KeyRepeat.frames { _ in
            times.append(ProcessInfo.processInfo.systemUptime)
            if times.count == 1 { Thread.sleep(forTimeInterval: 0.04) }
            return times.count < 4
        }
        for index in 1..<times.count {
            precondition(times[index] - times[index - 1] > 0.005,
                         "Slow AX work must skip stale frames instead of bursting queued writes")
        }
    }

    @MainActor static func testImmediateCadenceAndCancellation() async throws {
        var count = 0
        let task = KeyRepeat.start(every: 0.1) {
            count += 1
            return true
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(count == 0, "The press already adjusts once; do not immediately double it")
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(count >= 2, "Holding must repeat at the regular cadence without a separate initial delay")
        task.cancel()
        await task.value
        let stoppedCount = count
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(count == stoppedCount, "Cancelled repeats must not perform another action")
    }

    @MainActor static func testTap() async throws {
        var count = 0
        let task = KeyRepeat.start(every: 0.1) {
            count += 1
            return true
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        await task.value
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(count == 0, "A quick tap must stop before the first repeat")
    }

    @MainActor static func testReleaseWhileRepeating() async throws {
        var held = true
        var count = 0
        let task = KeyRepeat.start(every: 0.02) {
            guard held else { return false }
            count += 1
            return true
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(count >= 2)
        held = false
        let stoppedCount = count
        await task.value
        try await Task.sleep(nanoseconds: 60_000_000)
        precondition(count == stoppedCount, "A lost release event must still stop when the key is up")
    }

    @MainActor static func testSwitchDirection() async throws {
        var width = 800
        let increase = KeyRepeat.start(every: 0.02) {
            width += 50
            return true
        }
        try await Task.sleep(nanoseconds: 70_000_000)
        increase.cancel()
        let switchingWidth = width
        var decreases = 0
        let decrease = KeyRepeat.start(every: 0.02) {
            guard decreases < 3 else { return false }
            width -= 50
            decreases += 1
            return true
        }
        await increase.value
        await decrease.value
        precondition(width == switchingWidth - 150, "The old direction must not resume after a switch")
    }
}
