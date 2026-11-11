import Testing
import Foundation
import SwiftUI
@testable import Knock

/// WAG-356: sources on a request. Markers in agent text, the pill model, the list sub-line, decoding and the
/// "no sources" layout rule.
struct SourcesTests {
    static func source(
        _ id: String, kind: String = "file", state: SourceState = .seen, label: String? = nil, note: String? = nil,
        seenAt: String? = nil
    ) -> Source {
        Source(id: id, kind: kind, label: label ?? "label \(id)", note: note, state: state, seenAt: seenAt)
    }

    // MARK: Marker parsing

    @Test func aSingleMarkerIsOneSegment() {
        #expect(SourceMarkers.segments("It is fast. [[s:a]] Next.") == [.text("It is fast."), .marker(["a"]), .text(" Next.")])
    }

    @Test func aGroupedMarkerKeepsItsIdsInOrder() {
        #expect(SourceMarkers.segments("Done.[[s:a,b, c]]") == [.text("Done."), .marker(["a", "b", "c"])])
    }

    @Test func twoMarkersInOneField() {
        let parsed = SourceMarkers.parse("One. [[s:a]] Two. [[s:b,c]]")
        #expect(parsed.groups == [["a"], ["b", "c"]])
        #expect(parsed.text == "One.\u{E000} Two.\u{E000}")
    }

    @Test func aMarkerInsideBoldKeepsTheBold() {
        let parsed = SourceMarkers.parse("**Use the queue [[s:a]]** now")
        let styled = AgentMarkdown.inline(parsed.text)
        let bold = styled.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold != nil)
        #expect(String(styled.characters).contains(SourceMarkers.placeholder))
        #expect(parsed.groups == [["a"]])
    }

    @Test func aMarkerInsideAListItem() {
        let blocks = AgentMarkdown.blocks("- first thing [[s:a]]\n- second thing [[s:b]]", keepingSources: true)
        #expect(blocks == [.bullet(level: 0, text: "first thing [[s:a]]"), .bullet(level: 0, text: "second thing [[s:b]]")])
        #expect(AgentMarkdown.blocks("- first thing [[s:a]]") == [.bullet(level: 0, text: "first thing")])
    }

    @Test func tokensPutAPlaceholderWhereTheMarkerWas() {
        let parsed = SourceMarkers.parse("Alpha beta. [[s:a]] Gamma")
        let tokens = InlineToken.tokens(AttributedString(parsed.text))
        var words: [String] = []
        var markers: [Int] = []
        for token in tokens {
            switch token {
            case .word(let word): words.append(String(word.characters))
            case .marker(let index): markers.append(index)
            }
        }
        #expect(words == ["Alpha", "beta.", "Gamma"])
        #expect(markers == [0])
    }

    @Test func aMarkerCutOffAtTheEndIsGone() {
        #expect(SourceMarkers.strip("Half a marker [[s:a") == "Half a marker")
        #expect(!SourceMarkers.strip("Half a marker [[s:a,").contains("[[s:"))
    }

    @Test func restoreGivesTheMarkersBack() {
        let parsed = SourceMarkers.parse("A. [[s:x,y]] B.")
        #expect(SourceMarkers.restore(parsed.text, groups: parsed.groups) == "A.[[s:x,y]] B.")
    }

    // MARK: Stripping in the one-line places

    @Test func singleLineRemovesEveryMarker() {
        #expect(AgentMarkdown.singleLine("Ship it. [[s:a]] Then test. [[s:b,c]]") == "Ship it. Then test.")
        #expect(AgentMarkdown.singleLine("- **Ship it [[s:a]]**\n- test [[s:b]]") == "Ship it test")
    }

    @Test func singleLineCanKeepTheMarkersForTheRequestPage() {
        let kept = AgentMarkdown.singleLine("Ship it. [[s:a]] Then.", keepingSources: true)
        #expect(kept == "Ship it.[[s:a]] Then.")
        #expect(AgentMarkdown.singleLine(kept) == "Ship it. Then.")
    }

    @Test func plainTextAndBlocksAndInlineRemoveMarkers() {
        #expect(!AgentMarkdown.plainText("Text [[s:a]]\n\n- item [[s:b]]").contains("[[s:"))
        #expect(!String(AgentMarkdown.inline("Bold **x [[s:a]]**").characters).contains("[[s:"))
        #expect(AgentMarkdown.blocks("Para [[s:a]]") == [.paragraph("Para")])
    }

    @Test func titlesAndNotesCarryNoRawMarker() {
        let option = Option(id: "o", label: "Use the queue [[s:a]] because it is simple", title: nil)
        #expect(!option.displayTitle.contains("[[s:"))
        let titled = Option(id: "o2", label: "x", title: "Queue [[s:a]]")
        #expect(titled.displayTitle == "Queue")
        let note = CalmOption.note(for: option, isRecommended: true, recommendationWhy: "Simple. [[s:a]]")
        #expect(note == "Simple.[[s:a]]")
        #expect(AgentMarkdown.singleLine(note ?? "") == "Simple.")
    }

    @Test func theNeedSplitKeepsMarkersOutOfThePlainNeed() {
        #expect(!NeedText.split("Which one? [[s:a]]\n\nDetails [[s:b]]").question.isEmpty)
        #expect(!AgentMarkdown.singleLine("Which one? [[s:a]]").contains("[[s:"))
    }

    // MARK: Pill model

    @Test func aMarkerWithAnUnknownIdMakesNoPill() {
        let book = SourceBook(sources: [Self.source("a")])
        #expect(book.pill(ids: ["zzz"]) == nil)
        #expect(book.pill(ids: []) == nil)
    }

    @Test func aGroupedPillShowsTheFirstSourceAndPlusN() throws {
        let book = SourceBook(sources: [Self.source("a", kind: "test"), Self.source("b"), Self.source("c")])
        let pill = try #require(book.pill(ids: ["a", "b", "c"]))
        #expect(pill.label == "label a")
        #expect(pill.kind == .test)
        #expect(pill.extraText == "+2")
        #expect(try #require(book.pill(ids: ["a"])).extraText == nil)
        // An id that is unknown does not count in the +N, and the same id twice counts once.
        #expect(try #require(book.pill(ids: ["b", "nope", "b", "c"])).extraText == "+1")
    }

    @Test func anUnknownKindUsesTheFileIcon() {
        let odd = Self.source("a", kind: "hologram")
        #expect(odd.kind == nil)
        #expect(odd.drawnKind == .file)
        #expect(SourcesTheme.pillSymbol(for: odd) == SourceKind.file.symbol)
        #expect(Source(id: "n", kind: nil).drawnKind == .file)
    }

    @Test func everyKindHasASymbolAndAName() {
        #expect(SourceKind.allCases.count == 16)
        for kind in SourceKind.allCases {
            #expect(!kind.symbol.isEmpty)
            #expect(!kind.title.isEmpty)
        }
        #expect(SourceKind.youSaid.title == "You said")
        #expect(SourceKind.database.title == "Database query")
    }

    @Test func eachStateHasItsLook() {
        let seen = SourcesTheme.pillLook(state: .seen, selected: false)
        let stated = SourcesTheme.pillLook(state: .stated, selected: false)
        let assumption = SourcesTheme.pillLook(state: .assumption, selected: false)
        let selected = SourcesTheme.pillLook(state: .seen, selected: true)
        #expect(seen.fill == Theme.Colors.side)
        #expect(stated.fill == .white)
        #expect(seen.stroke == Theme.Colors.line && stated.stroke == Theme.Colors.line)
        #expect(assumption.fill == Theme.Colors.honeySoft)
        #expect(assumption.stroke == Theme.Colors.honey500)
        #expect(assumption.label == SourcesTheme.assumptionInk)
        #expect(selected.fill == Theme.Colors.ink && selected.stroke == Theme.Colors.ink)
        #expect(selected.label == Theme.Colors.onFill && selected.icon == Theme.Colors.onFill)
        // An assumption draws the dashed circle, whatever its kind.
        #expect(SourcesTheme.pillSymbol(for: Self.source("a", kind: "web", state: .assumption)) == "circle.dashed")
        #expect(SourcesTheme.pillSymbol(for: Self.source("a", kind: "web", state: .seen)) == SourceKind.web.symbol)
    }

    @Test func theButtonShowsTheFirstThreeDistinctKinds() {
        let book = SourceBook(sources: [
            Self.source("a", kind: "file"), Self.source("b", kind: "file"), Self.source("c", kind: "web"),
            Self.source("d", kind: "test"), Self.source("e", kind: "rule"),
        ])
        #expect(book.dotKinds == [.file, .web, .test])
        #expect(book.buttonText == "Sources · 5")
    }

    @Test func aRepeatedIdKeepsTheFirstSource() {
        let book = SourceBook(sources: [Self.source("a", label: "first"), Self.source("a", label: "second")])
        #expect(book.sources.count == 1)
        #expect(book.source(id: "a")?.label == "first")
    }

    // MARK: Sub-line, when line

    @Test func theSubLineCountsTheStates() {
        let sources =
            (0..<5).map { Self.source("s\($0)", state: .seen) } + [Self.source("t", state: .stated), Self.source("u", state: .assumption)]
        #expect(SourceBook(sources: sources).summary == "7 sources · 5 seen by Waggle · 1 stated by the agent · 1 not checked")
    }

    @Test func theSubLineLeavesOutAPartWithNoCount() {
        #expect(SourceBook(sources: [Self.source("a", state: .seen), Self.source("b", state: .seen)]).summary == "2 sources · 2 seen by Waggle")
        #expect(SourceBook(sources: [Self.source("a", state: .stated)]).summary == "1 source · 1 stated by the agent")
        #expect(SourceBook(sources: [Self.source("a", state: .assumption), Self.source("b", state: .seen)]).summary
            == "2 sources · 1 seen by Waggle · 1 not checked")
    }

    @Test func theWhenLineReadsFromTheState() {
        let asked = KnockDateFormat.parse("2026-10-10T10:03:00Z")
        let book = SourceBook(sources: [], askedAt: asked)
        #expect(book.whenLine(for: Self.source("a", state: .seen, seenAt: "2026-10-10T10:00:00Z"))
            == "Ran in this session, 3 min before the request")
        #expect(book.whenLine(for: Self.source("a", state: .stated)) == "Waggle found no matching call in the session")
        #expect(book.whenLine(for: Self.source("a", state: .assumption)) == "The agent did not check this")
        #expect(book.whenLine(for: Self.source("a", state: .seen)) == "Ran in this session")
        #expect(SourceBook.stateWord(.seen) == "Seen by Waggle")
        #expect(SourceBook.stateWord(.stated) == "Stated by the agent")
        #expect(SourceBook.stateWord(.assumption) == "Not checked")
    }

    @Test func theSpanUsesMinutesHoursAndDays() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        #expect(SourceBook.span(from: base.addingTimeInterval(-20), to: base) == "just before")
        #expect(SourceBook.span(from: base.addingTimeInterval(-180), to: base) == "3 min before")
        #expect(SourceBook.span(from: base.addingTimeInterval(-7200), to: base) == "2 h before")
        #expect(SourceBook.span(from: base.addingTimeInterval(-3 * 86400), to: base) == "3 days before")
        #expect(SourceBook.span(from: base.addingTimeInterval(120), to: base) == "2 min after")
    }

    // MARK: Decoding

    static func roundJSON(sources: Any?) -> Data {
        var json: [String: Any] = ["seq": 0, "question": "Q", "items": [], "created_at": "2026-10-10T10:00:00Z"]
        if let sources { json["sources"] = sources }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test func aRoundWithoutSourcesDecodesAsBefore() throws {
        let round = try JSONDecoder().decode(Round.self, from: Self.roundJSON(sources: nil))
        #expect(round.sources.isEmpty)
        #expect(round.sourceBook.isEmpty)
    }

    @Test func aRoundWithSourcesDecodesEveryField() throws {
        let raw: [[String: Any]] = [[
            "id": "s1", "kind": "file", "label": "daemon/src/queue.ts", "note": "Where it is built.", "excerpt": "const q = 1",
            "ref": ["path": "daemon/src/queue.ts", "line": 40, "case_id": "c_1"], "state": "seen", "seen_at": "2026-10-10T09:57:00Z",
        ]]
        let round = try JSONDecoder().decode(Round.self, from: Self.roundJSON(sources: raw))
        let source = try #require(round.sources.first)
        #expect(source.id == "s1" && source.kind == .file && source.state == .seen)
        #expect(source.note == "Where it is built." && source.excerpt == "const q = 1")
        #expect(source.ref?.path == "daemon/src/queue.ts" && source.ref?.line == 40 && source.ref?.caseId == "c_1")
        #expect(source.seenAt == "2026-10-10T09:57:00Z")
        #expect(round.sourceBook.askedAt == KnockDateFormat.parse("2026-10-10T10:00:00Z"))
    }

    @Test func unknownFieldsKindsAndStatesDoNotFailTheDecode() throws {
        let raw: [[String: Any]] = [
            ["id": "a", "kind": "hologram", "label": "X", "state": "dreamed", "future_field": [1, 2]],
            ["label": "no id: dropped"],
            ["id": "b"],
            ["id": "c", "kind": 7, "label": 3, "ref": "not an object", "state": 9],
        ]
        let round = try JSONDecoder().decode(Round.self, from: Self.roundJSON(sources: raw))
        #expect(round.sources.map(\.id) == ["a", "b", "c"])
        #expect(round.sources[0].kind == nil && round.sources[0].state == .stated)
        #expect(round.sources[1].label == "" && round.sources[1].state == .stated)
        #expect(round.sources[2].ref == nil)
    }

    @Test func sourcesThatIsNotAListIsIgnored() throws {
        let round = try JSONDecoder().decode(Round.self, from: Self.roundJSON(sources: "nope"))
        #expect(round.sources.isEmpty)
    }

    // MARK: Layout rule

    @Test func aRoundWithNoSourcesHasNoButton() {
        #expect(!SourcesLayout.showsButton(nil))
        #expect(!SourcesLayout.showsButton(.empty))
        #expect(SourcesLayout.showsButton(SourceBook(sources: [Self.source("a")])))
    }

    @Test func withNoSourcesAMarkerIsJustGone() {
        // No pill can resolve, so the text takes the plain path: the same text as a round with no markers.
        #expect(SourceBook.empty.parsedWithPills("Fast. [[s:a]]") == nil)
        #expect(SourceBook(sources: [Self.source("a")]).parsedWithPills("Fast. [[s:zzz]]") == nil)
        #expect(SourceBook(sources: [Self.source("a")]).parsedWithPills("Fast. [[s:a]]") != nil)
    }

    // MARK: Card place and the hub

    @Test func theCardOpensEightPointsUnderThePillWithLeftEdgesAligned() {
        let origin = SourcesCardPlace.origin(
            anchor: CGRect(x: 100, y: 200, width: 80, height: 20), card: CGSize(width: 340, height: 200), host: CGSize(width: 900, height: 700))
        #expect(origin == CGPoint(x: 100, y: 228))
    }

    @Test func theCardStaysInsideTheWindow() {
        let host = CGSize(width: 500, height: 400)
        let right = SourcesCardPlace.origin(
            anchor: CGRect(x: 450, y: 50, width: 40, height: 20), card: CGSize(width: 340, height: 100), host: host)
        #expect(right.x == 152, "\(right)")
        let low = SourcesCardPlace.origin(
            anchor: CGRect(x: 10, y: 350, width: 40, height: 20), card: CGSize(width: 340, height: 100), host: host)
        #expect(low.y == 242, "\(low)")
    }

    @MainActor @Test func aClickPinsTheCardAndTheSamePillClosesIt() {
        let hub = SourcesHub(book: SourceBook(sources: [Self.source("a"), Self.source("b")]))
        hub.report(key: "p1", rect: CGRect(x: 10, y: 10, width: 50, height: 20))
        hub.report(key: "p2", rect: CGRect(x: 100, y: 10, width: 50, height: 20))
        hub.tap(key: "p1", ids: ["a"])
        #expect(hub.shown?.ids == ["a"] && hub.isPinned(key: "p1"))
        // One card at a time: a click on another pill moves the pin.
        hub.tap(key: "p2", ids: ["b"])
        #expect(hub.shown?.ids == ["b"] && !hub.isPinned(key: "p1"))
        hub.tap(key: "p2", ids: ["b"])
        #expect(hub.shown == nil)
    }

    @MainActor @Test func aClickOutsideOrEscapeClosesThePinnedCard() {
        let hub = SourcesHub(book: SourceBook(sources: [Self.source("a")]))
        hub.hostSize = CGSize(width: 1000, height: 700)
        hub.report(key: "p1", rect: CGRect(x: 10, y: 10, width: 50, height: 20))
        hub.cardRect = CGRect(x: 10, y: 38, width: 340, height: 150)
        hub.tap(key: "p1", ids: ["a"])
        hub.clickedOutside(at: CGPoint(x: 20, y: 100))
        #expect(hub.pinned != nil, "a click inside the card keeps it")
        hub.clickedOutside(at: CGPoint(x: 20, y: 15))
        #expect(hub.pinned != nil, "a click on the pill is the pill's own")
        hub.clickedOutside(at: CGPoint(x: 700, y: 500))
        #expect(hub.pinned == nil)
        hub.tap(key: "p1", ids: ["a"])
        #expect(hub.dismissTopmost())
        #expect(hub.shown == nil)
        #expect(!hub.dismissTopmost())
    }

    @MainActor @Test func theListOpensWithTheSourceOpenAndClosesOnEscapeOrAClickOutside() {
        let hub = SourcesHub(book: SourceBook(sources: [Self.source("a"), Self.source("b")]))
        hub.hostSize = CGSize(width: 1000, height: 700)
        hub.openList(selecting: "b")
        #expect(hub.isListOpen && hub.openRowId == "b" && hub.isOpen)
        // One row open at a time.
        hub.toggleRow("a")
        #expect(hub.openRowId == "a")
        hub.toggleRow("a")
        #expect(hub.openRowId == nil)
        hub.clickedOutside(at: CGPoint(x: 900, y: 300))
        #expect(hub.isListOpen, "a click in the list keeps it")
        hub.clickedOutside(at: CGPoint(x: 300, y: 300))
        #expect(!hub.isListOpen)
        hub.openList()
        #expect(hub.dismissTopmost())
        #expect(!hub.isListOpen)
    }

    @MainActor @Test func openingTheListClosesTheCard() {
        let hub = SourcesHub(book: SourceBook(sources: [Self.source("a")]))
        hub.report(key: "p1", rect: .zero)
        hub.tap(key: "p1", ids: ["a"])
        hub.openList(selecting: "a")
        #expect(hub.pinned == nil && hub.isListOpen)
    }

    @MainActor @Test func aNewRoundWithoutTheSourceClosesItsCard() {
        let hub = SourcesHub(book: SourceBook(sources: [Self.source("a")]))
        hub.report(key: "p1", rect: .zero)
        hub.tap(key: "p1", ids: ["a"])
        hub.update(book: .empty)
        #expect(hub.shown == nil)
        #expect(!hub.isListOpen)
    }

    // MARK: Web link (WAG-407)

    @Test func linkAcceptsHttpAndHttpsWithAHost() {
        #expect(SourceLink("https://github.com/limone/waggle/pull/1")?.host == "github.com")
        #expect(SourceLink("http://example.org")?.host == "example.org")
        #expect(SourceLink("HTTPS://Docs.Example.com/a?b=c#d")?.url.absoluteString == "HTTPS://Docs.Example.com/a?b=c#d")
    }

    @Test func linkRefusesOtherSchemesAndBadInput() {
        for raw in [
            "file:///etc/passwd", "javascript:alert(1)", "slack://channel?id=1", "mailto:a@b.c", "ftp://example.com",
            "https://", "https:///path", "/just/a/path", "github.com", "https://user:pw@example.com",
            "https://user@example.com", "", "   ", "https://exa mple.com", "not a url", "http://",
        ] {
            #expect(SourceLink(raw) == nil, "should refuse \(raw)")
        }
        #expect(SourceLink(nil) == nil)
    }
}
