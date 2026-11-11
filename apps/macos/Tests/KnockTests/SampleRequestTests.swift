import Foundation
import Testing
@testable import Knock

/// The built-in sample request: the fixture, the local Decide and the saved state. Every test runs on a temporary
/// `KNOCK_HOME` and an unreachable client: a call that left this process would fail the test.
@Suite("SampleRequest")
@MainActor
struct SampleRequestTests {
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("waggle-sample-\(UUID().uuidString)")
    }

    @Test func theFixtureIsTheSampleWithThreeOptions() {
        let item = SampleRequest.knockCase
        #expect(item.title == "Pricing card: compact or detailed?")
        #expect(SampleAsk.isSample(item))
        #expect(item.options.map { $0.title ?? "" } == ["Compact card", "Detailed card", "Compact with a compare table"])
        #expect(item.recommendation == SampleRequest.compactId)
        #expect(item.status == .needsYou)
        #expect(SampleRequest.detail.revisions.first?.kind == .markdown)
    }

    @Test func theArtifactIsWrittenUnderTheTemporaryHome() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try #require(SampleRequest.writeArtifact(environment: ["KNOCK_HOME": root.path]))
        #expect(result.kind == .markdown)
        #expect(result.entry.hasPrefix(root.path))
        let text = try String(contentsOfFile: result.entry, encoding: .utf8)
        #expect(text == SampleRequest.artifactText)
    }

    @Test func theClientAnswersTheSampleArtifactWithoutTheDaemon() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = makeUnreachableClient()
        await SampleRequest.prepare(client: client, environment: ["KNOCK_HOME": root.path])
        let result = try await client.artifactPath(caseId: SampleRequest.caseId, revision: 1)
        #expect(result.entry.hasPrefix(root.path))
    }

    @Test func decideOnTheSampleStaysInThisProcess() async throws {
        let client = makeUnreachableClient()
        var answered: [PendingReply] = []
        let coordinator = SendCoordinator.local(client: client, onAnswered: { answered.append($0) })
        let pending = PendingReply(
            caseId: SampleRequest.caseId, idempotencyKey: "k1", choice: SampleRequest.compactId, message: nil,
            comments: [], captures: [])
        // An unreachable client throws on any call: a local delivery must return a reply instead.
        let reply = try await coordinator.send(pending)
        #expect(reply.state == .queued)
        #expect(reply.choice == SampleRequest.compactId)
        #expect(answered.count == 1)
        let delivered = try await pollUntil(.seconds(2)) { answered.count == 1 }
        #expect(delivered)
    }

    @Test func theSampleNeverShowsAgainOnceAnswered() throws {
        let (model, root) = makeTempGettingStarted()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.sampleAvailable)
        model.openSample()
        #expect(model.sampleOpen)
        model.answerSample()
        #expect(!model.sampleOpen)
        #expect(model.sampleAnswered)
        model.openSample()
        #expect(!model.sampleOpen)
        let reloaded = GettingStartedModel(store: GettingStartedStore(
            environment: ["KNOCK_HOME": root.path], isOnboarded: { false }, now: { Date() }))
        #expect(reloaded.sampleAnswered)
        #expect(!reloaded.sampleAvailable)
        #expect(reloaded.lines[1].isDone)
    }

    @Test func theSampleNeverShowsAgainOnceDismissedAndDismissingIsNotAnswering() {
        let (model, root) = makeTempGettingStarted()
        defer { try? FileManager.default.removeItem(at: root) }
        model.openSample()
        model.dismissSample()
        #expect(model.sampleDismissed)
        #expect(!model.sampleAvailable)
        #expect(!model.lines[1].isDone)
        model.openSample()
        #expect(!model.sampleOpen)
    }

    @Test func aPersonFromTheOldSetupNeverSeesTheSample() {
        let (model, root) = makeTempGettingStarted(isOnboarded: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!model.sampleAvailable)
        #expect(!model.isCardVisible)
    }

    @Test func aRealRequestTicksTheThirdLineButTheSampleAskDoesNot() {
        let (model, root) = makeTempGettingStarted()
        defer { try? FileManager.default.removeItem(at: root) }
        let after = "2027-02-01T12:00:00.000Z"
        model.apply(cases: [FirstRun.ask("c1", title: SampleAsk.title, at: after)])
        #expect(!model.lines[2].isDone)
        model.apply(cases: [FirstRun.ask("c2", title: "A real one", at: after)])
        #expect(model.lines[2].isDone)
    }

    @Test func theCardCountsThreeLines() {
        let (model, root) = makeTempGettingStarted()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.lines.count == 3)
        #expect(model.isCardVisible)
        model.markConnected(agent: "Claude Code")
        model.answerSample()
        #expect(model.isCardVisible)
        model.apply(cases: [FirstRun.ask("c2", title: "A real one", at: "2027-02-01T12:00:00.000Z")])
        #expect(!model.isCardVisible)
    }
}
