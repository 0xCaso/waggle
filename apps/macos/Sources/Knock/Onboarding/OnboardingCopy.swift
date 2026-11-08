import Foundation

/// Words the Settings Agents page copies for a person. They were the last screen of the old setup; the
/// Settings page still shows them (WAG-338). Agent-facing text, so "ask" and "waggle_ask" stay.
enum OnboardingCopy {
    static let sessionPrompt = "From now on, when you need a decision from me (a product, design or UX choice, a review before something ships, or info only I have), ask me in Waggle with waggle_ask instead of asking here in the terminal. Keep working on anything that doesn't depend on my answer."
    static let projectLine = "Ask me for decisions and reviews in Waggle (waggle_ask), not in the terminal."
}
