import Testing
import Foundation
@testable import Knock

struct DaemonLogTests {
    private func tempHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daemonlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("logs"), withIntermediateDirectories: true)
        return dir
    }

    @Test func noLogFileMeansNoViewLogButton() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // The daemon writes only usage.log today: that is not the daemon log.
        FileManager.default.createFile(atPath: home.appendingPathComponent("logs/usage.log").path, contents: Data())
        #expect(DaemonLog.existingURL(environment: ["KNOCK_HOME": home.path]) == nil)
    }

    @Test func anExistingDaemonLogIsFound() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("logs/daemon.log")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        #expect(DaemonLog.existingURL(environment: ["KNOCK_HOME": home.path])?.path == file.path)
    }
}
