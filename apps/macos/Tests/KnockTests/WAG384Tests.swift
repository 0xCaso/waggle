import Testing
import Foundation
@testable import Knock

/// WAG-384: ask how the code behind a decision works, from the "Ask for" row or from a text selection.
@MainActor
struct WAG384Tests {
    @Test func theRowStartsWithHowItWorksAndKeepsTheOldOrder() {
        #expect(DetailPill.all.map(\.label) == [
            "how it works", "the trade-offs", "a prototype", "screenshots", "the numbers", "an example", "a diagram",
        ])
        guard case .quick(let index) = DetailPill.all[0].pick else { Issue.record("not a quick ask"); return }
        #expect(ComposerViewModel.detailChips[index] == "Explain how the code behind this decision works.")
        #expect(ComposerViewModel.detailChipUsageNames[index] == "how_it_works")
        #expect(ComposerViewModel.detailChips.count == ComposerViewModel.detailChipUsageNames.count)
    }

    @Test func aSelectionRequestQuotesTheText() {
        #expect(ExplainRequest.text(forSelection: "the daemon writes it") == #"Explain how this works: "the daemon writes it""#)
        #expect(ExplainRequest.text(forSelection: "  padded \n") == #"Explain how this works: "padded""#)
    }

    @Test func aLongQuoteIsCutAt300CharactersWithAnEllipsis() {
        let exact = String(repeating: "a", count: 300)
        #expect(ExplainRequest.text(forSelection: exact) == "Explain how this works: \"\(exact)\"")
        let long = String(repeating: "b", count: 301)
        #expect(ExplainRequest.text(forSelection: long) == "Explain how this works: \"\(String(repeating: "b", count: 300))…\"")
    }

    @Test func settingsDecodeWithAndWithoutAskLearn() throws {
        let with = try JSONDecoder().decode(SettingsValue.self, from: Data(#"{"key":"askLearn","value":"diagram"}"#.utf8))
        #expect(with.value == .diagram)
        #expect((try? JSONDecoder().decode(SettingsValue.self, from: Data(#"{"key":"askLearn","value":null}"#.utf8))) == nil)
    }

    private struct SettingsValue: Decodable {
        let value: AskLearn
    }
}

/// WAG-385: the "After you decide" setting.
struct WAG385Tests {
    private struct Value: Decodable { let value: AskAfterDecide }

    @Test func titlesAndRawValuesMatchTheDaemon() {
        #expect(AskAfterDecide.allCases.map(\.title) == ["Nothing", "A record", "A record and tasks"])
        #expect(AskAfterDecide.allCases.map(\.rawValue) == ["none", "record", "record_tasks"])
    }

    @Test func settingsDecodeTheDaemonValues() throws {
        for raw in ["none", "record", "record_tasks"] {
            let v = try JSONDecoder().decode(Value.self, from: Data(#"{"key":"askAfterDecide","value":"\#(raw)"}"#.utf8))
            #expect(v.value.rawValue == raw)
        }
        #expect((try? JSONDecoder().decode(Value.self, from: Data(#"{"value":"all"}"#.utf8))) == nil)
    }
}
