import Foundation

enum KeyRepeat {
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
