import Foundation

/// The built-in sample ask (WAG-338): "Try a sample instead" runs `waggle test-ask`, which makes one real
/// ask in the three blocks shape (the need, the why, one item with a recommendation, and an artifact).
enum SampleAsk {
    /// The title `waggle test-ask` gives the sample (daemon/src/cli/test-ask.ts).
    static let title = "Pricing card: compact or detailed?"

    static func isSample(_ item: Case) -> Bool { item.title == title }
}

extension OnboardingModel {
    /// "Try a sample instead". Runs `waggle test-ask` in the background. The sample is a real ask, so it
    /// reaches the queue and the tour the same way an agent's ask does. A failure leaves a plain line.
    func runSample() {
        guard gettingStarted.sample != .running else { return }
        gettingStarted.sampleStarted()
        let runner = self.runner
        Task {
            var sawCase = false
            let code = await runner.run(["test-ask"], onLine: { [weak self] line in
                guard let self, !sawCase, Self.extractCaseId(line) != nil else { return }
                sawCase = true
                self.gettingStarted.sampleFinished()
            })
            if !sawCase {
                gettingStarted.sampleFailed("Waggle could not make the sample (code \(code)). Try again in a moment.")
            }
        }
    }

    /// Parses `Created test review "Checkout prototype" (case c_01J...).` (daemon/src/cli/test-ask.ts) for the
    /// case id inside the parens.
    nonisolated static func extractCaseId(_ line: String) -> String? {
        guard let openRange = line.range(of: "(case "),
              let closeRange = line.range(of: ").", range: openRange.upperBound..<line.endIndex)
        else { return nil }
        let id = line[openRange.upperBound..<closeRange.lowerBound]
        return id.isEmpty ? nil : String(id)
    }
}
