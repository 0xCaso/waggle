import Testing
import Foundation
@testable import Knock

/// HAIL-95: when the update card shows above NEED FROM YOU, and what it holds.
struct UpdateCardTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func asked() -> ThreadStep { .asked(.init(need: "n", meta: nil, at: t0)) }
    private func replied() -> ThreadStep {
        .replied(.init(summary: "ok", meta: nil, at: t0 + 10, pickedUp: nil))
    }
    private func updated(_ text: String) -> ThreadStep {
        .updated(.init(message: text, revision: nil, at: t0 + 20))
    }
    private func thread(_ steps: [ThreadStep]) -> ThreadModel { ThreadModel(steps: steps, runtimeName: "Claude Code") }

    @Test func showsTheUpdateThatCameAfterYourLastReply() {
        let card = UpdateCardContent.content(
            thread: thread([asked(), replied(), updated("All done.")]), hasArtifact: false, isColumnVisible: false)
        #expect(card?.prose == "All done.")
        #expect(card?.stepIndex == 2)
    }

    @Test func goesAwayOnceYouReplyAgain() {
        let steps = [asked(), replied(), updated("All done."), replied()]
        #expect(UpdateCardContent.content(thread: thread(steps), hasArtifact: false, isColumnVisible: false) == nil)
    }

    @Test func noUpdateNoCard() {
        #expect(UpdateCardContent.content(thread: thread([asked(), replied()]), hasArtifact: false, isColumnVisible: false) == nil)
        #expect(UpdateCardContent.content(thread: nil, hasArtifact: false, isColumnVisible: false) == nil)
    }

    @Test func hiddenWhileTheColumnIsOpenAndWide() {
        let steps = [asked(), replied(), updated("All done.")]
        #expect(UpdateCardContent.content(thread: thread(steps), hasArtifact: false, isColumnVisible: true) == nil)
    }

    @Test func leavesAnAskWithAnArtifactToTheOnePage() {
        let steps = [asked(), replied(), updated("All done.")]
        #expect(UpdateCardContent.content(thread: thread(steps), hasArtifact: true, isColumnVisible: false) == nil)
    }

    @Test func aMessageThatIsACommandBecomesOnlyABlock() {
        let cmd = "read -rs \"K?Key: \" && printf 'X=%s\\n' \"$K\" >> .env"
        let parts = UpdateCardContent.split(cmd)
        #expect(parts.prose.isEmpty)
        #expect(parts.commands == [cmd])
    }

    @Test func fencedBlocksAndInlineCommandsAreCopyable() {
        let parts = UpdateCardContent.split("Run this:\n```\nbun test\n```\nThen `git status` and check `foo.swift`.")
        #expect(parts.prose.hasPrefix("Run this:"))
        #expect(parts.commands == ["bun test", "git status"])
    }

    @Test func plainProseHasNoCommand() {
        let parts = UpdateCardContent.split("I changed the `title` field and it works now.")
        #expect(parts.commands.isEmpty)
        #expect(parts.prose == "I changed the `title` field and it works now.")
    }

    @Test func label() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(UpdateCardContent.label(runtime: "Claude Code", at: Date(timeIntervalSince1970: 3600 * 21 + 60 * 24), timeZone: utc)
            == "UPDATE FROM CLAUDE CODE · 21:24")
    }
}
