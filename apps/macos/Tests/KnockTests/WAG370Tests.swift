import XCTest
@testable import Knock

/// WAG-370: the answer box of a reply item takes Shift-Return as a new line and grows with its lines.
final class WAG370Tests: XCTestCase {
    func testShiftReturnStartsANewLineAndPlainReturnDoesNothing() {
        XCTAssertEqual(PromptBarLogic.returnKeyAction(shift: true, command: false, hasMarkedText: false, canSend: false), .newline)
        XCTAssertEqual(PromptBarLogic.returnKeyAction(shift: false, command: false, hasMarkedText: false, canSend: false), .ignore)
    }

    func testTheBoxIsTwoLinesWhenEmptyAndGrowsToSix() {
        let two = ReplyItemField.height(text: "", textWidth: 600)
        XCTAssertEqual(two, PromptBarLogic.fieldHeight(totalLines: 2, maxLines: 6))
        XCTAssertEqual(ReplyItemField.height(text: "a\nb\nc\nd", textWidth: 600), PromptBarLogic.fieldHeight(totalLines: 4, maxLines: 6))
        XCTAssertEqual(ReplyItemField.height(text: "a\nb\nc\nd", textWidth: 0), PromptBarLogic.fieldHeight(totalLines: 4, maxLines: 6))
        let nine = String(repeating: "x\n", count: 8) + "x"
        XCTAssertEqual(ReplyItemField.height(text: nine, textWidth: 600), PromptBarLogic.fieldHeight(totalLines: 6, maxLines: 6))
    }

    func testTheReplyItemUsesThePromptTextView() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Knock/AskDoc/QuestionsDocView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("PromptTextView("))
        XCTAssertFalse(source.contains("axis: .vertical"))
    }
}
