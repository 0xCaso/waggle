import Foundation

/// Races `operation` against `seconds`; returns `nil` if it did not finish in
/// time (HAIL-55: an `html_bundle` preview must never spin forever). `WKWebView`'s
/// `evaluateJavaScript`/`takeSnapshot` are callback-based, not cancellable -
/// `operation` keeps running in the background past the bound and its result,
/// if it ever arrives, is discarded; callers that want the abandoned work to
/// stop early (rather than just be ignored) need to check `Task.isCancelled`
/// inside `operation` itself and react to it (see `ArtifactPreviewLoader`).
///
/// Deliberately NOT `withTaskGroup`: a task group will not let its own
/// enclosing call return until every child task has finished, even a losing
/// one that was cancelled - `cancelAll()` is cooperative, and neither
/// `evaluateJavaScript` nor `takeSnapshot` ever checks `Task.isCancelled`, so
/// that wait would silently reintroduce the exact hang this function exists
/// to bound (caught live: a task-group version of this helper raced a 0.5s
/// bound against a real stuck `WKWebView` call and still took the operation's
/// full 60s to return). Two unstructured `Task`s racing to resume one
/// continuation have no such "wait for the loser" step.
@MainActor
func withTimeout<T: Sendable>(
    seconds: Double, operation: @escaping @MainActor @Sendable () async -> T
) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let box = TimeoutResumeBox(continuation)
        let operationTask = Task { @MainActor in
            let value = await operation()
            box.resume(with: value)
        }
        // Cancelling here does not stop an in-flight `evaluateJavaScript`/
        // `takeSnapshot` call (they never check `Task.isCancelled`), but it
        // does let a still-cooperative part of `operation` - a poll loop
        // between such calls, say - notice and bail out early instead of
        // finishing a render nobody will ever look at.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            operationTask.cancel()
            box.resume(with: nil)
        }
    }
}

/// Guarantees the continuation `withTimeout` hands to its two racing `Task`s
/// resumes exactly once, whichever finishes first. `@MainActor`-isolated
/// like every caller in this codebase, so the guard flag needs no lock.
@MainActor
private final class TimeoutResumeBox<T: Sendable> {
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
