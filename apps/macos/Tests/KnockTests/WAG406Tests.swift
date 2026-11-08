import Foundation
import Testing
@testable import Knock

/// WAG-406: each session row says the project, the folder and the agent; the folder chip has a measured width.
struct WAG406Tests {
    @Test func aWorktreeReadsProjectThenFolder() {
        #expect(ScreenshotRows.place(cwd: "/Users/me/.superset/worktrees/waggle/rumbling-tray-ea96cfab", project: "x") == "waggle \u{00B7} Rumbling tray")
    }

    @Test func aPlainFolderReadsItsName() {
        #expect(ScreenshotRows.place(cwd: "/Users/me/projects/omea", project: "omea") == "omea")
    }

    @Test func noFolderReadsNothing() {
        #expect(ScreenshotRows.place(cwd: "", project: "x") == "")
        #expect(ScreenshotRows.place(cwd: "/", project: "x") == "")
    }

    @Test func theDetailLineNamesTheAgentThenTheState() {
        let row = ScreenshotSessionRow(id: "a", name: "A", dot: .working, stateLine: "Working", canSend: true, agent: "Codex")
        #expect(row.detailLine == "Codex \u{00B7} Working")
        let bare = ScreenshotSessionRow(id: "b", name: "B", dot: .idle, stateLine: "Idle", canSend: true)
        #expect(bare.detailLine == "Idle")
        let app = ScreenshotSessionRow(id: "c", name: "Claude app", dot: .idle, stateLine: "Idle", canSend: false, agent: "Claude app")
        #expect(app.detailLine == "Idle")
    }

    @MainActor @Test func theFolderChipFitsShortNamesAndCapsLongOnes() {
        let short = ScreenshotPanelView.chipWidth("waggle")
        #expect(short > 50 && short < 150)
        #expect(ScreenshotPanelView.chipWidth(String(repeating: "folder-", count: 10)) == 150)
    }
}
