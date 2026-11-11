import Foundation
import Testing
@testable import Knock

/// WAG-338: no "Knock" in any text a person reads in onboarding or Settings. The product is Waggle (HAIL-171).
/// Hidden ids keep the old name on purpose (AGENTS.md: env vars, the data folder, bundle ids, legacy
/// aliases), so a literal may still carry those. Anything else with the old name fails here.
@MainActor
struct NoKnockCopyTests {
    /// Folders and files whose string literals can reach a person's screen in onboarding or Settings.
    private static let scanned: [String] = ["Onboarding", "Settings"]
    private static let scannedFiles: [String] = ["Queue/FirstRunViews.swift", "Queue/FirstRunRules.swift", "Queue/SampleRequest.swift", "Home/CaughtUpView.swift", "Support/AppTagline.swift"]

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Knock")
    }

    /// The old name inside a hidden id: an env var, a project file, a bundle name, a camelCase identifier.
    private static let hiddenIds = try! NSRegularExpression(pattern: [
        #"KNOCK_[A-Z0-9_]+"#,
        #"\.knock(?:-[A-Za-z]+|/[A-Za-z.\-]+)"#,
        #"knock-[a-z\-]+"#,
        #"Knock\.app"#,
        #"/Resources/knock"#,
        #"^knock$"#,
        #"\bknock[A-Z][A-Za-z]*"#,
    ].joined(separator: "|"))

    private static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)

    /// Drops every `\( ... )` from a line, however deep the parentheses nest. Code in an interpolation
    /// (`inKnock ? "Waggle" : "Terminal"`) is not text a person reads.
    static func removingInterpolations(_ line: String) -> String {
        var out = ""
        var depth = 0
        var iterator = line.makeIterator()
        var previous: Character?
        while let ch = iterator.next() {
            if depth > 0 {
                if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
                previous = ch
                continue
            }
            if ch == "(" && previous == "\\" {
                out.removeLast()
                depth = 1
                previous = ch
                continue
            }
            out.append(ch)
            previous = ch
        }
        return out
    }

    /// The literals in a Swift file that name Knock and are not a hidden id. Comment lines are skipped.
    static func offenders(in source: String) -> [String] {
        var found: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            let text = removingInterpolations(String(line))
            for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                var value = String(text[range])
                value = hiddenIds.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
                if value.range(of: "knock", options: .caseInsensitive) != nil { found.append(String(text[range])) }
            }
        }
        return found
    }

    private func swiftFiles() -> [URL] {
        var urls: [URL] = []
        for folder in Self.scanned {
            let dir = Self.sourcesRoot.appendingPathComponent(folder)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            urls += names.filter { $0.hasSuffix(".swift") }.map { dir.appendingPathComponent($0) }
        }
        urls += Self.scannedFiles.map { Self.sourcesRoot.appendingPathComponent($0) }
        return urls
    }

    @Test func noOnboardingOrSettingsStringNamesKnock() throws {
        let files = swiftFiles()
        #expect(files.count > 20, "the scan found the source folders")
        var problems: [String] = []
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            for text in Self.offenders(in: source) { problems.append("\(url.lastPathComponent): \"\(text)\"") }
        }
        #expect(problems.isEmpty, "Knock in a user-visible string: \(problems.joined(separator: "; "))")
    }

    @Test func theScanCatchesTheOldNameAndLetsHiddenIdsThrough() {
        #expect(Self.offenders(in: #"Text("WHAT COMES TO KNOCK")"#) == ["WHAT COMES TO KNOCK"])
        #expect(Self.offenders(in: #"Text("Set up Knock")"#) == ["Set up Knock"])
        #expect(Self.offenders(in: #"label("Your knock is ready")"#) == ["Your knock is ready"])
        #expect(Self.offenders(in: #"let key = "KNOCK_HOME""#).isEmpty)
        #expect(Self.offenders(in: #"let path = ".knock/design-kit.md""#).isEmpty)
        #expect(Self.offenders(in: #"let names = ["Waggle.app", "Knock.app"]"#).isEmpty)
        #expect(Self.offenders(in: #"Text("Seen in \(KnockDateFormat.relativeShort(from: at)) now")"#).isEmpty)
        #expect(Self.offenders(in: #"// "Knock" in a comment"#).isEmpty)
    }

    @Test func theWordsOfTheNewFlowNameWaggleNeverKnock() {
        let (model, root) = makeTempGettingStarted()
        defer { try? FileManager.default.removeItem(at: root) }
        var words: [String] = []
        words += model.items.flatMap { [$0.title, $0.hint, $0.actionLabel ?? ""] }
        words += [GettingStartedModel.notificationsTipTitle, GettingStartedModel.notificationsTipBody]
        words += CoachMarkTourModel.Mark.allCases.flatMap { [$0.title, $0.body, $0.buttonLabel] }
        words += OnboardingStep.allCases.flatMap { [$0.label, $0.pillTitle] }
        words += [FirstJobPrompt.build(.findDecision, projectName: "Acme"), AgentOnIt.defaultSummary]
        words += model.lines.flatMap { [$0.title, $0.hint] } + [FirstRunRules.sampleTitle, FirstRunRules.sampleMeta, FirstRunRules.sampleToolbarLine]
        words += [FirstRunRules.caughtUpTitle, FirstRunRules.caughtUpSubtitle, FirstRunRules.caughtUpQuietLine]
        words += AgentInstructions.knockWhen + AgentInstructions.knockWont + AgentInstructions.everyAskCarries
        words += [AgentInstructions.text, OnboardingCopy.sessionPrompt, OnboardingCopy.projectLine]
        words += SettingsPage.allCases.flatMap { [$0.title, $0.subtitle] }
        words += AskWords.allCases.map(\.title) + AskLearn.allCases.flatMap { [$0.title, $0.note] } + AskDetail.allCases.map(\.note) + AskReach.allCases.flatMap { [$0.title, $0.menuTitle, $0.summary, $0.kindNote] }
        for word in words { #expect(!word.localizedCaseInsensitiveContains("knock"), "Knock in: \(word)") }
    }

    @Test func theSettingsPageForRequestsIsCalledRequests() {
        #expect(SettingsPage.asks.title == "Requests")
    }

    @Test func noEmDashesInTheNewCopy() {
        let (model, root) = makeTempGettingStarted()
        defer { try? FileManager.default.removeItem(at: root) }
        var words = model.items.flatMap { [$0.title, $0.hint] }
        words += CoachMarkTourModel.Mark.allCases.flatMap { [$0.title, $0.body] }
        words += model.lines.flatMap { [$0.title, $0.hint] } + [FirstRunRules.sampleTitle, FirstRunRules.sampleMeta, FirstRunRules.sampleToolbarLine]
        words += [FirstRunRules.caughtUpTitle, FirstRunRules.caughtUpSubtitle, FirstRunRules.caughtUpQuietLine]
        words += SampleRequest.options.map(\.label) + [SampleRequest.knockCase.need, SampleRequest.knockCase.why, SampleRequest.artifactText]
        words += AgentInstructions.everyAskCarries
        words += [FirstJobPrompt.build(.findDecision, projectName: "Acme"), GettingStartedModel.notificationsTipBody]
        for word in words { #expect(!word.contains("\u{2014}"), "em dash in: \(word)") }
    }
}
