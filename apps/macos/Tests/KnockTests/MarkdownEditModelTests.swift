import Foundation
import Testing
@testable import Knock

/// HAIL-168: editing a markdown explanation in place. The person edits the rendered text; the
/// markdown that comes back keeps headings, bold, italics, lists and code, and carries no syntax the
/// person typed.
struct MarkdownEditModelTests {
    private let doc = """
    # Cache plan

    We cache for **ten** minutes, *never* longer, and `ttl` stays fixed.

    - first item
    - second item

    1. step one
    2. step two

    ```
    let a = 1
    ```
    """

    /// The range of `needle` in the displayed text.
    private func range(of needle: String, in model: MarkdownEditModel) -> Range<Int> {
        let text = String(decoding: model.displayText, as: UTF16.self) as NSString
        let r = text.range(of: needle)
        precondition(r.location != NSNotFound, "\(needle) not found")
        return r.location..<(r.location + r.length)
    }

    private func edited(_ source: String, _ needle: String, to replacement: String) -> String {
        var model = MarkdownEditModel(markdown: source)
        _ = model.replace(range(of: needle, in: model), with: replacement)
        return model.markdown()
    }

    @Test func anUntouchedDocumentComesBackExactly() {
        let model = MarkdownEditModel(markdown: doc)
        #expect(model.markdown() == doc)
        #expect(!model.hasChanges)
    }

    @Test func aWordInsideBoldKeepsTheBold() {
        let out = edited(doc, "ten", to: "five")
        #expect(out.contains("We cache for **five** minutes"))
        // Untouched blocks keep their source text.
        #expect(out.contains("- first item\n- second item"))
        #expect(out.contains("```\nlet a = 1\n```"))
    }

    @Test func aWordInsideItalicsKeepsTheItalics() {
        let out = edited(doc, "never", to: "rarely")
        #expect(out.contains("_rarely_") || out.contains("*rarely*"))
        #expect(out.contains("**ten**"))
    }

    @Test func inlineCodeKeepsItsLook() {
        let out = edited(doc, "ttl", to: "max_age")
        #expect(out.contains("`max_age`"))
    }

    @Test func aHeadingStaysAHeading() {
        let out = edited(doc, "Cache plan", to: "Cache rules")
        #expect(out.hasPrefix("# Cache rules\n"))
    }

    @Test func listItemsKeepTheirMarkers() {
        let out = edited(doc, "second item", to: "last item")
        #expect(out.contains("- first item\n- last item"))
        let ordered = edited(doc, "step two", to: "step three")
        #expect(ordered.contains("1. step one\n2. step three"))
    }

    @Test func aCodeBlockStaysRawText() {
        let out = edited(doc, "a = 1", to: "b = *2*")
        #expect(out.contains("```\nlet b = *2*\n```"))
    }

    @Test func removedTextShowsAsRemovedAndAddedTextAsAdded() {
        var model = MarkdownEditModel(markdown: doc)
        _ = model.replace(range(of: "ten", in: model), with: "five")
        let states = model.units.map(\.state)
        #expect(states.filter { $0 == .deleted }.count == 3)
        #expect(states.filter { $0 == .added }.count == 4)
        let shown = String(decoding: model.displayText, as: UTF16.self)
        #expect(shown.contains("tenfive"), "the removed word stays on screen next to the added one")
        #expect(model.hasChanges)
    }

    @Test func deletingAddedTextRemovesItAndEverythingBackIsUnchanged() {
        var model = MarkdownEditModel(markdown: doc)
        let at = range(of: "second", in: model).lowerBound
        _ = model.replace(at..<at, with: "XY")
        _ = model.replace(at..<(at + 2), with: "")
        #expect(model.units.allSatisfy { $0.state == .kept })
        #expect(!model.hasChanges)
    }

    @Test func returnInAParagraphStartsANewParagraph() {
        var model = MarkdownEditModel(markdown: "One two three.\n")
        let at = range(of: " two", in: model).lowerBound
        _ = model.replace(at..<at, with: "\n")
        let out = model.markdown()
        #expect(out.hasPrefix("One\n\n"))
        #expect(out.contains("two three."))
    }

    @Test func returnInAListItemStartsANewItem() {
        var model = MarkdownEditModel(markdown: "- alpha beta\n- gamma\n")
        let at = range(of: " beta", in: model).lowerBound
        _ = model.replace(at..<at, with: "\n")
        #expect(model.markdown() == "- alpha\n- beta\n- gamma\n")
    }

    @Test func aParagraphDeletedWholeLeavesNoLine() {
        var model = MarkdownEditModel(markdown: "Keep this.\n\nDrop this.\n\nAnd this.\n")
        _ = model.replace(range(of: "Drop this.", in: model), with: "")
        let out = model.markdown()
        #expect(!out.contains("Drop"))
        #expect(out.contains("Keep this."))
        #expect(out.contains("And this."))
    }

    @Test func typedMarkdownNeverBecomesLinksImagesOrHTML() {
        let typed = "[click](https://evil.example) ![pic](https://evil.example/x.png) <b>bold</b> **x** `y` # z"
        let out = edited("Hello world.\n", "world", to: typed)
        let parsed = RenderedMarkdown.parse(out)
        #expect(parsed.links.isEmpty)
        #expect(parsed.string.contains(typed), "the typed characters show as plain text")
        #expect(!parsed.styles.contains { $0.contains(.bold) || $0.contains(.code) })
        #expect(!out.contains("<b>") || out.contains("\\<b"))
    }

    @Test func aTypedLineStartCannotMakeAHeadingOrList() {
        var model = MarkdownEditModel(markdown: "Plain text.\n")
        let start = range(of: "Plain", in: model)
        _ = model.replace(start, with: "# Big")
        let parsed = RenderedMarkdown.parse(model.markdown())
        #expect(parsed.blocks.first?.kind == .paragraph)
        _ = model
        let dash = edited("Plain text.\n", "Plain text.", to: "- not a list")
        #expect(RenderedMarkdown.parse(dash).blocks.first?.kind == .paragraph)
        let numbered = edited("Plain text.\n", "Plain text.", to: "1. not a list")
        #expect(RenderedMarkdown.parse(numbered).blocks.first?.kind == .paragraph)
    }

    @Test func theRenderedTextAfterAnEditIsTheEditedText() {
        let out = edited(doc, "ten", to: "five")
        let parsed = RenderedMarkdown.parse(out).string
        #expect(parsed.contains("We cache for five minutes, never longer"))
    }

    @Test func bulletsAndBlockEndsCannotBeDeleted() {
        var model = MarkdownEditModel(markdown: "- alpha\n- beta\n")
        let bullet = 0..<1
        let result = model.replace(bullet, with: "")
        #expect(result == nil)
        #expect(!model.hasChanges)
    }

    @Test func aTableCellTakesNoLineBreak() {
        var model = MarkdownEditModel(markdown: "| a | b |\n|---|---|\n| c | d |\n")
        let at = range(of: "c", in: model).upperBound
        let result = model.replace(at..<at, with: "\n")
        #expect(result == nil)
        let out = edited("| a | b |\n|---|---|\n| c | d |\n", "d", to: "dd | x")
        #expect(out.contains("| c | dd  x |"))
        #expect(RenderedMarkdown.parse(out).blocks.count == 4)
    }

    @Test func undoAndRedoStepThroughEdits() {
        var model = MarkdownEditModel(markdown: "Hello world.\n")
        _ = model.replace(range(of: "world", in: model), with: "there")
        #expect(model.hasChanges)
        let undone = model.undo()
        #expect(undone)
        #expect(!model.hasChanges)
        let redone = model.redo()
        #expect(redone)
        #expect(model.markdown().contains("there"))
    }

    @Test func compareDrawsTheEditOverTheOldVersion() {
        let model = MarkdownEditModel.comparison(
            from: "We cache for **ten** minutes.\n", to: "We cache for **five** minutes.\n")
        #expect(model.units.contains { $0.state == .deleted })
        #expect(model.units.contains { $0.state == .added })
        #expect(!model.canUndo)
    }
}
