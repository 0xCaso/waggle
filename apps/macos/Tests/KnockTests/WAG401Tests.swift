import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Knock

/// WAG-401: late comments on a decided shared case. The bar, its buttons and the prompt.
@MainActor
struct WAG401Tests {
    private let sample = Case(
        id: "c_401", taskId: "t_1", kind: .question, title: "Which plan?", need: "Pick one", why: "Why", recommendation: "a",
        recommendationWhy: "Because", options: [], status: .waitingOnAgent, hasArtifact: false,
        createdAt: "2026-10-18T10:00:00.000Z", updatedAt: "2026-10-18T10:00:00.000Z")

    @Test func theBarTextCountsTheComments() {
        #expect(LateCommentsCopy.barText(count: 1) == "1 comment since you decided")
        #expect(LateCommentsCopy.barText(count: 3) == "3 comments since you decided")
    }

    @Test func theButtonSaysSendForALiveSessionAndCopyOtherwise() {
        #expect(LateCommentsCopy.sendLabel(LateCommentsCopy.sendMode(sessionState: .live, sendFailed: false)) == "Send to the agent")
        #expect(LateCommentsCopy.sendLabel(LateCommentsCopy.sendMode(sessionState: .ended, sendFailed: false)) == "Copy prompt")
        #expect(LateCommentsCopy.sendLabel(LateCommentsCopy.sendMode(sessionState: .disconnected, sendFailed: false)) == "Copy prompt")
        #expect(LateCommentsCopy.sendLabel(LateCommentsCopy.sendMode(sessionState: .live, sendFailed: true)) == "Copy prompt")
        #expect(LateCommentsCopy.closedLine == "The agent's session is closed. Paste this in a new session.")
        #expect(LateCommentsCopy.sent == "Sent to the agent")
    }

    @Test func thePromptNamesTheCaseAndSaysCommentsAreInput() {
        let text = LateCommentsCopy.prompt(caseId: "c_401", title: "Which \"plan\"?")
        #expect(text.contains("c_401"))
        #expect(text.contains("Which 'plan'?"))
        #expect(text.contains("after the human decided"))
        #expect(text.contains("input and not an answer"))
        #expect(text.contains("waggle_check with case_id c_401"))
    }

    @Test func theStateReadsTheLateCount() throws {
        let json = #"{"enabled":true,"shared_count":1,"share":null,"comments":[],"error":null,"late_comments":{"count":2,"new":1}}"#
        let state = try JSONDecoder().decode(SharingState.self, from: Data(json.utf8))
        #expect(state.lateComments == LateComments(count: 2, new: 1))
        let old = try JSONDecoder().decode(SharingState.self, from: Data(#"{"enabled":true,"shared_count":0,"share":null,"comments":[],"error":null}"#.utf8))
        #expect(old.lateComments == .none)
    }

    @Test func markingGivenKeepsTheCountAndClearsNew() async {
        let model = SharingModel(
            caseId: "c_401",
            fetch: { SharingState(enabled: true, sharedCount: 1, share: nil, comments: [], error: nil, lateComments: LateComments(count: 2, new: 2)) },
            markLateGiven: { SharingState(enabled: true, sharedCount: 1, share: nil, comments: [], error: nil, lateComments: LateComments(count: 2, new: 0)) })
        await model.load()
        #expect(model.lateComments.new == 2)
        await model.markLateGiven()
        #expect(model.lateComments == LateComments(count: 2, new: 0))
    }

    /// Evidence only: `WAG401_EVIDENCE_DIR=<dir>` writes the bar as PNG files (one view, never the screen).
    @Test func theBarRenders() async throws {
        guard let dir = ProcessInfo.processInfo.environment["WAG401_EVIDENCE_DIR"] else { return }
        for (name, late) in [("one", LateComments(count: 1, new: 1)), ("many", LateComments(count: 3, new: 3)), ("sent", LateComments(count: 3, new: 0))] {
            let model = SharingModel(caseId: "c_401", fetch: { SharingState(enabled: true, sharedCount: 1, share: nil, comments: [], error: nil, lateComments: late) })
            await model.load()
            let bar = LateCommentsBarView(sharing: model, item: sample, onChangeAnswer: {}, sendPrompt: { _ in true })
                .frame(width: 400).padding(16).background(Color.white)
            let renderer = ImageRenderer(content: bar)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("bar-\(name).png"))
        }
    }
}
