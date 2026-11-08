import Testing
@testable import Knock

/// Settings Agents page's "Use it on your real work" texts (tester feedback 29 Sep).
struct OnboardingRealWorkCopyTests {
    @Test func bothTextsNameWaggleAskAndAvoidTheTerminal() {
        for text in [OnboardingCopy.sessionPrompt, OnboardingCopy.projectLine] {
            #expect(text.contains("waggle_ask"))
            #expect(text.contains("terminal"))
            #expect(!text.contains("\u{2014}"))  // UI copy: no em-dashes (AGENTS.md)
        }
    }
}
