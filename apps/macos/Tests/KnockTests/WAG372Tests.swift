import AppKit
import XCTest
@testable import Knock

/// WAG-372: right-click on a screenshot offers Copy Image and Save Image….
final class WAG372Tests: XCTestCase {
    private func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 4, height: 3))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 3).fill()
        image.unlockFocus()
        return image
    }

    func testCopyPutsTheImageOnThePasteboard() {
        let board = NSPasteboard(name: NSPasteboard.Name("wag372-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(ImageActions.copy(image(), to: board))
        XCTAssertTrue(board.canReadObject(forClasses: [NSImage.self], options: nil))
    }

    func testSaveWritesAPNG() throws {
        let data = try XCTUnwrap(ImageActions.pngData(image()))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testFileName() {
        XCTAssertEqual(ImageActions.fileName(nil), "Screenshot.png")
        XCTAssertEqual(ImageActions.fileName("  "), "Screenshot.png")
        XCTAssertEqual(ImageActions.fileName("Home/v2"), "Home v2.png")
        XCTAssertEqual(ImageActions.fileName("shot.PNG"), "shot.PNG")
    }

    func testEveryLargeScreenshotViewHasTheMenu() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Review/ScreenshotStageView.swift", "Review/Comments/CommentCaptureStageView.swift",
                     "Review/Comments/ScreenshotSetViews.swift", "Review/ArtifactViewerView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/Knock/" + path), encoding: .utf8)
            XCTAssertTrue(source.contains(".imageContextMenu("), path)
        }
    }
}
