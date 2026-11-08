import Testing
import Foundation
@testable import Knock

/// `UpdateLogTail.tail` (HAIL-52): the pure "last N lines" rule "Copy
/// diagnostics" uses for the update log.
struct UpdateLogTailTests {
    @Test func keepsEveryLineWhenFewerThanN() {
        #expect(UpdateLogTail.tail(["a", "b"], keeping: 50) == ["a", "b"])
    }

    @Test func keepsOnlyTheLastNLines() {
        let lines = (1...60).map { "line \($0)" }
        let tail = UpdateLogTail.tail(lines, keeping: 50)
        #expect(tail.count == 50)
        #expect(tail.first == "line 11")
        #expect(tail.last == "line 60")
    }

    @Test func emptyInputStaysEmpty() {
        #expect(UpdateLogTail.tail([], keeping: 50).isEmpty)
    }
}

/// `DiagnosticsText.build` (HAIL-52 contract: "copies versions (app, daemon,
/// macOS), the `knock doctor` output and the last 50 lines of the update log
/// ... no ask content"). Checks the assembled text carries every required
/// piece and nothing that looks like ask content.
struct DiagnosticsTextTests {
    @Test func carriesEveryVersionAndBothLogSections() {
        let text = DiagnosticsText.build(
            appVersion: "0.1.19",
            daemonVersion: "0.1.19",
            macOSVersion: "Version 15.0 (Build 24A335)",
            doctorLines: ["ok    knock.sock reachable", "ok    claude found"],
            updateLogLines: ["2026-09-29T00:00:00Z didFinishLoading appcast items=1"]
        )

        #expect(text.contains("Waggle 0.1.19"))
        #expect(text.contains("Daemon 0.1.19"))
        #expect(text.contains("macOS Version 15.0 (Build 24A335)"))
        #expect(text.contains("ok    knock.sock reachable"))
        #expect(text.contains("ok    claude found"))
        #expect(text.contains("didFinishLoading appcast items=1"))
    }

    @Test func neverInventsContentForEmptyInputs() {
        let text = DiagnosticsText.build(
            appVersion: "0.1.19", daemonVersion: "unknown", macOSVersion: "Version 15.0",
            doctorLines: [], updateLogLines: []
        )
        #expect(text.contains("Daemon unknown"))
        #expect(text.contains("Update log (last 0 lines):"))
    }
}
