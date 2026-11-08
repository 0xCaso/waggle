import Foundation
import Testing
@testable import Knock

/// WAG-341: the onboarding views draw with Theme tokens only. No hex colour, no `Color(red:)`, no system
/// font size, no literal `Color.white` or `Color.black` in a view file of the onboarding.
struct OnboardingDesignSystemTests {
    private static let files: [String] = [
        "Onboarding/OnboardingFirstJobView.swift", "Onboarding/OnboardingConnectView.swift",
        "Onboarding/OnboardingWindowView.swift", "Onboarding/CoachMarkOverlayView.swift",
        "Queue/FirstRunViews.swift",
    ]

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Knock")
    }

    @Test func onboardingViewsHaveNoLiteralColoursOrFontSizes() throws {
        let banned = try NSRegularExpression(pattern: #"0x[0-9A-Fa-f]{6}|Color\(hex:|Color\(red:|\.system\(size:|Color\.(white|black|red)\b|\.foregroundColor\(\.(white|black)\)"#)
        var hits: [String] = []
        for file in Self.files {
            let text = try String(contentsOf: Self.sourcesRoot.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if banned.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    hits.append("\(file):\(index + 1): \(trimmed)")
                }
            }
        }
        #expect(hits.isEmpty, "Use Theme tokens: \(hits.joined(separator: "\n"))")
    }

    @Test func projectSubLineUsesTheUIFontNotMono() throws {
        let text = try String(contentsOf: Self.sourcesRoot.appendingPathComponent("Onboarding/OnboardingFirstJobView.swift"), encoding: .utf8)
        #expect(!text.contains("monoMeta"))
    }
}
