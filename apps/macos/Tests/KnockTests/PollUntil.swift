import Foundation

/// Polls `condition` every `interval` until it holds or `timeout` of the test's own time has passed.
///
/// A full run starts about 1,600 tests at once and most of them are `@MainActor`, so a poll often wakes up
/// seconds late: it waited in the main actor's queue behind other tests. That wait is not the code under
/// test being slow, so any wake-up later than `lateAfter` credits its extra delay back to the deadline.
/// The `timeout` still bounds the work the test waits for. Returns false when the time is up.
func pollUntil(
    _ timeout: Duration, every interval: Duration = .milliseconds(10), lateAfter: Duration = .milliseconds(100),
    isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool
) async throws -> Bool {
    let clock = ContinuousClock()
    var deadline = clock.now + timeout
    while !condition() {
        let before = clock.now
        if before > deadline { return false }
        try await Task.sleep(for: interval)
        let slept = clock.now - before
        if slept > lateAfter { deadline += slept - interval }
    }
    return true
}
