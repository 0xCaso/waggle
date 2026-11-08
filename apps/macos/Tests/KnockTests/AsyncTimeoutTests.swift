import Testing
import Foundation
@testable import Knock

/// `withTimeout` (HAIL-55): the shared race between an operation and a bound,
/// used by both the still card's off-screen render and Comment mode's
/// capture - neither `evaluateJavaScript` nor `takeSnapshot` has a timeout of
/// its own, so this is what stops an `html_bundle` preview from spinning
/// forever. Short bounds throughout (well under a second) so the suite stays
/// fast; the behaviour being tested does not depend on the bound's size.
@MainActor
struct AsyncTimeoutTests {
    @Test func returnsTheOperationsValueWhenItFinishesInTime() async {
        let result = await withTimeout(seconds: 30) { "done" }
        #expect(result == "done")
    }

    @Test func returnsNilWhenTheOperationOutlivesTheBound() async {
        let result = await withTimeout(seconds: 0.05) { () -> String in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            return "too late"
        }
        #expect(result == nil)
    }

    @Test func aFastOperationsResultArrivesWellBeforeTheBound() async throws {
        // The bound is an hour. A `withTimeout` that waited for it would never return, so the
        // guard below is what fails the test. Neither number depends on machine load.
        var result: Int??
        let call = Task { @MainActor in result = await withTimeout(seconds: 3600) { 42 } }
        let deadline = ContinuousClock.now + .seconds(30)
        while result == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        call.cancel()
        #expect(result == .some(42), "must not wait for the bound when the operation already finished")
    }
}
