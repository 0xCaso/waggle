import AppKit
import Foundation
import Testing
@testable import Knock

/// HAIL-156: each round of a plan ask can carry its own artifact of any kind. The stage shows the
/// current round's artifact, the answered history opens an earlier round's artifact read-only, and the
/// "Still showing vN" line only appears when the round's content clearly changed.
private final class Artifacts: @unchecked Sendable {
    var byRevision: [Int: String] = [:]
}

private func writeShot() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let path = dir.appendingPathComponent("shot.png").path
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    return path
}

private func writeMarkdown(_ text: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("doc.md").path
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

private func round(
    _ seq: Int, _ stage: PlanStageName, revision: Int?, own: Bool, kind: ArtifactKind?, answered: Bool = true
) -> PlanRound {
    PlanRound(
        seq: seq, stage: PlanStage(name: stage), question: "Q\(seq)",
        options: [Option(id: "a", label: "One", title: "One")], recommendation: "a",
        createdAt: "2026-10-03T09:0\(seq):00Z", revision: revision, ownArtifact: own, artifactKind: kind,
        answer: answered ? PlanAnswer(choice: "a", createdAt: "2026-10-03T09:0\(seq):30Z") : nil)
}

private func planDetail(rounds: [PlanRound], revisions: Int) throws -> CaseDetail {
    let list = (1...revisions).map { n in
        #"{"id":"r_\#(n)","case_id":"c_1","n":\#(n),"created_at":"2026-10-03T09:00:00Z"}"#
    }.joined(separator: ",")
    let json = #"""
    {"case":{"id":"c_1","task_id":"t_1","kind":"question","title":"Plan","need":"Q","why":"W",
      "recommendation":"a","recommendation_why":"R","options":[{"id":"a","label":"One"}],
      "status":"needs_you","has_artifact":true,"runtime":"claude","created_at":"2026-10-03T09:00:00Z",
      "updated_at":"2026-10-03T09:10:00Z","plan":{"stage":{"name":"spec"},"rounds":\#(rounds.count),"answered":0}},
     "task":{"id":"t_1","name":"Plan","project":"app"},
     "messages":[],"revisions":[\#(list)],"comments":[],"replies":[]}
    """#
    var value = try JSONDecoder().decode(CaseDetail.self, from: Data(json.utf8))
    value.planRounds = rounds
    return value
}

@MainActor
struct PlanArtifactTests {
    // MARK: the stale rule

    @Test func aRoundWithItsOwnArtifactNeverSaysStill() {
        let rounds = [round(0, .questions, revision: 1, own: true, kind: .screenshot)]
        #expect(PlanArtifacts.staleNote(rounds: rounds) == nil)
    }

    @Test func moreRoundsOfTheSameStageStayQuiet() {
        let rounds = [
            round(0, .design, revision: 1, own: true, kind: .diagram),
            round(1, .design, revision: 1, own: false, kind: .diagram),
        ]
        #expect(PlanArtifacts.staleNote(rounds: rounds) == nil)
    }

    @Test func aNewStageWithoutAnArtifactSaysItIsStillShowingTheOldOne() {
        let rounds = [
            round(0, .questions, revision: 1, own: true, kind: .screenshots),
            round(1, .approaches, revision: 1, own: false, kind: .screenshots),
        ]
        let note = PlanArtifacts.staleNote(rounds: rounds)
        #expect(note?.shownRevision == 1)
        #expect(note?.text.hasPrefix("Still showing v1") == true)
    }

    @Test func aPlanWithNoArtifactHasNoNote() {
        #expect(PlanArtifacts.staleNote(rounds: [round(0, .questions, revision: nil, own: false, kind: nil)]) == nil)
    }

    @Test func theDetailUsesThePlanRuleForAPlanAndTheCaseRuleOtherwise() throws {
        let rounds = [
            round(0, .questions, revision: 1, own: true, kind: .screenshot),
            round(1, .questions, revision: 1, own: false, kind: .screenshot),
        ]
        // The plain rule would fire here (the case updated after its revision); the plan rule does not.
        #expect(try planDetail(rounds: rounds, revisions: 1).staleArtifactNote == nil)
    }

    @Test func theSeeLinkNamesTheRoundsRevision() {
        #expect(PlanArtifacts.seeLabel(round(0, .design, revision: 3, own: true, kind: .diagram)) == "See v3")
        #expect(PlanArtifacts.seeLabel(round(0, .questions, revision: nil, own: false, kind: nil)) == nil)
    }

    @Test func aRoundDecodesWithAndWithoutArtifactFields() throws {
        let base = #"""
        {"seq":1,"stage":{"name":"design"},"question":"Q","options":[],"recommendation":"a",
         "recommendation_why":"R","created_at":"2026-10-03T09:00:00Z","answer":null
        """#
        let old = try JSONDecoder().decode(PlanRound.self, from: Data((base + "}").utf8))
        #expect(old.revision == nil && old.ownArtifact == false && old.artifactKind == nil)
        let new = try JSONDecoder().decode(
            PlanRound.self,
            from: Data((base + #","revision":2,"own_artifact":true,"artifact_kind":"html_bundle"}"#).utf8))
        #expect(new.revision == 2 && new.ownArtifact && new.artifactKind == .htmlBundle)
    }

    @Test func aPlanCaseCarriesTheKindOfItsNewestRoundArtifact() throws {
        let with = try JSONDecoder().decode(
            PlanInfo.self,
            from: Data(#"{"stage":{"name":"design"},"rounds":2,"answered":1,"artifact_kind":"diagram"}"#.utf8))
        #expect(with.artifactKind == .diagram)
        let without = try JSONDecoder().decode(
            PlanInfo.self, from: Data(#"{"stage":{"name":"design"},"rounds":2,"answered":1}"#.utf8))
        #expect(without.artifactKind == nil)
    }

    // MARK: the stage

    private func makeModel(_ artifacts: Artifacts) async throws -> (ReviewViewModel, FakeKnockServer) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id, method == "artifact.path" else { return nil }
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            let params = object?["params"] as? [String: Any]
            let revision = params?["revision"] as? Int ?? 1
            return jsonRPCOK(id: id, result: artifacts.byRevision[revision] ?? "{}")
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return (ReviewViewModel(client: client), server)
    }

    @Test func aRoundWithAnotherArtifactKindStartsTheStageOverAndAnEarlierRoundOpensReadOnly() async throws {
        let artifacts = Artifacts()
        let shot = try writeShot(), md = try writeMarkdown("# Spec\n\nAll good.")
        artifacts.byRevision[1] = #"{"kind":"screenshot","root":"\#(shot)","entry":""}"#
        artifacts.byRevision[2] = #"{"kind":"markdown","root":"\#(md)","entry":""}"#
        let (model, server) = try await makeModel(artifacts)
        defer { server.stop() }

        let first = [round(0, .questions, revision: 1, own: true, kind: .screenshot, answered: false)]
        await model.load(detail: try planDetail(rounds: first, revisions: 1))
        guard case .screenshot = model.artifactState else { Issue.record("round 1 shows its screenshot"); return }
        #expect(model.commentsStore.currentImage != nil)
        #expect(model.mode == .comment)

        let both = [
            round(0, .questions, revision: 1, own: true, kind: .screenshot),
            round(1, .spec, revision: 2, own: true, kind: .markdown, answered: false),
        ]
        await model.refresh(detail: try planDetail(rounds: both, revisions: 2))
        guard case .markdown(let text, let revision) = model.artifactState else { Issue.record("round 2 shows markdown"); return }
        #expect(revision == 2 && text.contains("All good"))
        #expect(model.commentsStore.model.captures.isEmpty, "the screenshot's stills are gone")
        #expect(model.staleArtifactNote == nil)

        // History: open round 1's screenshot read-only, then come back.
        model.viewRevision(1)
        _ = try await pollUntil(.seconds(20)) {
            if case .images = model.olderRevisionDisplay?.content { return true } else { return false }
        }
        #expect(model.olderRevisionDisplay?.revision == 1)
        guard case .images(let images)? = model.olderRevisionDisplay?.content else { Issue.record("round 1 opens as an image"); return }
        #expect(images.count == 1)
        model.returnToLatestRevision()
        #expect(model.olderRevisionDisplay == nil)
        #expect(model.artifactState.revision == 2)
    }

    @Test func aNewRoundLeavesAnEarlierRoundThatWasOpen() async throws {
        let artifacts = Artifacts()
        let md = try writeMarkdown("# One")
        artifacts.byRevision[1] = #"{"kind":"markdown","root":"\#(md)","entry":""}"#
        let (model, server) = try await makeModel(artifacts)
        defer { server.stop() }
        let one = [round(0, .questions, revision: 1, own: true, kind: .markdown)]
        await model.load(detail: try planDetail(rounds: one, revisions: 1))
        model.viewRevision(1)
        #expect(model.olderRevisionDisplay != nil)
        let two = one + [round(1, .questions, revision: 1, own: false, kind: .markdown, answered: false)]
        await model.refresh(detail: try planDetail(rounds: two, revisions: 1))
        #expect(model.olderRevisionDisplay == nil, "a new round shows its own artifact")
    }
}
