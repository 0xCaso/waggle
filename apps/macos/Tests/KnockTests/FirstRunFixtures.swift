import Foundation
@testable import Knock

/// Sessions and asks for the first-run tests (WAG-338). Everything is a plain value: nothing starts or sends.
enum FirstRun {
    static let now = KnockDateFormat.date(from: "2026-10-09T12:00:00.000Z")!

    static func session(
        _ id: String, project: String, cwd: String? = nil, runtime: Runtime = .claude, state: SessionState = .live,
        canNudge: Bool = true, title: String? = nil, seen: String = "2026-10-09T11:00:00.000Z",
        started: String = "2026-10-09T09:12:00.000Z", context: SessionContext? = nil
    ) -> SessionInfo {
        SessionInfo(
            id: id, runtime: runtime, taskName: "task-\(id)", project: project, branch: nil,
            cwd: cwd ?? "/Users/me/\(project)", canNudge: canNudge, state: state, connectedAt: started,
            lastSeenAt: seen, context: context, sessionTitle: title)
    }

    static func ask(
        _ id: String, project: String = "acme-support", title: String = "An ask", status: CaseStatus = .needsYou,
        at: String = "2026-10-09T11:30:00.000Z", replyId: String? = nil, intent: ReplyIntent? = nil,
        seq: Int = 0, roundQuestion: String? = nil
    ) -> Case {
        Case(
            id: id, taskId: "t_\(id)", kind: .question, title: title, need: "Need", why: "Why",
            recommendation: "a", recommendationWhy: "Because",
            options: [Option(id: "a", label: "Option A", title: "A"), Option(id: "b", label: "Option B", title: "B")],
            status: status, hasArtifact: true, latestReplyId: replyId, latestReplyIntent: intent,
            project: project, createdAt: at, updatedAt: at, optionsSeq: seq, roundQuestion: roundQuestion)
    }
}
