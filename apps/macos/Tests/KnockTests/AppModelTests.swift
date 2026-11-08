import Testing
import Foundation
@testable import Knock

/// Exercises `AppModel` against `FakeKnockServer` per KNOCK-08's acceptance
/// criteria: the needs_you/waiting_on_agent split, newest-first ordering
/// (docs/stories/HAIL-34.md operator amendment, 2026-09-28), task/artifact-
/// kind enrichment, keyboard navigation, and the review-only activation gate.
struct AppModelTests {
    private struct LinePeek: Decodable {
        let method: String
        let id: Int?
        let params: ParamsPeek?
    }

    private struct ParamsPeek: Decodable {
        let status: String?
        let id: String?
        let caseId: String?
        let revision: Int?
        let replyId: String?

        private enum CodingKeys: String, CodingKey {
            case status, id
            case caseId = "case_id"
            case revision
            case replyId = "reply_id"
        }
    }

    /// The `c_waiting` fixture's current reply, mutable so a test can push
    /// a `reply.state_changed` event and have the server's next `cases.get`
    /// answer with the outcome that event describes - `FakeKnockServer`
    /// scripts respond from a fixed table otherwise, but this one reply
    /// needs to change mid-test.
    private final class LockedReplyState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (id: String, state: String)?

        func set(id: String, state: String) {
            lock.lock()
            value = (id, state)
            lock.unlock()
        }

        var current: (id: String, state: String)? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Case ids the scripted `cases.list` leaves out (HAIL-118): a test hides an ask, then
    /// shows it, to make it arrive (or return to Needs you) between two refreshes.
    private final class HiddenCaseIds: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String>
        init(_ ids: Set<String> = []) { self.ids = ids }
        func set(_ new: Set<String>) { lock.lock(); ids = new; lock.unlock() }
        func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    }

    /// Blocks a scripted `cases.get` response for one case id until told to
    /// proceed (HAIL-47): lets a test hold a "still fetching" response open
    /// long enough to assert what the pane shows before that fetch resolves
    /// - the same shape of race a fast second click, or a click that lands
    /// on an already-warm row, produces against the real daemon. Waits on
    /// the server's own background accept thread (`FakeKnockServer` calls
    /// `onRequest` synchronously there), so blocking it is safe: nothing on
    /// the test's `MainActor` depends on that thread making progress except
    /// the one gated response.
    /// A one-shot latch, not a single-use semaphore: `enrichMetadata`'s own
    /// background fetch and a test's own `open(caseId:)` call can both land
    /// on the server at once while a case id is armed, so `release()` must
    /// wake every waiter, current and future, not just one.
    private final class CaseFetchGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var armedCaseId: String?
        private var released = false

        func arm(for caseId: String) {
            condition.lock()
            armedCaseId = caseId
            released = false
            condition.unlock()
        }

        func waitIfArmed(for caseId: String) {
            condition.lock()
            defer { condition.unlock() }
            guard armedCaseId == caseId else { return }
            while !released {
                condition.wait()
            }
        }

        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }

    /// A tiny scripted daemon: two `needs_you` cases (one with an artifact),
    /// one `waiting_on_agent` case, and the task/revision/artifact data
    /// `cases.get`/`artifact.path` need to answer KNOCK-08's enrichment
    /// calls. `created_at` is intentionally out of list order so ordering
    /// is genuinely exercised, not just preserved.
    private func makeServer(
        socketPath: String, waitingReply: LockedReplyState = LockedReplyState(), gate: CaseFetchGate? = nil,
        hidden: HiddenCaseIds? = nil
    ) -> FakeKnockServer {
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            let peek = try? JSONDecoder().decode(LinePeek.self, from: line)

            if method == "cases.get", let caseId = peek?.params?.id {
                gate?.waitIfArmed(for: caseId)
            }

            switch method {
            case "cases.list":
                let status = peek?.params?.status
                let all = [
                    (#"{"id":"c_new","task_id":"t_1","task_name":"Card pricing","project":"weekend-league","kind":"question","title":"Newer","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"needs_you","has_artifact":false,"artifact_kind":null,"runtime":"claude","created_at":"2026-09-26T10:10:00.000Z","updated_at":"2026-09-26T10:10:00.000Z"}"#, "needs_you"),
                    (#"{"id":"c_old","task_id":"t_2","task_name":"Checkout redesign","project":"omea-web","kind":"review","title":"Older, with artifact","need":"N","why":"W","recommendation":"a","recommendation_why":"RW","options":[{"id":"a","label":"Compact"}],"status":"needs_you","has_artifact":true,"artifact_kind":"html_bundle","runtime":"claude","created_at":"2026-09-26T10:00:00.000Z","updated_at":"2026-09-26T10:00:00.000Z"}"#, "needs_you"),
                    (#"{"id":"c_waiting","task_id":"t_1","kind":"review","title":"Sent back already","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"waiting_on_agent","has_artifact":false,"runtime":"claude","created_at":"2026-09-26T09:00:00.000Z","updated_at":"2026-09-26T09:00:00.000Z"}"#, "waiting_on_agent"),
                ]
                let matching = all.filter { entry in
                    (status == nil || entry.1 == status)
                        && !(hidden?.contains(entry.0.contains(#""id":"c_new""#) ? "c_new" : entry.0.contains(#""id":"c_old""#) ? "c_old" : "c_waiting") ?? false)
                }.map(\.0)
                return jsonRPCOK(id: id, result: "[\(matching.joined(separator: ","))]")

            case "cases.get":
                guard let caseId = peek?.params?.id else { return nil }
                switch caseId {
                case "c_new":
                    return jsonRPCOK(id: id, result: #"""
                    {"case":{"id":"c_new","task_id":"t_1","kind":"question","title":"Newer","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"needs_you","has_artifact":false,"runtime":"claude","created_at":"2026-09-26T10:10:00.000Z","updated_at":"2026-09-26T10:10:00.000Z"},
                     "task":{"id":"t_1","name":"Card pricing","project":"weekend-league"},
                     "messages":[],"revisions":[],"comments":[],"replies":[]}
                    """#)
                case "c_old":
                    return jsonRPCOK(id: id, result: #"""
                    {"case":{"id":"c_old","task_id":"t_2","kind":"review","title":"Older, with artifact","need":"N","why":"W","recommendation":"a","recommendation_why":"RW","options":[{"id":"a","label":"Compact"}],"status":"needs_you","has_artifact":true,"runtime":"claude","created_at":"2026-09-26T10:00:00.000Z","updated_at":"2026-09-26T10:00:00.000Z"},
                     "task":{"id":"t_2","name":"Checkout redesign","project":"omea-web"},
                     "messages":[],"revisions":[{"id":"r_1","case_id":"c_old","n":1,"created_at":"2026-09-26T10:00:00.000Z"}],"comments":[],"replies":[]}
                    """#)
                case "c_waiting":
                    let repliesJSON: String
                    if let reply = waitingReply.current {
                        repliesJSON = #"[{"id":"\#(reply.id)","case_id":"c_waiting","idempotency_key":"k1","choice":null,"message":null,"comments":[],"captures":[],"state":"\#(reply.state)","created_at":"2026-09-26T09:00:00.000Z"}]"#
                    } else {
                        repliesJSON = "[]"
                    }
                    return jsonRPCOK(id: id, result: #"""
                    {"case":{"id":"c_waiting","task_id":"t_1","kind":"review","title":"Sent back already","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"waiting_on_agent","has_artifact":false,"runtime":"claude","created_at":"2026-09-26T09:00:00.000Z","updated_at":"2026-09-26T09:00:00.000Z"},
                     "task":{"id":"t_1","name":"Card pricing","project":"weekend-league"},
                     "messages":[],"revisions":[],"comments":[],"replies":\#(repliesJSON)}
                    """#)
                default:
                    return nil
                }

            case "artifact.path":
                guard peek?.params?.caseId == "c_old" else { return nil }
                return jsonRPCOK(id: id, result: #"{"kind":"html_bundle","root":"/data/bundles/c_old/r1","entry":"index.html"}"#)

            case "reply.retry":
                guard let replyId = peek?.params?.replyId, let reply = waitingReply.current else { return nil }
                return jsonRPCOK(id: id, result: #"{"id":"\#(replyId)","case_id":"c_waiting","idempotency_key":"k1","choice":null,"message":null,"comments":[],"captures":[],"state":"\#(reply.state)","created_at":"2026-09-26T09:05:00.000Z"}"#)

            case "events.subscribe":
                return jsonRPCOK(id: id, result: "{}")

            case "case.dismiss":
                // HAIL-116: only so a test can empty the pane; the list keeps its rows.
                return jsonRPCOK(id: id, result: #"{"id":"c_new","task_id":"t_1","kind":"question","title":"Newer","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"resolved","has_artifact":false,"runtime":"claude","created_at":"2026-09-26T10:10:00.000Z","updated_at":"2026-09-26T10:10:00.000Z"}"#)

            default:
                return jsonRPCOK(id: id, result: "{}")
            }
        }
        return server
    }

    @MainActor
    private func makeModel(
        socketPath: String,
        environment: [String: String] = [:],
        bundleIdentifier: String? = TestCopyEnvironment.releaseBundleIdentifier,
        waitingReply: LockedReplyState = LockedReplyState(),
        gate: CaseFetchGate? = nil,
        usage: UsageReporter? = nil,
        hidden: HiddenCaseIds? = nil
    ) -> (AppModel, FakeKnockServer) {
        let server = makeServer(socketPath: socketPath, waitingReply: waitingReply, gate: gate, hidden: hidden)
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        return (AppModel(client: client, environment: isolatedKnockEnvironment(environment), bundleIdentifier: bundleIdentifier, usage: usage), server)
    }

    @MainActor
    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        if try await !pollUntil(timeout, condition) { throw TestClientError.timedOut }
    }

    @Test @MainActor func splitsGroupsSortsNewestFirstAndEnrichesMetadata() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        let getCalls = LockedCounter()
        let inner = server.onRequest
        server.onRequest = { method, id, line in
            if method == "cases.get" { getCalls.increment() }
            return inner?(method, id, line)
        }

        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }

        #expect(model.needsYouCases.map(\.id) == ["c_new", "c_old"])
        #expect(model.waitingOnAgentCases.map(\.id) == ["c_waiting"])

        // PERF-4: the rows carry the task and the artifact kind, so launch fetches no case detail but the auto-selected one.
        #expect(model.needsYouCases.last?.knockTask == KnockTask(id: "t_2", name: "Checkout redesign", project: "omea-web"))
        #expect(model.artifactKindByCaseId["c_old"] == .htmlBundle)
        #expect(model.artifactKindByCaseId["c_new"] == nil)
        try await waitUntil(.seconds(30)) { model.cachedDetailCount >= 1 }
        try await Task.sleep(for: .milliseconds(150))
        // Only the auto-selected top ask is fetched, not all three.
        #expect(getCalls.value == 1)
        #expect(model.cachedDetailCount == 1)

        model.stop()
    }

    /// HAIL-134: the Knock Claude Code mod's "open" button sends `case.open_requested`;
    /// the app hands the case to `onOpenRequested` and changes nothing else.
    @Test @MainActor func aCaseOpenRequestIsHandedToTheOpenHandler() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        var opened: [String?] = []
        model.onOpenRequested = { opened.append($0) }

        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }
        server.pushEvent(Event(type: .caseOpenRequested, caseId: "c_old", replyId: nil, sessionId: nil, at: "2026-10-02T10:00:00.000Z"))
        try await waitUntil { opened == ["c_old"] }
        // No case: the band's "queue" button asks for the queue.
        server.pushEvent(Event(type: .caseOpenRequested, caseId: nil, replyId: nil, sessionId: nil, at: "2026-10-02T10:00:01.000Z"))
        try await waitUntil { opened == ["c_old", nil] }

        model.stop()
    }

    /// AC: "onConnected subscribes and runs refreshCases() first ...
    /// Resubmission then runs as a separate background task that never
    /// blocks the list" - the operator report this fixes was exactly a
    /// resubmit that never returned, before `subscribeEvents()`/
    /// `refreshCases()` had run at all, leaving the queue on "No cases yet"
    /// forever. This server never answers `reply.submit` at all; the queue
    /// must still fill from `cases.list` alone.
    @Test @MainActor func refreshCasesFillsTheQueueWhileAPendingReplyNeverGetsAResubmitResponse() async throws {
        let socketPath = makeTempSocketPath()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("knock_appmodel_\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let environment = ["KNOCK_HOME": home]
        try PendingReplyStore(environment: environment).save(
            PendingReply(caseId: "c_waiting", idempotencyKey: "key-1", choice: nil, message: "hi", comments: [], captures: [])
        )

        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            switch method {
            case "reply.submit":
                return nil // Deliberately never answered.
            case "cases.list":
                let peek = try? JSONDecoder().decode(LinePeek.self, from: line)
                let status = peek?.params?.status
                guard status == nil || status == "waiting_on_agent" else {
                    return jsonRPCOK(id: id, result: "[]")
                }
                return jsonRPCOK(id: id, result: #"""
                [{"id":"c_waiting","task_id":"t_1","task_name":"Card pricing","project":"weekend-league","kind":"review",
                  "title":"Sent back already","need":"N","why":"W","recommendation":"R","recommendation_why":"RW",
                  "options":[],"status":"waiting_on_agent","has_artifact":false,"runtime":"claude",
                  "created_at":"2026-09-26T09:00:00.000Z","updated_at":"2026-09-26T09:00:00.000Z"}]
                """#)
            case "events.subscribe":
                return jsonRPCOK(id: id, result: "{}")
            default:
                return jsonRPCOK(id: id, result: "{}")
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        let model = AppModel(client: client, environment: isolatedKnockEnvironment(environment))
        model.start()

        // No tight wall-clock bound: a loaded machine can be slow. The bound only has to stay
        // under the 15 s resubmit timeout, so a queue that waited on the resubmit still fails.
        try await waitUntil(.seconds(10)) { model.waitingOnAgentCases.map(\.id) == ["c_waiting"] }

        model.stop()
    }

    @Test @MainActor func newCaseAppearsFromAPushedEventWithoutAManualRefresh() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }

        // The fake server's script is static, so this doesn't add a case;
        // it proves the push alone re-triggers `cases.list` (AC: event
        // driven, no manual refresh call from the test).
        server.pushEvent(Event(type: .caseCreated, caseId: "c_new", replyId: nil, sessionId: nil, at: "2026-09-26T10:10:00.000Z"))
        try await waitUntil { model.needsYouCases.count == 2 }
        #expect(model.needsYouCases.map(\.id) == ["c_new", "c_old"])

        model.stop()
    }

    /// HAIL-120: a refresh that fails after a case event (a timeout, a reconnect in flight)
    /// must not leave the queue without the new ask. The model reads again on its own, and
    /// leaves a line in the data root's logs folder.
    @Test @MainActor func aFailedRefreshAfterAnEventIsRetriedAndLogged() async throws {
        let socketPath = makeTempSocketPath()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("knock_retry_\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let failList = HiddenCaseIds()
        let server = FakeKnockServer(socketPath: socketPath)
        let caseJSON = #"{"id":"c_followup","task_id":"t_1","kind":"review","title":"Follow-up","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"needs_you","has_artifact":false,"follows_case_id":"c_parent","runtime":"claude","created_at":"2026-10-01T14:49:42.000Z","updated_at":"2026-10-01T14:49:42.000Z"}"#
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            if method == "cases.list" {
                if failList.contains("fail") {
                    return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"boom"}}"#.utf8)
                }
                let status = (try? JSONDecoder().decode(LinePeek.self, from: line))?.params?.status
                return jsonRPCOK(id: id, result: status == "needs_you" ? "[\(caseJSON)]" : "[]")
            }
            return jsonRPCOK(id: id, result: "{}")
        }
        try server.start()
        defer { server.stop() }
        failList.set(["fail"])
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        let model = AppModel(client: client, environment: ["KNOCK_HOME": home])
        model.refreshRetryDelays = [0.05, 0.05, 0.05, 0.05]
        model.start()
        try await waitUntil { model.lastErrorMessage != nil }
        #expect(model.needsYouCases.isEmpty)

        failList.set([])
        try await waitUntil { model.needsYouCases.map(\.id) == ["c_followup"] }

        let log = try String(contentsOfFile: home + "/logs/queue.log", encoding: .utf8)
        #expect(log.contains("onConnected failed"))
        model.stop()
    }

    @Test @MainActor func moveSelectionClampsAtBothEnds() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.needsYouCases.count == 2 && model.waitingOnAgentCases.count == 1 }
        // "c_waiting" has a newer ask on its task, so it sits in the Answered
        // group; keyboard order only reaches it while that group is open.
        model.answeredOpen = true

        model.moveSelection(by: 1)
        try await waitUntil { model.selectedCaseId == "c_new" }

        model.moveSelection(by: 1)
        try await waitUntil { model.selectedCaseId == "c_old" }

        model.moveSelection(by: 1)
        try await waitUntil { model.selectedCaseId == "c_waiting" }

        model.moveSelection(by: 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.selectedCaseId == "c_waiting")

        model.moveSelection(by: -1)
        try await waitUntil { model.selectedCaseId == "c_old" }

        model.stop()
    }

    /// `AppModel.canOpenReview`: the pure rule behind `activateSelection()`
    /// and `ArtifactPreviewCard`'s tap (docs/stories/HAIL-36.md amendment 3,
    /// operator, 16:23: "why i cannot click this?") - a question ask opens
    /// the review workspace once it carries an artifact, same as a review
    /// ask always does.
    @Test @MainActor func canOpenReviewIsTrueForAReviewAskOrAQuestionAskWithAnArtifact() {
        #expect(AppModel.canOpenReview(kind: .question, hasArtifact: true))
        #expect(!AppModel.canOpenReview(kind: .question, hasArtifact: false))
        #expect(AppModel.canOpenReview(kind: .review, hasArtifact: true))
        #expect(AppModel.canOpenReview(kind: .review, hasArtifact: false))
    }

    /// WAG-347: Comment in the case box opens the review with the box's page; closing the review drops it.
    @Test @MainActor func theReviewOpenedByCommentKeepsTheBoxPageUntilItCloses() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }
        await model.open(caseId: "c_old")
        let handoff = CommentHandoff(hash: "#plans", scroll: CGPoint(x: 0, y: 320))
        model.activateSelection(commentHandoff: handoff)
        try await waitUntil { model.reviewRequestCaseId == "c_old" }
        #expect(model.reviewRequestCaseId == "c_old")
        #expect(model.reviewCommentHandoff == handoff)

        model.closeReview()
        #expect(model.reviewCommentHandoff == nil)
    }

    /// WAG-257: every ask is the decision doc. Return opens the review (comments) only for an ask with an artifact:
    /// `c_old` carries a prototype, `c_new` is a plain question.
    @Test @MainActor func activateSelectionOpensTheReviewOnlyForAnAskWithAnArtifact() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }

        await model.open(caseId: "c_new")
        #expect(model.selectedCaseId == "c_new")
        model.activateSelection()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.reviewRequestCaseId == nil)

        await model.open(caseId: "c_old")
        model.activateSelection()
        try await waitUntil { model.reviewRequestCaseId == "c_old" }
        #expect(model.reviewRequestCaseId == "c_old")

        model.closeReview()
        #expect(model.reviewRequestCaseId == nil)

        model.stop()
    }

    /// KNOCK-09: `case.created` for a case that is (still) `needs_you`
    /// feeds `caseNotifications`; `case.updated`, which can also return a
    /// case to `needs_you`, must not (contract: "On `case.created` for a
    /// `needs_you` case: one notification").
    @Test @MainActor func onlyCaseCreatedEventsFeedCaseNotifications() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }

        final class Collected: @unchecked Sendable {
            var items: [NotificationContent] = []
        }
        let collected = Collected()
        let collectTask = Task {
            for await content in model.caseNotifications {
                collected.items.append(content)
            }
        }

        server.pushEvent(Event(type: .caseUpdated, caseId: "c_old", replyId: nil, sessionId: nil, at: "2026-09-26T10:11:00.000Z"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(collected.items.isEmpty)

        server.pushEvent(Event(type: .caseCreated, caseId: "c_new", replyId: nil, sessionId: nil, at: "2026-09-26T10:12:00.000Z"))
        try await waitUntil { collected.items.count == 1 }
        #expect(collected.items[0].caseId == "c_new")
        #expect(collected.items[0].title == "[test] Claude needs your decision: Newer", "the temp KNOCK_HOME makes this a test copy (WAG-358)")

        server.pushEvent(Event(type: .caseCreated, caseId: "c_old", replyId: nil, sessionId: nil, at: "2026-09-26T10:13:00.000Z"))
        try await waitUntil { collected.items.count == 2 }
        #expect(collected.items[1].caseId == "c_old")

        collectTask.cancel()
        model.stop()
    }

    /// KNOCK_OPEN_CASE is the evidence hook for launch-time deep links
    /// (Amendments): notifications (KNOCK-09) will call `open(caseId:)` the
    /// same way once a case is already selectable.
    @Test @MainActor func opensTheCaseNamedByKnockOpenCaseOnceTheFirstListLoads() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath, environment: ["KNOCK_OPEN_CASE": "c_old"])
        try server.start()
        defer { server.stop() }

        model.start()
        // HAIL-24 fold: waiting on `selectedCaseId` alone is flaky under a
        // busy full-suite run - `open(caseId:)` sets it synchronously, before
        // the `casesGet` it then awaits resolves `selectedCaseDetail`, so a
        // slow scheduler can let this `waitUntil` see the id land and this
        // test's own assertion run in the gap before the detail does. Wait on
        // the detail itself instead, since that is what the assertion checks.
        try await waitUntil { model.selectedCaseDetail != nil }
        #expect(model.selectedCaseId == "c_old")
        #expect(model.selectedCaseDetail?.task.id == "t_2")

        model.stop()
    }

    /// HAIL-24: a caller (the setup window's own Open, a notification click)
    /// can call `open(caseId:)` in the same instant `start()` begins - the
    /// exact race `AppActivation.showMainWindow()` creating the main window
    /// for the first time produces, since that is also the first moment
    /// `MainWindowView`'s own `.task { model.start() }` runs. `open` must
    /// still resolve the case once the connection catches up, not fail with
    /// `notConnected` because `casesGet` fired before the socket was up.
    @Test @MainActor func openCalledInTheSameInstantAsStartStillResolvesOnceConnected() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        model.start()
        await model.open(caseId: "c_old")

        #expect(model.selectedCaseId == "c_old")
        #expect(model.selectedCaseDetail?.task.id == "t_2", "open() must wait for the connection rather than fail instantly")

        model.stop()
    }

    /// `KNOCK_OPEN_REVIEW=1` alongside `KNOCK_OPEN_CASE` (Amendments): a deep link to an ask with an
    /// artifact opens its review workspace, where comments work (WAG-257: the doc page itself has none).
    @Test @MainActor func knockOpenReviewOpensTheReviewOfAnAskWithAnArtifact() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath, environment: ["KNOCK_OPEN_CASE": "c_old", "KNOCK_OPEN_REVIEW": "1"])
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_old" }
        try await waitUntil { model.reviewRequestCaseId == "c_old" }

        model.stop()
    }

    /// A question case (no review workspace to open) is opened but not
    /// pushed into the review workspace, even with `KNOCK_OPEN_REVIEW=1`.
    @Test @MainActor func knockOpenReviewIsIgnoredForAQuestionCase() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath, environment: ["KNOCK_OPEN_CASE": "c_new", "KNOCK_OPEN_REVIEW": "1"])
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.selectedCaseId == "c_new" }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.reviewRequestCaseId == nil)

        model.stop()
    }

    /// `KNOCK_OPEN_REVIEW=1` for a question case that DOES carry an artifact
    /// (docs/stories/HAIL-36.md amendment 3): the deep-link evidence hook
    /// must apply the same `canOpenReview` rule `activateSelection()` uses,
    /// not just `kind == .review` - otherwise the orchestrator has no way to
    /// drive this state into a capture even though a real click/Return now
    /// opens it.
    @Test @MainActor func knockOpenReviewOpensAQuestionCaseThatCarriesAnArtifact() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            switch method {
            case "cases.list":
                return jsonRPCOK(id: id, result: #"[{"id":"c_q_art","task_id":"t_1","kind":"question","title":"Ship the plan?","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"needs_you","has_artifact":true,"runtime":"claude","created_at":"2026-09-26T10:00:00.000Z","updated_at":"2026-09-26T10:00:00.000Z"}]"#)
            case "cases.get":
                return jsonRPCOK(id: id, result: #"""
                {"case":{"id":"c_q_art","task_id":"t_1","kind":"question","title":"Ship the plan?","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"needs_you","has_artifact":true,"runtime":"claude","created_at":"2026-09-26T10:00:00.000Z","updated_at":"2026-09-26T10:00:00.000Z"},
                 "task":{"id":"t_1","name":"Card pricing","project":"weekend-league"},
                 "messages":[],"revisions":[],"comments":[],"replies":[]}
                """#)
            case "events.subscribe":
                return jsonRPCOK(id: id, result: "{}")
            default:
                return jsonRPCOK(id: id, result: "{}")
            }
        }
        try server.start()
        defer { server.stop() }

        let (model, _) = (
            AppModel(
                client: KnockClient(socketPath: socketPath, backoffSchedule: [0.02]),
                environment: isolatedKnockEnvironment(["KNOCK_OPEN_CASE": "c_q_art", "KNOCK_OPEN_REVIEW": "1"]),
                bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier
            ), server
        )
        model.start()
        try await waitUntil { model.reviewRequestCaseId == "c_q_art" }
        #expect(model.selectedCaseId == "c_q_art")

        model.stop()
    }

    /// Amendment 2 (KNOCK-13 fold): the real delivery outcome comes from
    /// `reply.state_changed`, re-read with `cases.get` - never optimistically
    /// from `reply.submit`'s own `queued` result (AC 8).
    @Test @MainActor func replyStateChangedDeliveredRendersDeliveredForItsCase() async throws {
        let socketPath = makeTempSocketPath()
        let waitingReply = LockedReplyState()
        let (model, server) = makeModel(socketPath: socketPath, waitingReply: waitingReply)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.waitingOnAgentCases.map(\.id) == ["c_waiting"] }
        #expect(model.deliveryStatusByCaseId["c_waiting"] == nil, "nothing is known yet - queued must never render as delivered")

        waitingReply.set(id: "r_1", state: "delivered")
        server.pushEvent(Event(type: .replyStateChanged, caseId: "c_waiting", replyId: "r_1", sessionId: nil, at: "2026-09-26T09:05:00.000Z"))

        try await waitUntil {
            if case .delivered = model.deliveryStatusByCaseId["c_waiting"] { true } else { false }
        }

        model.stop()
    }

    /// Amendment 2/4 (KNOCK-13 fold): a `reply.state_changed` failed event
    /// renders Failed, and its Retry calls `reply.retry` - never a second
    /// `reply.submit` (AC 8 "make retry explicitly idempotent").
    @Test @MainActor func replyStateChangedFailedRendersFailedAndRetryCallsReplyRetry() async throws {
        let socketPath = makeTempSocketPath()
        let waitingReply = LockedReplyState()
        let (model, server) = makeModel(socketPath: socketPath, waitingReply: waitingReply)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.waitingOnAgentCases.map(\.id) == ["c_waiting"] }

        waitingReply.set(id: "r_2", state: "failed")
        server.pushEvent(Event(type: .replyStateChanged, caseId: "c_waiting", replyId: "r_2", sessionId: nil, at: "2026-09-26T09:05:00.000Z"))

        try await waitUntil { model.deliveryStatusByCaseId["c_waiting"] == .failed(replyId: "r_2") }

        // The daemon requeues it once Retry reaches it.
        waitingReply.set(id: "r_2", state: "queued")
        await model.retryDelivery(caseId: "c_waiting")

        #expect(model.deliveryStatusByCaseId["c_waiting"] == nil, "a requeued reply clears the stale Failed banner until the next reply.state_changed")

        model.stop()
    }

    /// Contract amendment 1 (KNOCK-13 fold pass 3): a case's persisted
    /// `latest_reply_state`/`latest_reply_id` (docs/protocol-mvp.md "Case
    /// fields") - not an event - is what shows Delivered/Failed after a
    /// relaunch. This server pushes no event at all: `cases.list` alone
    /// already carries both outcomes.
    @Test @MainActor func persistedLatestReplyStateRendersWithoutAnyEvent() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            switch method {
            case "cases.list":
                return jsonRPCOK(id: id, result: #"""
                [{"id":"c_delivered","task_id":"t_1","kind":"review","title":"Delivered already","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"waiting_on_agent","has_artifact":false,"latest_reply_id":"r_1","latest_reply_state":"delivered","latest_reply_at":"2026-09-26T09:10:00.000Z","created_at":"2026-09-26T09:00:00.000Z","updated_at":"2026-09-26T09:10:00.000Z"},
                 {"id":"c_failed","task_id":"t_1","kind":"review","title":"Failed already","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"waiting_on_agent","has_artifact":false,"latest_reply_id":"r_2","latest_reply_state":"failed","latest_reply_at":"2026-09-26T09:12:00.000Z","created_at":"2026-09-26T09:01:00.000Z","updated_at":"2026-09-26T09:12:00.000Z"}]
                """#)
            case "cases.get":
                return jsonRPCOK(id: id, result: #"""
                {"case":{"id":"c_delivered","task_id":"t_1","kind":"review","title":"Delivered already","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"waiting_on_agent","has_artifact":false,"latest_reply_id":"r_1","latest_reply_state":"delivered","latest_reply_at":"2026-09-26T09:10:00.000Z","created_at":"2026-09-26T09:00:00.000Z","updated_at":"2026-09-26T09:10:00.000Z"},
                 "task":{"id":"t_1","name":"Card pricing","project":"weekend-league"},
                 "messages":[],"revisions":[],"comments":[],"replies":[]}
                """#)
            case "events.subscribe":
                return jsonRPCOK(id: id, result: "{}")
            default:
                return jsonRPCOK(id: id, result: "{}")
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        let model = AppModel(client: client, environment: isolatedKnockEnvironment())
        model.start()

        try await waitUntil { model.waitingOnAgentCases.count == 2 }
        try await waitUntil { model.deliveryStatusByCaseId["c_failed"] == .failed(replyId: "r_2") }
        guard case .delivered = model.deliveryStatusByCaseId["c_delivered"] else {
            Issue.record("expected c_delivered to render Delivered from cases.list alone, no event")
            model.stop()
            return
        }

        model.stop()
    }

    /// A thread-safe flag `FakeKnockServer.onRequest` (its own background
    /// accept thread) and the test's main thread both touch - the dismiss
    /// tests use it to make `cases.list`/`case.dismiss`/`case.restore`
    /// answer consistently with each other across the round trip.
    private final class DismissedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set(_ newValue: Bool) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        var current: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func soloCaseJSON(status: String) -> String {
        #"""
        {"id":"c_solo","task_id":"t_1","task_name":"Card pricing","project":"weekend-league","kind":"question","title":"Pick a layout","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"\#(status)","has_artifact":false,"runtime":"claude","created_at":"2026-09-26T09:00:00.000Z","updated_at":"2026-09-26T09:00:00.000Z"}
        """#
    }

    /// HAIL-152: Got it on a done case is `case.dismiss` and nothing else. No reply is made for
    /// the agent: no `reply.submit`, `reply.replace` or `reply.retry` is sent.
    @Test @MainActor func gotItClosesADoneCaseAndSendsNoReply() async throws {
        let socketPath = makeTempSocketPath()
        let dismissed = DismissedFlag()
        let methods = MethodLog()
        let doneJSON = #"""
        {"id":"c_done","task_id":"t_1","task_name":"Card pricing","project":"weekend-league","kind":"question","title":"Ship the rebrand?","need":"N","why":"W","recommendation":"R","recommendation_why":"RW","options":[],"status":"waiting_on_agent","has_artifact":false,"runtime":"claude","latest_reply_id":"r_1","latest_reply_state":"queued","latest_reply_at":"2026-10-03T17:00:00.000Z","latest_update_message":"Done and live.","done_at":"2026-10-03T17:05:00.000Z","created_at":"2026-10-03T16:00:00.000Z","updated_at":"2026-10-03T17:05:00.000Z"}
        """#

        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            methods.add(method)
            let peek = try? JSONDecoder().decode(LinePeek.self, from: line)
            switch method {
            case "cases.list":
                let status = peek?.params?.status
                guard !dismissed.current, status == nil || status == "waiting_on_agent" else {
                    return jsonRPCOK(id: id, result: "[]")
                }
                return jsonRPCOK(id: id, result: "[\(doneJSON)]")
            case "case.dismiss":
                dismissed.set(true)
                return jsonRPCOK(id: id, result: doneJSON.replacingOccurrences(of: "waiting_on_agent", with: "resolved"))
            default:
                return jsonRPCOK(id: id, result: "{}")
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        // Own KNOCK_HOME: with the default one, a pending reply another test saved could be
        // resubmitted here, and the test would then see a reply it never made.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("knock_appmodel_\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let model = AppModel(client: client, environment: ["KNOCK_HOME": home])
        model.start()

        // Awaited conditions with a generous bound, never a tight clock: a loaded suite is slow.
        try await waitUntil(.seconds(30)) { model.waitingOnAgentCases.map(\.id) == ["c_done"] }
        try await waitUntil(.seconds(30)) { model.waitingOnAgentCases.first?.isDone == true }
        // A done case never moves to the Answered group, whatever the reply state.
        try await waitUntil(.seconds(30)) { model.stillWaitingCases.map(\.id) == ["c_done"] && model.activeCases.isEmpty }
        // Let the startup refresh finish first: one still in flight could put the case back
        // after the dismiss, from a list it fetched before.
        try await waitUntil(.seconds(30)) { methods.all.contains("events.subscribe") }

        await model.dismiss(caseId: "c_done")
        try await waitUntil(.seconds(30)) { model.waitingOnAgentCases.isEmpty }
        let sent = methods.all
        #expect(sent.contains("case.dismiss"))
        #expect(!sent.contains { $0.hasPrefix("reply.") }, "methods sent: \(sent)")

        model.stop()
    }

    private final class MethodLog: @unchecked Sendable {
        private let lock = NSLock()
        private var methods: [String] = []
        func add(_ method: String) {
            lock.lock()
            methods.append(method)
            lock.unlock()
        }
        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return methods
        }
    }

    /// docs/stories/HAIL-32.md: "the row leaves the queue at once" and "an
    /// Undo toast for 5 s calls case.restore". `dismiss` removes the row
    /// without waiting for the `case.updated` event the RPC also emits;
    /// `undoDismiss` calls `case.restore` and re-reads the list, landing the
    /// case back in `needsYouCases`.
    @Test @MainActor func dismissRemovesTheRowAtOnceAndUndoRestoresIt() async throws {
        let socketPath = makeTempSocketPath()
        let dismissed = DismissedFlag()

        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            let peek = try? JSONDecoder().decode(LinePeek.self, from: line)
            switch method {
            case "cases.list":
                let status = peek?.params?.status
                let caseStatus = dismissed.current ? "resolved" : "needs_you"
                guard status == nil || status == caseStatus else {
                    return jsonRPCOK(id: id, result: "[]")
                }
                return jsonRPCOK(id: id, result: "[\(self.soloCaseJSON(status: caseStatus))]")
            case "case.dismiss":
                dismissed.set(true)
                return jsonRPCOK(id: id, result: self.soloCaseJSON(status: "resolved"))
            case "case.restore":
                dismissed.set(false)
                return jsonRPCOK(id: id, result: self.soloCaseJSON(status: "needs_you"))
            case "events.subscribe":
                return jsonRPCOK(id: id, result: "{}")
            default:
                return jsonRPCOK(id: id, result: "{}")
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        let model = AppModel(client: client, environment: isolatedKnockEnvironment())
        model.start()

        try await waitUntil { model.needsYouCases.map(\.id) == ["c_solo"] }

        await model.dismiss(caseId: "c_solo")
        #expect(model.needsYouCases.isEmpty)
        #expect(model.waitingOnAgentCases.isEmpty)
        #expect(model.dismissUndo?.caseId == "c_solo")
        #expect(model.dismissUndo?.title == "Pick a layout")

        await model.undoDismiss()
        try await waitUntil { model.needsYouCases.map(\.id) == ["c_solo"] }
        #expect(model.dismissUndo == nil)

        model.stop()
    }

    @Test @MainActor func dismissClearsTheSelectionWhenTheDismissedCaseWasSelected() async throws {
        let socketPath = makeTempSocketPath()
        let dismissed = DismissedFlag()

        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            let peek = try? JSONDecoder().decode(LinePeek.self, from: line)
            switch method {
            case "cases.list":
                let status = peek?.params?.status
                let caseStatus = dismissed.current ? "resolved" : "needs_you"
                guard status == nil || status == caseStatus else {
                    return jsonRPCOK(id: id, result: "[]")
                }
                return jsonRPCOK(id: id, result: "[\(self.soloCaseJSON(status: caseStatus))]")
            case "cases.get":
                return jsonRPCOK(id: id, result: #"""
                {"case":\#(self.soloCaseJSON(status: "needs_you")),
                 "task":{"id":"t_1","name":"Card pricing","project":"weekend-league"},
                 "messages":[],"revisions":[],"comments":[],"replies":[]}
                """#)
            case "case.dismiss":
                dismissed.set(true)
                return jsonRPCOK(id: id, result: self.soloCaseJSON(status: "resolved"))
            case "events.subscribe":
                return jsonRPCOK(id: id, result: "{}")
            default:
                return jsonRPCOK(id: id, result: "{}")
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        let model = AppModel(client: client, environment: isolatedKnockEnvironment())
        model.start()

        try await waitUntil { model.needsYouCases.map(\.id) == ["c_solo"] }
        await model.open(caseId: "c_solo")
        #expect(model.selectedCaseId == "c_solo")

        await model.dismiss(caseId: "c_solo")
        #expect(model.selectedCaseId == nil)
        #expect(model.selectedCaseDetail == nil)

        model.stop()
    }

    /// HAIL-83: every way an ask opens names its source, and "Go back" on the
    /// toast is one `go_back_clicked`.
    @Test @MainActor func opensNameTheirSourceAndGoBackIsReported() async throws {
        let socketPath = makeTempSocketPath()
        let recorder = UsageRecorder()
        let (model, server) = makeModel(socketPath: socketPath, usage: recorder.reporter)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.needsYouCases.map(\.id) == ["c_new", "c_old"] }

        await model.open(caseId: "c_new", source: .queue)
        model.moveSelection(by: 1)
        try await waitUntil { recorder.events.count == 2 }
        model.advanceAfterSend(answeredCaseId: "c_old", answer: "Compact")
        try await waitUntil { recorder.events.count == 3 }
        model.goBackFromSentToast()
        try await waitUntil { recorder.events.count == 4 }

        #expect(recorder.records == [
            UsageRecord(.caseOpened, source: "queue"),
            UsageRecord(.caseOpened, source: "keyboard"),
            UsageRecord(.caseOpened, source: "auto_advance"),
            UsageRecord(.goBackClicked),
        ])

        model.stop()
    }

    /// Contract "Next ask": answering `c_new` (the newer of the two
    /// `needsYouCases` fixtures, so `c_old` sits below it in list order)
    /// selects `c_old`, shows the pill naming how many are left, and "Go
    /// back" reselects `c_new` and clears the pill.
    @Test @MainActor func advanceAfterSendSelectsTheNextNeedsYouCaseAndGoBackReturnsToTheAnswered() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.needsYouCases.map(\.id) == ["c_new", "c_old"] }

        model.advanceAfterSend(answeredCaseId: "c_new", answer: "Compact")
        #expect(model.sentToast?.answeredCaseId == "c_new")
        #expect(model.sentToast?.answer == "Compact")
        try await waitUntil { model.selectedCaseId == "c_old" }
        let first = model.sentToast?.id

        // A second send replaces the toast (one at a time).
        model.advanceAfterSend(answeredCaseId: "c_old", answer: "Other")
        #expect(model.sentToast?.answeredCaseId == "c_old")
        #expect(model.sentToast?.id != first)
        // A timer for the replaced toast cannot remove the new one.
        model.dismissSentToast(id: first!)
        #expect(model.sentToast?.answeredCaseId == "c_old")

        // Go back returns to the answered ask and clears the toast.
        model.goBackFromSentToast()
        #expect(model.sentToast == nil)
        try await waitUntil { model.selectedCaseId == "c_old" }

        model.stop()
    }

    /// HAIL-84: auto-advance from a text ask lands on the prototype ask in the one-page layout,
    /// and the text ask keeps the text page.
    @Test @MainActor func advanceAfterSendLandsOnTheNextAskInItsOwnLayout() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        model.start()
        try await waitUntil { model.needsYouCases.map(\.id) == ["c_new", "c_old"] }

        model.advanceAfterSend(answeredCaseId: "c_new", answer: "Compact")
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_old" }
        // Every ask is the decision doc now: Return opens the review (comments) of one with an artifact.
        model.activateSelection()
        #expect(model.reviewRequestCaseId == "c_old")
        model.stop()
    }

    /// HAIL-79: the toast's "Change answer" goes back and asks the pane to start the flow.
    @Test @MainActor func changeAnswerRequestsTheAnsweredCaseAndClearsTheToast() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        model.start()
        try await waitUntil { model.needsYouCases.map(\.id) == ["c_new", "c_old"] }

        model.advanceAfterSend(answeredCaseId: "c_new", answer: "Compact")
        model.changeAnswerFromSentToast()
        #expect(model.sentToast == nil)
        #expect(model.changeAnswerRequestCaseId == "c_new")
        try await waitUntil { model.selectedCaseId == "c_new" }
        model.clearChangeAnswerRequest()
        #expect(model.changeAnswerRequestCaseId == nil)
        model.stop()
    }

    /// Contract "All caught up": answering the only `needsYouCases` case
    /// leaves nothing to switch to - the selection clears (rather than
    /// lingering on the now-answered case) so the pane falls through to the
    /// "All caught up" empty state.
    @Test @MainActor func advanceAfterSendClearsTheSelectionWhenItWasTheOnlyNeedsYouCase() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            let peek = try? JSONDecoder().decode(LinePeek.self, from: line)
            switch method {
            case "cases.list":
                let status = peek?.params?.status
                guard status == nil || status == "needs_you" else { return jsonRPCOK(id: id, result: "[]") }
                return jsonRPCOK(id: id, result: "[\(self.soloCaseJSON(status: "needs_you"))]")
            case "events.subscribe":
                return jsonRPCOK(id: id, result: "{}")
            default:
                return jsonRPCOK(id: id, result: "{}")
            }
        }
        try server.start()
        defer { server.stop() }

        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02, 0.02, 0.05])
        let model = AppModel(client: client, environment: isolatedKnockEnvironment())
        model.start()

        try await waitUntil { model.needsYouCases.map(\.id) == ["c_solo"] }

        model.advanceAfterSend(answeredCaseId: "c_solo")
        #expect(model.sentToast?.answeredCaseId == "c_solo")
        #expect(model.selectedCaseId == nil)
        #expect(model.selectedCaseDetail == nil)

        model.stop()
    }

    /// HAIL-47: the queue-sidebar lag the contract fixes was the pane
    /// showing nothing new for a whole `cases.get` round trip -
    /// `refreshCases()`'s own background `enrichMetadata` pass keeps a
    /// `CaseDetail` cached for every row already in the queue, and
    /// `open(caseId:)` must draw from that cache at once, before its own
    /// revalidating fetch has any chance to answer. Proven here by arming
    /// the gate only AFTER the warm-up fetch, then never releasing it until
    /// the assertion already passed - if `open` were still waiting on the
    /// network for its result, this would hang until the test's own
    /// timeout, not pass promptly.
    @Test @MainActor func openDrawsFromTheWarmCacheAtOnceWithoutWaitingForItsOwnRevalidatingFetch() async throws {
        let socketPath = makeTempSocketPath()
        let gate = CaseFetchGate()
        let (model, server) = makeModel(socketPath: socketPath, gate: gate)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }
        // Warm-up: open "c_old" once, ungated, then move on to another case.
        await model.open(caseId: "c_old")
        await model.open(caseId: "c_new")
        #expect(model.selectedCaseDetail?.case.id == "c_new")

        gate.arm(for: "c_old")
        let openTask = Task { await model.open(caseId: "c_old") }
        try await waitUntil(.seconds(10)) { model.selectedCaseDetail?.case.id == "c_old" }
        #expect(model.selectedCaseDetail?.task.id == "t_2")
        #expect(model.selectedCaseDetail?.case.title == "Older, with artifact")

        gate.release()
        await openTask.value
        model.stop()
    }

    /// HAIL-47: a slow fetch for a row the operator already clicked away
    /// from must never win the race and overwrite the pane with the case
    /// they left. Arms the gate BEFORE the warm-up fetch this time, so
    /// `open(caseId: "c_old")` itself is the one left waiting on the
    /// network - then a second `open(caseId: "c_new")` (never gated)
    /// completes first, and only after that does the stale "c_old" fetch
    /// finally resolve.
    @Test @MainActor func aStaleFetchForAnAbandonedSelectionNeverOverwritesThePane() async throws {
        let socketPath = makeTempSocketPath()
        let gate = CaseFetchGate()
        gate.arm(for: "c_old")
        let (model, server) = makeModel(socketPath: socketPath, gate: gate)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }

        let staleOpen = Task { await model.open(caseId: "c_old") }
        try await waitUntil { model.selectedCaseId == "c_old" }

        await model.open(caseId: "c_new")
        #expect(model.selectedCaseId == "c_new")
        #expect(model.selectedCaseDetail?.case.id == "c_new")

        // Let the abandoned "c_old" fetch land now that the pane has moved
        // on. It must not clobber "c_new".
        gate.release()
        await staleOpen.value
        #expect(model.selectedCaseId == "c_new")
        #expect(model.selectedCaseDetail?.case.id == "c_new")

        model.stop()
    }

    /// HAIL-116: auto-select decides in `refreshCases()` but opens in a task. An operator
    /// open that begins in between must win. The pane is emptied, then one refresh runs;
    /// `open` runs its synchronous part inline, before the queued task.
    @Test @MainActor func anOperatorOpenBeforeTheAutoSelectTaskStartsAlwaysWins() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_new" }
        // Back to an empty pane (the fake daemon keeps listing "c_new" as needs_you).
        await model.dismiss(caseId: "c_new")
        #expect(model.selectedCaseId == nil)
        try await model.refreshCases()
        #expect(model.selectedCaseId == nil)
        await model.open(caseId: "c_old")
        #expect(model.selectedCaseId == "c_old")

        // Let the queued auto-select task run, and any fetch it might start.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.selectedCaseId == "c_old")
        #expect(model.selectedCaseDetail?.case.id == "c_old")
        model.stop()
    }

    /// HAIL-116: an auto-select open already in flight (slow fetch) when the operator
    /// opens another case must not replace the pane when its fetch lands.
    @Test @MainActor func aSlowAutoSelectNeverReplacesTheOperatorsOwnSelection() async throws {
        let socketPath = makeTempSocketPath()
        let gate = CaseFetchGate()
        let (model, server) = makeModel(socketPath: socketPath, gate: gate)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_new" }
        await model.dismiss(caseId: "c_new")
        #expect(model.selectedCaseId == nil)
        try await model.refreshCases()
        // Armed after the refresh: its metadata pass is done, so only the auto-select
        // open (queued, not yet started) meets the gate.
        gate.arm(for: "c_new")
        try await waitUntil { model.selectedCaseId == "c_new" }
        await model.open(caseId: "c_old")
        #expect(model.selectedCaseDetail?.case.id == "c_old")

        gate.release()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.selectedCaseId == "c_old")
        #expect(model.selectedCaseDetail?.case.id == "c_old")
        model.stop()
    }

    /// HAIL-118: the pane sits on an answered ask and a new ask arrives. Starts with "c_new"
    /// hidden, so the pane opens "c_old"; the operator then opens the answered "c_waiting".
    @MainActor
    private func modelViewingAnAnsweredAsk(
        hidden: HiddenCaseIds, socketPath: String
    ) async throws -> (AppModel, FakeKnockServer) {
        let (model, server) = makeModel(socketPath: socketPath, hidden: hidden)
        try server.start()
        model.start()
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_old" }
        await model.open(caseId: "c_waiting")
        #expect(model.selectedCaseDetail?.case.id == "c_waiting")
        return (model, server)
    }

    @Test @MainActor func viewingAnAnsweredAskAndANewAskArrivesMovesToTheNewAsk() async throws {
        let hidden = HiddenCaseIds(["c_new"])
        let (model, server) = try await modelViewingAnAnsweredAsk(hidden: hidden, socketPath: makeTempSocketPath())
        defer { server.stop() }
        hidden.set([])
        try await model.refreshCases()
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_new" }
        model.stop()
    }

    @Test @MainActor func viewingAWaitingAskAndAnAskReturnsToNeedsYouMovesToIt() async throws {
        let hidden = HiddenCaseIds()
        let (model, server) = makeModel(socketPath: makeTempSocketPath(), hidden: hidden)
        try server.start()
        defer { server.stop() }
        model.start()
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_new" }
        await model.open(caseId: "c_waiting")
        hidden.set(["c_new", "c_old"])
        try await model.refreshCases()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.selectedCaseDetail?.case.id == "c_waiting")
        hidden.set(["c_old"])
        try await model.refreshCases()
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_new" }
        model.stop()
    }

    @Test @MainActor func viewingAnAnsweredAskWithOlderNeedsYouAsksAndNothingNewStays() async throws {
        let hidden = HiddenCaseIds()
        let (model, server) = makeModel(socketPath: makeTempSocketPath(), hidden: hidden)
        try server.start()
        defer { server.stop() }
        model.start()
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_new" }
        await model.open(caseId: "c_waiting")
        try await model.refreshCases()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.selectedCaseDetail?.case.id == "c_waiting")
        model.stop()
    }

    @Test @MainActor func viewingANeedsYouAskAndANewAskArrivesStays() async throws {
        let hidden = HiddenCaseIds(["c_new"])
        let (model, server) = makeModel(socketPath: makeTempSocketPath(), hidden: hidden)
        try server.start()
        defer { server.stop() }
        model.start()
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_old" }
        hidden.set([])
        try await model.refreshCases()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.selectedCaseDetail?.case.id == "c_old")
        model.stop()
    }

    @Test @MainActor func viewingAnAnsweredAskWithUnsentWorkStaysWhenANewAskArrives() async throws {
        let hidden = HiddenCaseIds(["c_new"])
        let (model, server) = try await modelViewingAnAnsweredAsk(hidden: hidden, socketPath: makeTempSocketPath())
        defer { server.stop() }
        model.registerUnsentWorkProbe(id: UUID()) { true }
        hidden.set([])
        try await model.refreshCases()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.selectedCaseDetail?.case.id == "c_waiting")
        model.stop()
    }

    @Test @MainActor func anOperatorClickRacingTheAutoMoveToANewAskWins() async throws {
        let hidden = HiddenCaseIds(["c_new"])
        let (model, server) = try await modelViewingAnAnsweredAsk(hidden: hidden, socketPath: makeTempSocketPath())
        defer { server.stop() }
        hidden.set([])
        try await model.refreshCases()
        await model.open(caseId: "c_old")
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.selectedCaseId == "c_old")
        #expect(model.selectedCaseDetail?.case.id == "c_old")
        model.stop()
    }

    /// HAIL-59: "Show its requests in the list" narrows both queue groups to one
    /// task, the keyboard order follows, and clearing brings everything back.
    @Test @MainActor func sessionFilterNarrowsTheQueueUntilCleared() async throws {
        let socketPath = makeTempSocketPath()
        let (model, server) = makeModel(socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        model.start()
        try await waitUntil { model.needsYouCases.count == 2 && model.waitingOnAgentCases.count == 1 }
        #expect(model.visibleNeedsYouCases.map(\.id) == ["c_new", "c_old"])

        model.sessionFilter = SessionFilter(taskId: "t_1", label: "knock · main")
        #expect(model.visibleNeedsYouCases.map(\.id) == ["c_new"])
        // "c_new" is a newer ask on the same task, so "c_waiting" sits in
        // the Answered group; the filter keeps it there.
        #expect((model.visibleWaitingCases + model.visibleAnsweredCases).map(\.id) == ["c_waiting"])
        #expect(model.needsYouCases.count == 2, "the filter never drops cases from the model")

        model.sessionFilter = nil
        #expect(model.visibleNeedsYouCases.map(\.id) == ["c_new", "c_old"])
        #expect((model.visibleWaitingCases + model.visibleAnsweredCases).map(\.id) == ["c_waiting"])

        model.stop()
    }
    /// HAIL-153: a new ask in Needs you must show at once, even while an earlier event's refresh is
    /// still fetching case details. The operator saw "Needs you 0" for ~37 s with an ask open: the event
    /// loop waited on `enrichMetadata`, so the `case.created` event of the new ask sat behind it.
    @Test @MainActor func aNewAskShowsInNeedsYouWhileAnEarlierRefreshStillFetchesDetails() async throws {
        let hidden = HiddenCaseIds(["c_new", "c_waiting"])
        let gate = CaseFetchGate()
        let (model, server) = makeModel(socketPath: makeTempSocketPath(), gate: gate, hidden: hidden)
        try server.start()
        defer { server.stop() }
        model.start()
        try await waitUntil { model.needsYouCases.map(\.id) == ["c_old"] }

        // An answered ask comes back in the waiting list; its detail fetch is held open.
        gate.arm(for: "c_waiting")
        hidden.set(["c_new"])
        server.pushEvent(Event(type: .caseUpdated, caseId: "c_waiting", replyId: nil, sessionId: nil, at: "2026-10-03T16:13:57.000Z"))
        try await waitUntil { model.waitingOnAgentCases.map(\.id) == ["c_waiting"] }

        // The same session asks again.
        hidden.set([])
        server.pushEvent(Event(type: .caseCreated, caseId: "c_new", replyId: nil, sessionId: nil, at: "2026-10-03T16:16:09.500Z"))
        try await waitUntil(.seconds(10)) { model.needsYouCases.map(\.id) == ["c_new", "c_old"] }

        gate.release()
        model.stop()
    }

    /// PERF-4: the detail cache holds a few recently opened cases, not every case in the queue.
    @Test @MainActor func theDetailCacheKeepsOnlyTheMostRecentlyOpenedCases() async throws {
        let (model, server) = makeModel(socketPath: makeTempSocketPath())
        try server.start()
        defer { server.stop() }
        model.caseDetailCacheLimit = 2
        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }

        await model.open(caseId: "c_old")
        await model.open(caseId: "c_new")
        await model.open(caseId: "c_waiting")
        #expect(model.cachedDetailCount == 2)
        #expect(model.selectedCaseDetail?.case.id == "c_waiting")
        // The oldest entry was dropped: opening it again still shows its full detail.
        await model.open(caseId: "c_old")
        #expect(model.selectedCaseDetail?.case.title == "Older, with artifact")
        #expect(model.cachedDetailCount == 2)
        model.stop()
    }

    /// WAG-258: a session that ends changes the "Session closed" mark, so one session event re-reads the lists.
    @Test @MainActor func aSessionEventRereadsTheCaseLists() async throws {
        let (model, server) = makeModel(socketPath: makeTempSocketPath())
        try server.start()
        defer { server.stop() }
        let listCalls = LockedCounter()
        let inner = server.onRequest
        server.onRequest = { method, id, line in
            if method == "cases.list" { listCalls.increment() }
            return inner?(method, id, line)
        }
        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }
        let before = listCalls.value
        server.pushEvent(Event(type: .sessionStateChanged, caseId: nil, replyId: nil, sessionId: "s_1", at: "2026-10-07T10:10:00.000Z"))
        try await waitUntil { listCalls.value > before }
        model.stop()
    }

    /// HAIL-153: a burst of events is served by a few refreshes, not one per event, so the event
    /// that carries a new ask is not queued behind dozens of refreshes.
    @Test @MainActor func aBurstOfEventsRunsFewerRefreshesThanEvents() async throws {
        let (model, server) = makeModel(socketPath: makeTempSocketPath())
        try server.start()
        defer { server.stop() }
        let listCalls = LockedCounter()
        let inner = server.onRequest
        server.onRequest = { method, id, line in
            if method == "cases.list" { listCalls.increment() }
            return inner?(method, id, line)
        }
        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }
        let before = listCalls.value
        for n in 0..<30 {
            server.pushEvent(Event(type: .sessionStateChanged, caseId: nil, replyId: nil, sessionId: "s_1", at: "2026-10-03T16:16:\(String(format: "%02d", n)).000Z"))
        }
        try await Task.sleep(for: .milliseconds(800))
        // Each refresh is two `cases.list` calls (needs_you and waiting_on_agent).
        #expect(listCalls.value - before < 2 * 30)
        model.stop()
    }

    /// PERF-5 helpers: counts `cases.get` per case, can fail one case's `cases.get`, and can
    /// mark `c_new`'s title so a test sees which read reached the pane.
    private final class GetLog: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var failing: Set<String> = []
        private var marked = false
        func hit(_ id: String) { lock.lock(); counts[id, default: 0] += 1; lock.unlock() }
        func count(_ id: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[id, default: 0] }
        func setFailing(_ ids: Set<String>) { lock.lock(); failing = ids; lock.unlock() }
        func isFailing(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return failing.contains(id) }
        func setMarked(_ on: Bool) { lock.lock(); marked = on; lock.unlock() }
        var isMarked: Bool { lock.lock(); defer { lock.unlock() }; return marked }
    }

    private func instrument(_ server: FakeKnockServer, _ log: GetLog) {
        let inner = server.onRequest
        server.onRequest = { method, id, line in
            guard method == "cases.get", let id,
                  let caseId = (try? JSONDecoder().decode(LinePeek.self, from: line))?.params?.id else {
                return inner?(method, id, line)
            }
            log.hit(caseId)
            if log.isFailing(caseId) {
                return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"boom"}}"#.utf8)
            }
            guard let out = inner?(method, id, line) else { return nil }
            if caseId == "c_new", log.isMarked, let text = String(data: out, encoding: .utf8) {
                return Data(text.replacingOccurrences(of: #""title":"Newer""#, with: #""title":"Newer v2""#).utf8)
            }
            return out
        }
    }

    /// PERF-5: one failing step in a batch does not skip the rest of the batch.
    @Test @MainActor func aFailingReadInOneEventDoesNotSkipTheRestOfTheBatch() async throws {
        let log = GetLog()
        let (model, server) = makeModel(socketPath: makeTempSocketPath())
        instrument(server, log)
        try server.start()
        defer { server.stop() }
        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }
        // No launch pass reads every case (PERF-4): open c_waiting once so its detail is cached.
        await model.open(caseId: "c_waiting")
        try await waitUntil { log.count("c_waiting") >= 1 }
        await model.open(caseId: "c_new")
        try await waitUntil { model.selectedCaseDetail?.case.id == "c_new" }

        log.setFailing(["c_waiting"])
        log.setMarked(true)
        server.pushEvent(Event(type: .replyStateChanged, caseId: "c_waiting", replyId: "r_1", sessionId: nil, at: "2026-10-04T10:00:00.000Z"))
        server.pushEvent(Event(type: .caseUpdated, caseId: "c_new", replyId: nil, sessionId: nil, at: "2026-10-04T10:00:01.000Z"))
        try await waitUntil { model.selectedCaseDetail?.case.title == "Newer v2" }
        model.stop()
    }

    /// PERF-5: a case no event touched is not read again on open; an event makes the next open read it.
    @Test @MainActor func openingACaseReadsItOnlyWhenAnEventTouchedIt() async throws {
        let log = GetLog()
        let (model, server) = makeModel(socketPath: makeTempSocketPath())
        instrument(server, log)
        try server.start()
        defer { server.stop() }
        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }
        // No launch pass reads every case (PERF-4): one open each warms the cache.
        await model.open(caseId: "c_old")
        await model.open(caseId: "c_new")
        try await waitUntil { log.count("c_old") >= 1 && log.count("c_new") >= 1 }

        let before = log.count("c_old")
        await model.open(caseId: "c_old")
        await model.open(caseId: "c_new")
        await model.open(caseId: "c_old")
        #expect(log.count("c_old") == before)
        #expect(model.selectedCaseDetail?.case.id == "c_old")

        server.pushEvent(Event(type: .caseUpdated, caseId: "c_old", replyId: nil, sessionId: nil, at: "2026-10-04T10:00:00.000Z"))
        // The event lands on its own schedule (slower under full-suite load): open until it has,
        // which proves an event-touched case is read again, without a wall-clock guess.
        let deadline = ContinuousClock.now + .seconds(20)
        while log.count("c_old") == before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            await model.open(caseId: "c_old")
        }
        #expect(log.count("c_old") > before)
        model.stop()
    }

    /// PERF-5: a burst of session events reads no case, and a reply, a new ask and an update all
    /// reach the queue and the open pane.
    @Test @MainActor func sessionEventsReadNoCaseAndCaseEventsStillReachThePane() async throws {
        let log = GetLog()
        let (model, server) = makeModel(socketPath: makeTempSocketPath())
        instrument(server, log)
        try server.start()
        defer { server.stop() }
        model.start()
        try await waitUntil { model.needsYouCases.count == 2 && log.count("c_new") >= 1 }
        await model.open(caseId: "c_new")
        try await Task.sleep(for: .milliseconds(200))

        let before = log.count("c_new") + log.count("c_old") + log.count("c_waiting")
        for n in 0..<10 {
            server.pushEvent(Event(type: .sessionStateChanged, caseId: nil, replyId: nil, sessionId: "s_1", at: "2026-10-04T10:00:0\(n).000Z"))
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(log.count("c_new") + log.count("c_old") + log.count("c_waiting") == before)

        log.setMarked(true)
        server.pushEvent(Event(type: .caseUpdated, caseId: "c_new", replyId: nil, sessionId: nil, at: "2026-10-04T10:01:00.000Z"))
        try await waitUntil { model.selectedCaseDetail?.case.title == "Newer v2" }
        model.stop()
    }

    /// PERF-5: opens that follow each other fast end on the last case opened.
    @Test @MainActor func aFastSequenceOfOpensEndsOnTheLastCase() async throws {
        let log = GetLog()
        let (model, server) = makeModel(socketPath: makeTempSocketPath())
        instrument(server, log)
        try server.start()
        defer { server.stop() }
        model.start()
        try await waitUntil { model.needsYouCases.count == 2 }
        // No launch pass reads every case (PERF-4): one open each warms the cache.
        for id in ["c_waiting", "c_new", "c_old"] { await model.open(caseId: id) }
        try await waitUntil { log.count("c_waiting") >= 1 && log.count("c_new") >= 1 && log.count("c_old") >= 1 }
        for id in ["c_new", "c_old", "c_waiting"] {
            server.pushEvent(Event(type: .caseUpdated, caseId: id, replyId: nil, sessionId: nil, at: "2026-10-04T10:00:00.000Z"))
        }
        try await Task.sleep(for: .milliseconds(400))
        let ids = ["c_new", "c_old", "c_waiting", "c_new", "c_old", "c_waiting", "c_new", "c_old"]
        var tasks: [Task<Void, Never>] = []
        for id in ids {
            tasks.append(Task { await model.open(caseId: id) })
            try await Task.sleep(for: .milliseconds(5))
        }
        for task in tasks { await task.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.selectedCaseId == "c_old")
        #expect(model.selectedCaseDetail?.case.id == "c_old")
        model.stop()
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
