import Foundation

/// A small app log, `<data root>/logs/queue.log` (HAIL-120). Today it records a failed case
/// refresh and a queue that shows fewer Needs you asks than the daemon reported, so the next
/// "I see nothing" report leaves evidence. A test or dev copy logs under its own `KNOCK_HOME`.
@MainActor
enum QueueLog {
    static let fileName = "queue.log"

    /// A mismatch the app should log: the daemon reports `daemon` Needs you asks and the queue
    /// draws `rendered` rows. Nil when they agree. Not called while a session filter narrows the queue.
    nonisolated static func mismatchLine(daemon: Int, rendered: Int) -> String? {
        rendered < daemon ? "queueMismatch daemon_needs_you=\(daemon) rendered=\(rendered)" : nil
    }

    /// An event the app handled `lagSeconds` after the daemon made it (HAIL-153). Nil under 3 s.
    nonisolated static func lateEventLine(type: String, caseId: String?, lagSeconds: Double) -> String? {
        lagSeconds >= 3 ? "eventLate type=\(type) case=\(caseId ?? "-") lag_s=\(Int(lagSeconds))" : nil
    }

    /// A new ask that no list holds after the refresh its `case.created` event started (HAIL-153).
    nonisolated static func missingArrivalLine(caseId: String, held: Bool) -> String? {
        held ? nil : "arrivalMissing case=\(caseId) not in needs_you or waiting_on_agent after case.created"
    }

    static func write(
        _ line: String, now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let dir = UpdaterLogDelegate.logDirectory(environment: environment)
        let url = dir.appendingPathComponent(fileName)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(Data("\(ISO8601DateFormatter().string(from: now)) \(line)\n".utf8))
    }
}
