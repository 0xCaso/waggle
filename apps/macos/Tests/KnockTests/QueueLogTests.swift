import Testing
import Foundation
@testable import Knock

/// HAIL-120: the queue's self-check line and where it is written.
@MainActor
struct QueueLogTests {
    @Test func aQueueThatShowsFewerAsksThanTheDaemonReportedIsLogged() {
        #expect(QueueLog.mismatchLine(daemon: 3, rendered: 2) == "queueMismatch daemon_needs_you=3 rendered=2")
        #expect(QueueLog.mismatchLine(daemon: 0, rendered: 0) == nil)
        #expect(QueueLog.mismatchLine(daemon: 2, rendered: 2) == nil)
    }

    @Test func linesAreAppendedUnderTheDataRootLogsFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("knock_qlog_\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let env = ["KNOCK_HOME": home]
        QueueLog.write("one", now: Date(timeIntervalSince1970: 0), environment: env)
        QueueLog.write("two", now: Date(timeIntervalSince1970: 60), environment: env)

        let text = try String(contentsOfFile: home + "/logs/queue.log", encoding: .utf8)
        #expect(text == "1970-01-01T00:00:00Z one\n1970-01-01T00:01:00Z two\n")
    }

    @Test func aLateEventAndAMissingArrivalLeaveALine() {
        #expect(QueueLog.lateEventLine(type: "case.created", caseId: "c_1", lagSeconds: 2) == nil)
        #expect(QueueLog.lateEventLine(type: "case.created", caseId: "c_1", lagSeconds: 37.4) == "eventLate type=case.created case=c_1 lag_s=37")
        #expect(QueueLog.missingArrivalLine(caseId: "c_1", held: true) == nil)
        #expect(QueueLog.missingArrivalLine(caseId: "c_1", held: false)?.hasPrefix("arrivalMissing case=c_1") == true)
    }
}
