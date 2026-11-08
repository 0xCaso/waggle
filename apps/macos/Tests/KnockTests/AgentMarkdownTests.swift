import XCTest
@testable import Knock

final class AgentMarkdownTests: XCTestCase {
    func testParagraphsSplitOnBlankLines() {
        XCTAssertEqual(
            AgentMarkdown.blocks("One\nstill one\n\nTwo"),
            [.paragraph("One still one"), .paragraph("Two")])
    }

    func testBulletsRightAfterAParagraphLine() {
        XCTAssertEqual(
            AgentMarkdown.blocks("Intro:\n- a\n- b"),
            [.paragraph("Intro:"), .bullet(level: 0, text: "a"), .bullet(level: 0, text: "b")])
    }

    func testNestedBulletsOneLevel() {
        XCTAssertEqual(
            AgentMarkdown.blocks("- a\n  - b\n    - c"),
            [.bullet(level: 0, text: "a"), .bullet(level: 1, text: "b"), .bullet(level: 1, text: "c")])
    }

    func testNumberedList() {
        XCTAssertEqual(
            AgentMarkdown.blocks("1. one\n2. two\n3. three"),
            [.numbered(level: 0, index: 1, text: "one"), .numbered(level: 0, index: 2, text: "two"),
             .numbered(level: 0, index: 3, text: "three")])
    }

    func testBoldInsideABullet() {
        let blocks = AgentMarkdown.blocks("- **\"Sign out\"** is for members")
        guard case .bullet(_, let text) = blocks.first else { return XCTFail("no bullet") }
        let inline = AgentMarkdown.inline(text)
        XCTAssertEqual(String(inline.characters), "\"Sign out\" is for members")
        let bold = inline.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertNotNil(bold)
    }

    func testHeadingKeepsTextDropsMarker() {
        XCTAssertEqual(AgentMarkdown.blocks("## Plan"), [.heading("Plan")])
    }

    func testIndentedContinuationJoinsTheItem() {
        XCTAssertEqual(AgentMarkdown.blocks("- a\n  more"), [.bullet(level: 0, text: "a more")])
    }

    func testInlineCode() {
        let inline = AgentMarkdown.inline("run `bun test` now")
        XCTAssertEqual(String(inline.characters), "run bun test now")
        XCTAssertNotNil(inline.runs.first { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    // MARK: No links, no images

    func testLinksRenderAsPlainText() {
        let inline = AgentMarkdown.inline("see [the docs](https://example.com/x) now")
        XCTAssertEqual(String(inline.characters), "see the docs now")
        XCTAssertTrue(inline.runs.allSatisfy { $0.link == nil })
    }

    func testImagesRenderAsPlainText() {
        let inline = AgentMarkdown.inline("![logo](https://example.com/a.png)")
        XCTAssertTrue(inline.runs.allSatisfy { $0.imageURL == nil && $0.link == nil })
    }

    func testAutolinkIsNotALink() {
        let inline = AgentMarkdown.inline("<https://example.com>")
        XCTAssertTrue(inline.runs.allSatisfy { $0.link == nil })
    }

    // MARK: Single line

    func testSingleLineStripsMarkers() {
        XCTAssertEqual(AgentMarkdown.singleLine("**x**"), "x")
        XCTAssertEqual(AgentMarkdown.singleLine("- a\n- **b** and `c`"), "a b and c")
        XCTAssertEqual(AgentMarkdown.singleLine("1. one\n2. two"), "one two")
        XCTAssertEqual(AgentMarkdown.singleLine("# Title\n\nbody"), "Title body")
        XCTAssertEqual(AgentMarkdown.singleLine("a [link](https://x.y) b"), "a link b")
    }

    func testSingleLineLeavesPlainTextAlone() {
        XCTAssertEqual(AgentMarkdown.singleLine("Approve the plan?"), "Approve the plan?")
    }
}

final class AgentMarkdownCopyTests: XCTestCase {
    func testPlainTextStripsMarkersAndKeepsParagraphsAndLists() {
        let text = "**Heads up**: run `bun test` first.\n\nThen:\n- one *fast* item\n- two\n\n1. a\n2. b"
        XCTAssertEqual(
            AgentMarkdown.plainText(text),
            "Heads up: run bun test first.\n\nThen:\n\n- one fast item\n- two\n\n1. a\n2. b")
    }

    func testPlainTextDropsLinkTargets() {
        XCTAssertEqual(AgentMarkdown.plainText("See [the doc](https://example.com) now"), "See the doc now")
    }

    func testPlainTextOfEmptyIsEmpty() {
        XCTAssertEqual(AgentMarkdown.plainText(""), "")
    }

    func testLongCodeSpanGetsCopy() {
        let command = "cd daemon && bun test src/foo.test.ts"
        XCTAssertEqual(AgentMarkdown.copyableCommands("Run `\(command)` and tell me."), [command])
    }

    func testShortCodeSpanGetsNoCopy() {
        XCTAssertEqual(AgentMarkdown.copyableCommands("Use `bun test` here."), [])
    }

    func testSpanExactlyAtTheLimitGetsNoCopy() {
        let span = String(repeating: "a", count: AgentMarkdown.longCodeSpan)
        XCTAssertEqual(AgentMarkdown.copyableCommands("`\(span)`"), [])
        XCTAssertEqual(AgentMarkdown.copyableCommands("`\(span)b`"), [span + "b"])
    }

    func testRepeatedSpansCopyOnce() {
        let command = "swift test --filter AgentMarkdownTests"
        XCTAssertEqual(AgentMarkdown.copyableCommands("`\(command)`\n\n- `\(command)`"), [command])
    }

    func testWholeBodyCommandOffersCopy() {
        XCTAssertEqual(AgentMarkdown.copyableCommands("git log --oneline -5"), ["git log --oneline -5"])
        XCTAssertEqual(AgentMarkdown.copyableCommands("$ bun test"), ["bun test"])
        XCTAssertEqual(AgentMarkdown.copyableCommands("./scripts/bundle-app.sh"), ["./scripts/bundle-app.sh"])
    }

    func testProseIsNotACommand() {
        XCTAssertFalse(AgentMarkdown.looksLikeCommand("Should I run git rebase -i now?"))
        XCTAssertFalse(AgentMarkdown.looksLikeCommand("git is a fine tool."))
        XCTAssertFalse(AgentMarkdown.looksLikeCommand("open the settings page and pick one"))
        XCTAssertFalse(AgentMarkdown.looksLikeCommand("git"))
        XCTAssertFalse(AgentMarkdown.looksLikeCommand("Two paragraphs\n\ngit status -s"))
    }
}
