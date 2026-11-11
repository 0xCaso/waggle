import AppKit
import SwiftUI
import Testing
@testable import Knock

/// Status render colors: a dark page to show the failed line's dark pair on.
enum StatusRenderColors {
    static let darkPage = Color(nsColor: StatusLineColors.srgb(0x1E1E1E))
}

/// Evidence only: `KNOCK_RENDER_DIR=<folder> swift test --filter RequestPageRenderTests` draws the request page of
/// a few cases offscreen into PNGs in that folder (C1, one layout). Without the variable each test does nothing. The
/// pane has no daemon here, so an artifact's own content does not load; the layout around it does.
@MainActor
@Suite(.serialized)
struct RequestPageRenderTests {
    private var folder: URL? {
        let folder = ProcessInfo.processInfo.environment["KNOCK_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        // The renders draw in the bundled Inter Tight and JetBrains Mono, as the app does, not the system fallback.
        if folder != nil { FontRegistration.registerBundledFonts() }
        return folder
    }

    private func connectedModel() -> AppModel {
        let model = AppModel(
            client: KnockClient(socketPath: "/tmp/knock-nonexistent-\(UUID().uuidString).sock"), environment: isolatedKnockEnvironment(),
            bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier)
        model.setConnectionStateForTests(.connected)
        return model
    }

    private let options = [
        Option(id: "a", label: "Calm: the smallest change", title: "A · Calm",
               pros: ["Smallest change"], cons: ["Composer stays a separate band", "Two copies"], effects: ["Pane only"]),
        Option(id: "b", label: "Options in place: the options are the page", title: "B · Options in place",
               pros: ["The decision is in the first screen", "One list"], cons: ["Larger change to the Swift layout"]),
        Option(id: "c", label: "Focus: one request at a time", title: "C · Focus (stretch)",
               pros: ["One request at a time"], cons: ["The biggest change", "New navigation"]),
        Option(id: "d", label: "Keep today's page", title: "D · Keep today", pros: [], cons: ["Nothing improves"]),
    ]

    private func makeCase(
        hasArtifact: Bool, questions: [Question] = [], kind: Case.Kind = .question, options custom: [Option]? = nil,
        select: Case.Select = .one, max: Int? = nil, id: String = "c1", recommendation: String? = nil
    ) -> Case {
        let options = custom ?? self.options
        return Case(
            id: id, taskId: "t1", kind: kind, title: "Which direction for the request page?",
            need: "Pick one of three directions for the request page. All three show the table correctly and use the app tokens. "
                + String(repeating: "The page shows less at once, and all of today's functions stay. ", count: 3),
            why: "This changes the main screen that all users see.", recommendation: recommendation ?? (questions.isEmpty ? "b" : ""),
            recommendationWhy: "It removes the duplicate options and puts the decision in the first screen.",
            options: questions.isEmpty ? options : [], status: .needsYou, hasArtifact: hasArtifact,
            select: select, max: max, recommendations: select == .many ? ["a", "b"] : nil,
            createdAt: "2026-11-09T10:00:00Z", updatedAt: "2026-11-09T10:00:00Z", questions: questions)
    }

    private func detail(_ item: Case, planRounds: [PlanRound]? = nil) -> CaseDetail {
        let revisions = item.hasArtifact
            ? [Revision(id: "r1", caseId: item.id, n: 1, createdAt: "2026-11-09T10:00:00Z", author: .agent, baseRevision: nil,
                        name: "Request page mockups", kind: .markdown)]
            : []
        return CaseDetail(
            case: item, task: KnockTask(id: "t1", name: "Request page UI cleanup", project: "waggle"),
            messages: [], revisions: revisions, comments: [], replies: [], planRounds: planRounds)
    }

    private func render(
        _ name: String, _ item: Case, width: CGFloat, height: CGFloat, planRounds: [PlanRound]? = nil,
        fullDetail: CaseDetail? = nil, model given: AppModel? = nil
    ) throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = given ?? connectedModel()
        let view = CasePaneDetailView(model: model, detail: fullDetail ?? detail(item, planRounds: planRounds))
            .frame(width: width, height: height)
            .background(Theme.Colors.win)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }

    /// Draws any view offscreen into `<name>.png` (the option rows alone, tasks 5). `scale` 2 matches the mockup shots.
    private func renderView<V: View>(_ name: String, width: CGFloat, height: CGFloat, scale: CGFloat = 1, _ content: V) throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: content.frame(width: width, height: height, alignment: .topLeading)
            .background(Theme.Colors.win).environment(\.colorScheme, .light))
        let window = (scale == 1 ? NSWindow.self : RetinaRenderWindow.self).init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let rep = try #require(
            scale == 1
                ? host.bitmapImageRepForCachingDisplay(in: host.bounds)
                : NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale), bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }

    /// The option cards of the decision column (decision 2026-11-10) as the case map mockup's template `shots`
    /// draws them: A closed with its first pro, first con and "+N", B picked and open, C closed. Then a narrow
    /// column with a lean and a long title, and a pick-several list (template `multi`). Drawn at 2x, as the shots.
    @Test func optionRows() throws {
        guard folder != nil else { return }
        FontRegistration.registerBundledFonts()
        let cards = [
            Option(id: "a", label: "A · Calm", title: "A · Calm",
                   pros: ["Smallest change", "No new parts"], cons: ["Composer stays a separate band", "Two copies"], effects: ["Pane only"]),
            Option(id: "b", label: "The options are the page. You select, read the pros and cons, and send in one place.",
                   title: "B · Options in place",
                   pros: ["The decision is in the first screen", "First pro and con, not counts"],
                   cons: ["Larger change to the Swift layout", "Long need text behind a link"]),
            Option(id: "c", label: "C · Focus (stretch)", title: "C · Focus (stretch)",
                   pros: ["One request at a time", "Calm"], cons: ["The biggest change", "New navigation"]),
        ]
        func list(selected: String?, leanOn: String? = nil, extra: Option? = nil) -> some View {
            let all = cards + (extra.map { [$0] } ?? [])
            let open = CalmOption.openPosition(
                selected: all.firstIndex { $0.id == selected }.map { $0 + 1 }, recommended: 2, isCheckbox: false)
            return VStack(alignment: .leading, spacing: CalmOption.rowGap) {
                OptionListLabel().padding(.bottom, OptionCardStyle.labelGap - CalmOption.rowGap)
                ForEach(Array(all.enumerated()), id: \.element.id) { index, option in
                    CalmOptionRowView(
                        option: option, position: index + 1, isSelected: option.id == selected, isRecommended: option.id == "b",
                        recommendationWhy: "it removes the duplicate options and puts the decision in the first screen.",
                        isLeaning: option.id == leanOn, isRuledOut: option.id == "c" && leanOn != nil,
                        onLean: {}, onRuleOut: {}, isOpen: open == index + 1, onSelect: {})
                }
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 18))
        }
        try renderView("12-cards-shots-440", width: 440, height: 400, scale: 2, list(selected: "b"))
        try renderView("13-cards-no-pick-440", width: 440, height: 400, scale: 2, list(selected: nil))
        let long = Option(id: "e", label: "E", title: "E · Keep the dock and the cards in the page, and add a third copy",
                          pros: ["None"], cons: ["Three copies"])
        try renderView("14-cards-narrow-lean-330", width: 330, height: 520, scale: 2, list(selected: "b", leanOn: "a", extra: long))
        let many = ["Order ahead", "Fresh batch alerts", "Bake planner", "Allergen list", "Gift cards"]
        let multi = VStack(alignment: .leading, spacing: CalmOption.rowGap) {
            PickSeveralHeaderView(count: 2, max: 4, isAtLimit: false, canTickRecommended: true, onTickRecommended: {}, onClear: {})
                .padding(.bottom, OptionCardStyle.labelGap - CalmOption.rowGap)
            ForEach(Array(many.enumerated()), id: \.offset) { index, title in
                CompactOptionRow(
                    position: index + 1, title: title, isSelected: index == 0 || index == 2, isRecommended: index < 4 && index != 1,
                    onLean: {}, onRuleOut: {}, isCheckbox: true, onSelect: {})
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 18))
        try renderView("14b-cards-multi-440", width: 440, height: 320, scale: 2, multi)
    }

    /// Task 11d: the decision column as variant `gist` of `design/mockups/2026-11-10-option-text/` draws it, at 440 pt and
    /// 2x, with the mockup's sample data: a new ask (facts and gists) and an old ask (strings only, no facts).
    @Test func gistCards() throws {
        guard folder != nil else { return }
        FontRegistration.registerBundledFonts()
        let fix = Option(
            id: "fix", label: "Fix the harness, then run 10 more cycles on the shared repo state.", title: "Fix the harness, run 10 more",
            facts: ["USD 40", "½ day", "10 cycles"],
            proPoints: [OptionPoint(gist: "Removes repo noise", detail: "Removes the noise from the shared repo state, so every cycle starts clean"),
                        OptionPoint(gist: "Ten cycles of proof", detail: "Ten cycles give a result that is not chance"), "Same harness for later tests"],
            conPoints: [OptionPoint(gist: "v0.4 waits a week", detail: "The v0.4 release waits about a week for the result"),
                        OptionPoint(gist: "About USD 40", detail: "About USD 40 and half a day of work"), "Needs the harness fix first"])
        let stop = Option(
            id: "stop", label: "Stop testing and ship v0.4 today.", title: "Stop testing, ship v0.4", facts: ["USD 0", "today", "5 cycles"],
            proPoints: ["No more cost", "Ships today", "No harness work"],
            conPoints: [OptionPoint(gist: "4 to 1 can be chance", detail: "Only 5 cycles: 4 to 1 can still be chance"), "No test of the new rule", "Old noise stays"])
        let ship = Option(
            id: "ship", label: "Ship `v0.4` first, then test 5 old and 5 new cycles.", title: "Ship v0.4, then test it",
            effects: ["Opens the v0.4 release branch"], facts: ["USD 40", "½ day", "10 cycles"],
            proPoints: [OptionPoint(gist: "One run checks both", detail: "One test run checks the new eviction rule and the cache together"),
                        OptionPoint(gist: "Same cost as option 1", detail: "Same cost as option 1: about USD 40"),
                        OptionPoint(gist: "Fix ships this week", detail: "The fix in `evict.ts` ships this week")],
            conPoints: [OptionPoint(gist: "Ships before its own test", detail: "The release goes out before its own test, so a bad result comes late"),
                        OptionPoint(gist: "A fail means `v0.4.1`", detail: "If the test fails, we must ship `v0.4.1` with a fix"),
                        OptionPoint(gist: "Needs the harness fix", detail: "It still needs the harness fix before the run")])
        let why = "one run does both jobs."
        func column(_ cards: [Option], open: String, title: String, need: String, whyYou: String) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).knockTextStyle(Theme.AskDoc.Column.title).foregroundColor(Theme.Colors.ink)
                    .padding(.bottom, Theme.AskDoc.Column.titleGap)
                NeedCalloutView(need: need, why: whyYou).padding(.bottom, Theme.AskDoc.Column.needGap)
                VStack(alignment: .leading, spacing: CalmOption.rowGap) {
                    OptionListLabel().padding(.bottom, OptionCardStyle.labelGap - CalmOption.rowGap)
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, option in
                        CalmOptionRowView(
                            option: option, position: index + 1, isSelected: option.id == open, isRecommended: option.id == open,
                            recommendationWhy: why, onLean: {}, onRuleOut: {}, isOpen: option.id == open, onSelect: {})
                    }
                }
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 18))
        }
        let need = "Cache B beat cache A in 4 of 5 cycles, with 5 wrong claims against 11. Pick the next step.\n\n"
            + "`~/.bench/cache/run-1108/summary.md` Spent USD 18.40 `--max-turns 15`"
        let whyYou = "the next step costs money and sets the release date."
        try renderView("50-gist-new-ask-440", width: 440, height: 640, scale: 2,
            column([fix, stop, ship], open: "ship", title: "Cache test: B won 4 of 5. What next?", need: need, whyYou: whyYou))
        // An old ask: the same options as strings only, no facts.
        let old = [fix, stop, ship].map { o in
            Option(id: o.id, label: o.label, title: o.title, pros: o.pros, cons: o.cons, effects: o.effects)
        }
        try renderView("51-gist-old-ask-440", width: 440, height: 760, scale: 2,
            column(old, open: "ship", title: "Cache test: B won 4 of 5. What next?", need: need,
                   whyYou: whyYou + " Only you know how much the release date can move this month, and who waits for it."))
        // The steps frame's cards: two facts each, one con.
        let thumb = Option(id: "t", label: "Thumbnail beside the title", facts: ["photo 64 pt", "card +0 pt"],
                           proPoints: ["The card stays short and calm"], conPoints: ["In the winter photos the plates are too small", "The text moves right"])
        let stretch = Option(id: "s", label: "Instead of the header (stretch)", facts: ["photo 320 pt", "header hides"],
                             proPoints: ["The largest photos"], conPoints: ["The header goes away when you point at a card"])
        let full = Option(id: "f", label: "Full width above the steps", facts: ["photo 400 pt", "card +240 pt"],
                          proPoints: [OptionPoint(gist: "Seen when the card opens", detail: "You see the dish as soon as you open the card"),
                                      OptionPoint(gist: "Plating easy to see", detail: "The plating is easy to see at 400 pt")],
                          conPoints: [OptionPoint(gist: "Longer card on a phone", detail: "The card gets long: on a phone the ingredients move below the fold")])
        let cards = VStack(alignment: .leading, spacing: CalmOption.rowGap) {
            OptionListLabel().padding(.bottom, OptionCardStyle.labelGap - CalmOption.rowGap)
            ForEach(Array([thumb, stretch, full].enumerated()), id: \.element.id) { index, option in
                CalmOptionRowView(
                    option: option, position: index + 1, isSelected: option.id == "f", isRecommended: option.id == "f",
                    recommendationWhy: "the dish is easy to see, the header stays.", onLean: {}, onRuleOut: {},
                    isOpen: option.id == "f", onSelect: {})
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 18))
        try renderView("52-gist-steps-cards-440", width: 440, height: 360, scale: 2, cards)
        // The whole pane (the commentable need text: code and path chips, bold numbers, "Why you" on one line).
        let paneCase = Case(
            id: "gist-\(UUID().uuidString.prefix(6))", taskId: "t1", kind: .question, title: "Cache test: B won 4 of 5. What next?",
            need: need, why: whyYou + " Only you know how far the release date can move this month.", recommendation: "ship",
            recommendationWhy: why, options: [fix, stop, ship], status: .needsYou, hasArtifact: false,
            createdAt: "2026-11-10T10:00:00Z", updatedAt: "2026-11-10T10:00:00Z")
        try render("54-gist-pane-1000x980", paneCase, width: 1000, height: 980)
        // An old ask in the pane: closed cards with long first points must not widen the column.
        let longOld = old.map { o in
            Option(id: o.id, label: o.label, title: o.title,
                   pros: ["You see the rhythm of the work: two in 2023, four in 2024, one in 2025"] + o.pros,
                   cons: ["You cannot see when the hackathons occurred in the year, only how many"] + o.cons, effects: o.effects)
        }
        let oldCase = Case(
            id: "gist-old-\(UUID().uuidString.prefix(6))", taskId: "t1", kind: .question, title: "Cache test: B won 4 of 5. What next?",
            need: need, why: whyYou, recommendation: "stop",
            recommendationWhy: why, options: longOld, status: .needsYou, hasArtifact: false,
            createdAt: "2026-11-10T10:00:00Z", updatedAt: "2026-11-10T10:00:00Z")
        try render("55-gist-old-pane-1000x980", oldCase, width: 1000, height: 980)
        // Pros and cons that wrap in a narrow column: each line keeps its own room (no line drawn over the next).
        let wrap = Option(
            id: "w", label: "One page per work, with a timeline", title: "One page per work",
            proPoints: ["Same movement as Percorso", "One proof for each work, and you select it", "The timeline stays on top"],
            conPoints: ["Longer to build than a list of links", "The photos must be cut again for the new size"])
        let wrapCards = VStack(alignment: .leading, spacing: CalmOption.rowGap) {
            CalmOptionRowView(
                option: wrap, position: 1, isSelected: true, isRecommended: true,
                recommendationWhy: "each work gets its own proof.", onLean: {}, onRuleOut: {}, isOpen: true, onSelect: {})
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 10, trailing: 18))
        try renderView("56-gist-wrapping-points-360", width: 360, height: 420, scale: 2, wrapCards)
        try renderView("57-gist-wrapping-points-440", width: 440, height: 380, scale: 2, wrapCards)
        // "Show the full points" open.
        setenv("KNOCK_EVIDENCE_FULL_POINTS", "1", 1)
        defer { unsetenv("KNOCK_EVIDENCE_FULL_POINTS") }
        try renderView("53-gist-full-points-440", width: 440, height: 820, scale: 2,
            column([fix, stop, ship], open: "ship", title: "Cache test: B won 4 of 5. What next?", need: need, whyYou: whyYou))
    }

    /// The need box with a table (decision 2026-11-10): the lead sentence and the details folded behind "▸ Show …",
    /// then the details open, with the table as mockup B draws it (outer line, 10 pt corners, grey header, numbers right).
    @Test func needTable() throws {
        guard folder != nil else { return }
        let need = """
            Which ideas do we keep for the next step?

            | Idea | Use | Cost | Proof |
            |---|---|---|---|
            | Order ahead | High | $1,200 | Morning queue survey |
            | Fresh batch alerts | High | $400 | — |
            | Allergen list | Medium | $150 | Questions asked at the till |

            Now I recommend "Order ahead" for customers and the bake planner for the staff.
            """
        try renderView("40-need-table-folded-404", width: 404, height: 200,
            NeedCalloutView(need: need, why: "This choice sets the scope of the project."))
        let parts = NeedText.split(need)
        let open = VStack(alignment: .leading, spacing: 7) {
            AgentMarkdownText(text: parts.question, style: Theme.AskDoc.Column.needQuestion, color: Theme.Colors.ink, weight: .semibold)
            AgentMarkdownText(text: parts.details ?? "", style: Theme.AskDoc.Column.need, color: Theme.Colors.ink)
        }
        .environment(\.askParagraphGap, Theme.AskDoc.Column.needParagraphGap)
        .padding(Theme.AskDoc.Column.needPadding)
        .background(Theme.Colors.needFill)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        try renderView("41-need-table-open-swiftui-404", width: 404, height: 300, open)
        // The commentable (AppKit) path draws the same table with `AskTableCellBlock`.
        let content = AskTextContent.build(
            text: parts.details ?? "", mode: .blocks,
            face: AskTextFace(style: Theme.AskDoc.Column.need, color: Theme.Colors.ink), book: nil, showsPills: false)
        try renderView("42-need-table-open-appkit-404", width: 404, height: 260, AttributedTextBox(text: content.attributed))
    }

    /// An update with options (spec section 3 item 4): the first options folded, then open in their own fold.
    @Test func updateWithFirstOptions() throws {
        guard folder != nil else { return }
        let first = [
            Option(id: "x", label: "Two columns, as today", title: "X · Two columns", pros: ["Known"], cons: ["Two copies"]),
            Option(id: "y", label: "One column with tabs", title: "Y · One column", pros: ["Simple"], cons: []),
        ]
        let item = Case(
            id: "c1", taskId: "t1", kind: .question, title: "Which direction for the request page?",
            need: "I changed the options after your comments.", why: "This changes the main screen.", recommendation: "b",
            recommendationWhy: "It removes the duplicate options.", options: options, status: .needsYou, hasArtifact: false,
            createdAt: "2026-11-09T10:00:00Z", updatedAt: "2026-11-09T10:30:00Z",
            firstOptions: first, firstRecommendation: "x", optionsUpdatedAt: "2026-11-09T10:30:00Z")
        try render("15-update-first-folded-1000x760", item, width: 1000, height: 760)
        setenv("KNOCK_EVIDENCE_SHOW_FIRST_OPTIONS", "1", 1)
        defer { unsetenv("KNOCK_EVIDENCE_SHOW_FIRST_OPTIONS") }
        try render("16-update-first-open-1000x900", item, width: 1000, height: 900)
    }

    /// "Ask for…" (C5): closed in the send row (every other render), and open on a short window: the panel scrolls in
    /// the column, the send row stays pinned.
    @Test func askForPanel() throws {
        guard folder != nil else { return }
        setenv("KNOCK_PANE_ASK_FOR_DETAIL", "1", 1)
        defer { unsetenv("KNOCK_PANE_ASK_FOR_DETAIL") }
        try render("17-ask-for-open-short-1000x560", makeCase(hasArtifact: false), width: 1000, height: 560)
        try render("18-ask-for-open-artifact-1300x760", makeCase(hasArtifact: true), width: 1300, height: 760)
        try render("19-ask-for-open-reply-only-1000x560", makeCase(hasArtifact: false, options: []), width: 1000, height: 560)
        let questions = [
            Question(id: "q1", title: "Which layout?", now: nil, points: [
                QuestionPoint(id: "p1", text: "Layout?", options: ["One column", "Two columns", "Keep today"])],
                artifactRef: nil, variants: nil, variantLabel: nil),
            Question(id: "q2", title: "Which tabs?", now: nil, points: [
                QuestionPoint(id: "p2", text: "Tabs?", options: ["Three tabs", "Two tabs"])],
                artifactRef: nil, variants: nil, variantLabel: nil),
        ]
        try render("20-ask-for-open-stepped-1300x600", makeCase(hasArtifact: true, questions: questions), width: 1300, height: 600)
    }

    @Test func textOnly() throws {
        try render("1-text-only-1200x860", makeCase(hasArtifact: false), width: 1200, height: 860)
    }

    @Test func oneArtifact() throws {
        try render("2-artifact-1300x860", makeCase(hasArtifact: true), width: 1300, height: 860)
    }

    @Test func narrowPane() throws {
        try render("3-narrow-pane-800x860", makeCase(hasArtifact: true), width: 800, height: 860)
    }

    @Test func shortWindow() throws {
        try render("4-short-window-1300x700", makeCase(hasArtifact: true), width: 1300, height: 700)
        try render("5-short-text-only-1000x560", makeCase(hasArtifact: false), width: 1000, height: 560)
    }

    @Test func steppedAsk() throws {
        let questions = [
            Question(id: "q1", title: "Which layout?", now: nil, points: [
                QuestionPoint(id: "p1", text: "Layout?", options: ["One column", "Two columns", "Keep today"])],
                artifactRef: nil, variants: nil, variantLabel: nil),
            Question(id: "q2", title: "Which tabs?", now: nil, points: [
                QuestionPoint(id: "p2", text: "Tabs?", options: ["Three tabs", "Two tabs"])],
                artifactRef: nil, variants: nil, variantLabel: nil),
        ]
        try render("6-stepped-1300x760", makeCase(hasArtifact: true, questions: questions), width: 1300, height: 760)
    }

    /// One option picked (the `shots` mockup frame): Send reads "Send: B · Options in place ↵" under the field.
    @Test func onePicked() throws {
        let run = UUID().uuidString.prefix(6)
        setenv("KNOCK_EVIDENCE_PICK_OPTION", "b", 1)
        defer { unsetenv("KNOCK_EVIDENCE_PICK_OPTION") }
        try render("2b-artifact-one-picked-1300x860", makeCase(hasArtifact: true, id: "pick-\(run)"), width: 1300, height: 860)
    }

    @Test func review() throws {
        let options = [Option(id: "approve", label: "Approve"), Option(id: "changes", label: "Request changes")]
        try render("7-review-1300x760", makeCase(hasArtifact: true, kind: .review, options: options), width: 1300, height: 760)
    }

    /// Reply only (spec section 9): no options, the suggested reply above the field, "Use this reply" in the send row
    /// while the field is empty.
    @Test func replyOnly() throws {
        let suggestion = "Keep the column at 440 pt, and let it narrow to 340 pt in full size."
        let run = UUID().uuidString.prefix(6)
        try render("8-reply-only-1100x700", makeCase(
            hasArtifact: false, options: [], id: "reply-\(run)", recommendation: suggestion), width: 1100, height: 700)
        try render("8b-reply-only-artifact-1300x760", makeCase(
            hasArtifact: true, options: [], id: "reply-art-\(run)", recommendation: suggestion), width: 1300, height: 760)
    }

    /// Pick several (spec section 9): the header, and Send reads "Decide: N picked" once options are ticked.
    @Test func pickSeveral() throws {
        let run = UUID().uuidString.prefix(6)
        try render("9-pick-several-1100x760", makeCase(hasArtifact: false, select: .many, max: 2, id: "many-\(run)"), width: 1100, height: 760)
        setenv("KNOCK_EVIDENCE_TICK", "a,c", 1)
        defer { unsetenv("KNOCK_EVIDENCE_TICK") }
        try render("9b-pick-several-two-picked-1100x760", makeCase(
            hasArtifact: false, select: .many, max: 2, id: "many-picked-\(run)"), width: 1100, height: 760)
    }

    /// A plan follow-up (the `plan` mockup frame): follows an answered ask, plan stage Approaches after an answered
    /// Questions round, three stepped questions with a group title.
    @Test func planFollowUp() throws {
        let earlier = Case(
            id: "c0", taskId: "t1", kind: .question, title: "Which direction for the request page?", need: "", why: "",
            recommendation: "b", recommendationWhy: "", options: options, status: .resolved, hasArtifact: false,
            latestReplyId: "r0", latestReplyChoice: "b",
            latestReplyMessage: "B is very good, but we must be careful about the many cases where Waggle shows artifacts, "
                + "screenshots and plans. Check each case before you change the page.",
            createdAt: "2026-11-09T09:00:00Z", updatedAt: "2026-11-09T09:30:00Z")
        FollowedCaseCache.shared.store(earlier)
        func step(_ id: String, _ title: String) -> Question {
            var q = Question(id: id, title: title, now: nil, points: [
                QuestionPoint(id: "p\(id)", text: title, options: ["Yes, in the guide and in the UI", "Only in the UI"])],
                artifactRef: nil, variants: nil, variantLabel: nil)
            q.groupTitle = "Base rules for the request page"
            return q
        }
        let questions = [
            step("q1", "Where does the decision sit on the page?"),
            step("q2", "How do we show the options once?"),
            step("q3", "Do we also limit how much text the agent writes?"),
        ]
        let item = Case(
            id: "c1", taskId: "t1", kind: .question, title: "Plan: one layout for every request page",
            need: "Pick the base rules for the new request page. The case map lists 15 cases, and these three rules apply to all of them.",
            why: "these rules change what users see in every case.", recommendation: "", recommendationWhy: "",
            options: [], status: .needsYou, hasArtifact: true, followsCaseId: "c0",
            createdAt: "2026-11-09T10:00:00Z", updatedAt: "2026-11-09T10:00:00Z",
            plan: PlanInfo(stage: PlanStage(name: .approaches, step: 1, total: 3), rounds: 2, answered: 1),
            questions: questions)
        let rounds = [
            PlanRound(seq: 1, stage: PlanStage(name: .questions), question: "Who reads the request page first?",
                      options: [Option(id: "x", label: "The person who answers")], recommendation: "x",
                      createdAt: "2026-11-09T09:40:00Z", revision: 1, answer: PlanAnswer(choice: "x", createdAt: "2026-11-09T09:45:00Z")),
            PlanRound(seq: 2, stage: PlanStage(name: .approaches, step: 1, total: 3), question: "Base rules",
                      options: [], recommendation: "", createdAt: "2026-11-09T10:00:00Z", revision: 1),
        ]
        try render("10-plan-follow-up-1300x860", item, width: 1300, height: 860, planRounds: rounds)
        try render("11-plan-follow-up-narrow-900x860", item, width: 900, height: 860, planRounds: rounds)
    }

    // MARK: Tasks 7 and 8: tabs, Conversation, Comments

    private func iso(_ hhmm: String) -> String { "2026-11-09T\(hhmm):00Z" }

    /// A request with a thread: the ask, your answer, two progress notes, a long agent update that brought v2.
    private func conversationDetail(id: String, hasArtifact: Bool = true) -> CaseDetail {
        var item = makeCase(hasArtifact: hasArtifact)
        item = Case(
            id: id, taskId: "t1", kind: .question, title: item.title, need: item.need, why: item.why,
            recommendation: "b", recommendationWhy: item.recommendationWhy, options: options, status: .needsYou,
            hasArtifact: hasArtifact, createdAt: iso("10:00"), updatedAt: iso("10:40"))
        let long = """
            **You are right about delivery.** A delivery app is not needed: the big delivery apps already do it. \
            What is left is a simple order-ahead page for the shop.

            **The loyalty card is less useful than I said.** Most customers come once a week or less.

            **Now I recommend:** "Order ahead" for the customers and the bake planner for the staff. \
            I changed the table in v2: the rows for delivery and the loyalty card moved down, and the evidence column \
            names its sources. Two rows still say `guess` where I found nothing.

            I also checked the three sources you asked about. The survey data is from 2024; the sales data is \
            from 2025. Both are sample data. The last one is a blog post, so I marked it as weaker evidence.
            """
        let reply = Reply(
            id: "r1", caseId: id, idempotencyKey: "r1", choice: "b",
            message: "How useful is the loyalty card really? Delivery could help too, but the delivery apps already do it.",
            comments: [], captures: [], intent: .decision, state: .delivered, createdAt: iso("10:20"), deliveredAt: iso("10:21"))
        let revisions = hasArtifact
            ? [Revision(id: "v1", caseId: id, n: 1, createdAt: iso("10:00"), author: .agent, baseRevision: nil, name: "Ideas", kind: .markdown),
               Revision(id: "v2", caseId: id, n: 2, createdAt: iso("10:40"), author: .agent, baseRevision: nil, name: "Ideas", kind: .markdown)]
            : []
        return CaseDetail(
            case: item, task: KnockTask(id: "t1", name: "Sample project", project: "demo"),
            messages: [
                Message(id: "m1", caseId: id, role: .agent, text: "Reading the three sources you named.", createdAt: iso("10:25"), working: true),
                Message(id: "m2", caseId: id, role: .agent, text: "Rebuilding the table with the new order.", createdAt: iso("10:32"), working: true),
                Message(id: "m3", caseId: id, role: .agent, text: long, createdAt: iso("10:40")),
            ],
            revisions: revisions, comments: [], replies: [reply])
    }

    /// The Conversation tab in the pane (several entries, each in full), and the Decision tab with the
    /// latest-message line and the dot on Conversation.
    @Test func conversationTab() throws {
        guard folder != nil else { return }
        let run = UUID().uuidString.prefix(6)
        let decision = conversationDetail(id: "conv-dot-\(run)")
        try render("21-decision-latest-line-dot-1300x860", decision.case, width: 1300, height: 860, fullDetail: decision)
        setenv("KNOCK_PANE_TAB", "conversation", 1)
        defer { unsetenv("KNOCK_PANE_TAB") }
        let open = conversationDetail(id: "conv-open-\(run)")
        try render("22-conversation-tab-1300x860", open.case, width: 1300, height: 860, fullDetail: open)
        let text = conversationDetail(id: "conv-text-\(run)", hasArtifact: false)
        try render("23-conversation-tab-text-only-1000x860", text.case, width: 1000, height: 860, fullDetail: text)
    }

    /// The Comments tab with 3 comments, in the pane and in the full size column.
    @Test func commentsTab() throws {
        guard folder != nil else { return }
        let model = connectedModel()
        let id = "comments-\(UUID().uuidString.prefix(6))"
        let item = Case(
            id: id, taskId: "t1", kind: .question, title: "Which direction for the request page?",
            need: "Pick one of three directions.", why: "It changes the main screen.", recommendation: "b",
            recommendationWhy: "It removes the duplicate options.", options: options, status: .needsYou, hasArtifact: false,
            createdAt: iso("10:00"), updatedAt: iso("10:00"))
        let store = model.commentsStore(forCase: id)
        for (n, text) in [
            "This option should say what happens to the dock.",
            "The table fix must stay: rows were cut before.",
            "Keep Lean and Rule out visible when there is room.",
        ].enumerated() {
            _ = store.addTextComment(anchor: TextAnchor(revision: 1, quote: "quote \(n)", start: n * 10, end: n * 10 + 5), text: text)
        }
        let detail = CaseDetail(
            case: item, task: KnockTask(id: "t1", name: "Request page UI cleanup", project: "waggle"),
            messages: [], revisions: [], comments: [], replies: [])
        setenv("KNOCK_PANE_TAB", "comments", 1)
        defer { unsetenv("KNOCK_PANE_TAB") }
        try render("24-comments-tab-pane-1000x760", item, width: 1000, height: 760, fullDetail: detail, model: model)
        unsetenv("KNOCK_PANE_TAB")

        let flow = SendFlowController(
            knockCase: item, commentsStore: store, coordinator: model.sendCoordinator, draftStore: ComposerDraftStore(), onSent: {})
        let column = CommentsColumnView(
            store: store, composer: flow.composer, sendFlow: flow,
            shared: SharingModels.model(for: id, client: model.client), tab: .comments)
        try renderView("25-comments-tab-full-size-430x760", width: 430, height: 760, column)
        let conv = conversationDetail(id: "conv-full-\(UUID().uuidString.prefix(6))")
        let convFlow = SendFlowController(
            knockCase: conv.case, commentsStore: CommentsSessionStore(), coordinator: model.sendCoordinator,
            draftStore: ComposerDraftStore(), onSent: {})
        let thread = try #require(conv.threadModel())
        let turn = conv.threadTurn(thread)
        let ask = AskColumnView(
            knockCase: conv.case, composer: convFlow.composer, sendFlow: convFlow, commentCount: 3,
            thread: (thread, turn), conversation: (thread, turn), tab: .conversation)
        try renderView("26-conversation-tab-full-size-430x860", width: 430, height: 860, ask)
    }

    // MARK: Task 9: full size

    /// Draws the full-size workspace (`ReviewWorkspaceView`, as `MainWindowView` opens it) into `<name>.png`.
    private func renderFullSize(_ name: String, _ detail: CaseDetail, width: CGFloat, height: CGFloat) throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = connectedModel()
        let view = ReviewWorkspaceView(
            detail: detail, now: Date(), client: model.client, sendCoordinator: model.sendCoordinator,
            onBack: {}, onRetryDelivery: {})
            .frame(width: width, height: height)
            .environment(\.colorScheme, .light)
        try renderView(name, width: width, height: height, view)
    }

    /// Full size (C9) on a 13" window and on full screen: the same column and tabs as the pane, 440 pt while the
    /// artifact keeps 60 % of the window. The toolbar's switches are drawn alone too (no daemon: the artifact's own
    /// content, and so its toolbar, does not load here).
    @Test func fullSize() throws {
        guard folder != nil else { return }
        let item = makeCase(hasArtifact: true)
        let shown = detail(item)
        for (w, h) in [(1440, 900), (1728, 1117), (1000, 700)] {
            let column = Int(AskLayout.fullSizeColumnWidth(window: CGFloat(w)))
            try renderFullSize("27-full-size-\(w)x\(h)-column-\(column)-artifact-\(w - column)", shown, width: CGFloat(w), height: CGFloat(h))
        }
        let stage = ScreenshotStageModel()
        let on = CompareModel()
        on.choose(.slider)
        let controls = VStack(alignment: .trailing, spacing: 14) {
            StageHeaderControls(stage: stage, showsSetToggle: true, onShowSet: {}, compare: CompareModel(), compareAvailable: true)
            StageHeaderControls(stage: stage, showsSetToggle: true, onShowSet: {}, compare: on, compareAvailable: true)
            StageHeaderControls(stage: stage, showsSetToggle: true, onShowSet: {}, compare: CompareModel(), compareAvailable: false)
            ComparePanel(compare: on)
        }
        .padding(16)
        try renderView("28-full-size-toolbar-switches", width: 820, height: 200, controls)
    }

    // MARK: Task 10: the status line

    private var task10: URL? {
        folder.map { $0.deletingLastPathComponent().appendingPathComponent("task10", isDirectory: true) }
    }

    private func isoAgo(_ seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-seconds))
    }

    /// A case of the status renders: one decision, answered or not, on a session in `session`.
    private func statusCase(
        id: String, status: CaseStatus = .waitingOnAgent, kind: Case.Kind = .question, session: SessionState? = .live,
        replyState: ReplyStatus? = .queued, replyAgo: TimeInterval = 300, doneAt: String? = nil, follows: String? = nil
    ) -> Case {
        let options = kind == .review
            ? [Option(id: "approve", label: "Approve"), Option(id: "changes", label: "Request changes")] : self.options
        return Case(
            id: id, taskId: "t1", kind: kind, title: "Which direction for the request page?",
            need: "Pick one of three directions for the request page.", why: "This changes the main screen.",
            recommendation: options[1].id, recommendationWhy: "It removes the duplicate options.", options: options,
            status: status, hasArtifact: false,
            latestReplyId: replyState == nil ? nil : "reply_8f2a1c", latestReplyState: replyState,
            latestReplyAt: replyState == nil ? nil : isoAgo(replyAgo), latestReplyChoice: replyState == nil ? nil : options[1].id,
            sessionState: session, followsCaseId: follows,
            doneAt: doneAt, createdAt: isoAgo(3600), updatedAt: isoAgo(60))
    }

    /// The pane of one status state, into the task 10 folder.
    private func renderStatus(
        _ name: String, _ item: Case, delivery: DeliveryState? = nil, offline: Bool = false, width: CGFloat = 1000,
        height: CGFloat = 620
    ) throws {
        guard let task10 else { return }
        let model = connectedModel()
        if offline { model.setConnectionStateForTests(.disconnected) }
        if let delivery { model.setDeliveryStatusForTests(delivery, caseId: item.id) }
        try renderInto(task10, name, item, width: width, height: height, model: model)
    }

    private func renderInto(_ dir: URL, _ name: String, _ item: Case, width: CGFloat, height: CGFloat, model: AppModel) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let view = CasePaneDetailView(model: model, detail: detail(item))
            .frame(width: width, height: height)
            .background(Theme.Colors.win)
            .environment(\.colorScheme, .light)
        try snapshot(view, into: dir.appendingPathComponent("\(name).png"), width: width, height: height, dark: false)
    }

    /// The status line alone, at a column's width, in light or dark.
    private func renderLine(_ name: String, _ line: RequestStatus.Line, item: Case, width: CGFloat, dark: Bool = false) throws {
        guard let task10 else { return }
        try FileManager.default.createDirectory(at: task10, withIntermediateDirectories: true)
        let view = RequestContextLine(
            item: item, client: nil, status: line.text,
            statusView: AnyView(RequestStatusLineView(line: line, item: item, onAction: { _ in }, onHide: {})),
            onOpenCase: { _ in })
            .padding(16)
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(dark ? StatusRenderColors.darkPage : Theme.Colors.win)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        let height = max(60, host.fittingSize.height)
        try snapshot(view.frame(height: height, alignment: .top), into: task10.appendingPathComponent("\(name).png"), width: width, height: height, dark: dark)
    }

    private func snapshot<V: View>(_ view: V, into url: URL, width: CGFloat, height: CGFloat, dark: Bool) throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        window.orderOut(nil)
    }

    /// Each state of spec section 8 in the pane, and the failed line alone in light and dark and at a narrow width.
    @Test func statusLine() throws {
        guard folder != nil else { return }
        let run = UUID().uuidString.prefix(6)
        func id(_ name: String) -> String { "\(name)-\(run)" }
        try renderStatus("30-sent-waiting-with-menu", statusCase(id: id("sent")))
        try renderStatus("31-sent-review-open-review", statusCase(id: id("sent-review"), kind: .review))
        try renderStatus(
            "32-working-delivered", statusCase(id: id("working"), replyState: .delivered),
            delivery: .delivered(at: Date().addingTimeInterval(-240)))
        try renderStatus(
            "33-delivered", statusCase(id: id("delivered"), status: .resolved, replyState: .delivered),
            delivery: .delivered(at: Date().addingTimeInterval(-240)))
        try renderStatus("34-session-closed-before-answer", statusCase(id: id("closed-open"), status: .needsYou, session: .ended, replyState: nil))
        try renderStatus("35-session-closed-while-waiting", statusCase(id: id("closed-wait"), session: .ended))
        try renderStatus(
            "36-not-delivered-light", statusCase(id: id("failed"), replyState: .failed), delivery: .failed(replyId: "reply_8f2a1c"))
        try renderStatus(
            "37-saved-session-ended", statusCase(id: id("saved"), session: .ended, replyState: .failed),
            delivery: .failed(replyId: "reply_8f2a1c"))
        try renderStatus("38-done-got-it", statusCase(id: id("done"), replyState: .delivered, doneAt: isoAgo(30)))
        try renderStatus("39-offline", statusCase(id: id("offline"), status: .needsYou, replyState: nil), offline: true)
        try renderStatus("40-handed-over", statusCase(id: id("handed"), status: .resolved, replyState: .handedOver))
        try renderStatus(
            "41-not-delivered-narrow-800", statusCase(id: id("failed-narrow"), replyState: .failed),
            delivery: .failed(replyId: "reply_8f2a1c"), width: 800)

        // The line alone: the failed one in light and dark (a dark page, for the dark pair of colors), a long refusal
        // at the narrowest column, the composer's own states, a settled answer, and a follow-up with its status.
        let open = statusCase(id: id("open"), status: .needsYou, replyState: nil)
        let failed = try #require(RequestStatus.line(.init(
            item: statusCase(id: id("f"), replyState: .failed), confirmed: .failed(replyId: "reply_8f2a1c"))))
        try renderLine("42-not-delivered-line-light-440", failed, item: open, width: 440)
        try renderLine("43-not-delivered-line-dark-440", failed, item: open, width: 440, dark: true)
        let reason = "The case was dismissed in another window, so the service cannot take a reply for it any more. "
            + "Open the case again from the list to answer it."
        let refused = try #require(RequestStatus.line(.init(item: open, local: .refused(reason: reason))))
        try renderLine("44-refused-long-reason-light-340", refused, item: open, width: 340)
        try renderLine("45-refused-long-reason-dark-340", refused, item: open, width: 340, dark: true)
        let notSent = try #require(RequestStatus.line(.init(item: open, local: .offline)))
        try renderLine("46-not-sent-offline-440", notSent, item: open, width: 440)
        let sending = try #require(RequestStatus.line(.init(item: open, local: .sending)))
        try renderLine("47-sending-440", sending, item: open, width: 440)
        let settled = try #require(RequestStatus.line(.init(
            item: statusCase(id: id("settled"), replyState: .delivered),
            settled: .init(pickedUpAt: Date().addingTimeInterval(-7200), followUp: .init(id: "c9", title: "Next step")))))
        try renderLine("48-settled-open-follow-up-440", settled, item: open, width: 440)
        let earlier = statusCase(id: id("earlier"), status: .resolved, replyState: .delivered)
        FollowedCaseCache.shared.store(earlier)
        let follow = statusCase(id: id("follow"), follows: earlier.id)
        let sent = try #require(RequestStatus.line(.init(item: follow, pickup: .copyPrompt(.live))))
        try renderLine("49-follow-up-and-sent-one-line-1100", sent, item: follow, width: 1100)
        try renderLine("50-follow-up-and-sent-stacked-440", sent, item: follow, width: 440)
    }
    // MARK: The whole window: sidebar, top bar, page header and artifact card (STYLE-AUDIT.md §6)

    /// A sample queue case for the window renders (mockup sample content, never real data).
    private func sampleCase(
        _ id: String, _ title: String, project: String, taskId: String, ago: TimeInterval, status: CaseStatus = .needsYou,
        answered: String? = nil, hasArtifact: Bool = false
    ) -> Case {
        Case(
            id: id, taskId: taskId, kind: .question, title: title, need: "", why: "", recommendation: "", recommendationWhy: "",
            options: [Option(id: "a", label: "Yes"), Option(id: "b", label: "No")], status: status, hasArtifact: hasArtifact,
            latestReplyId: answered == nil ? nil : "r-\(id)", latestReplyState: answered == nil ? nil : .delivered,
            latestReplyAt: answered == nil ? nil : isoAgo(ago), latestReplyChoice: answered,
            firstReplySubmittedAt: answered == nil ? nil : isoAgo(ago),
            sessionState: answered == nil ? .live : .ended, project: project,
            createdAt: isoAgo(ago + 60), updatedAt: isoAgo(ago))
    }

    private func sampleSession(_ taskId: String, project: String, title: String) -> SessionInfo {
        SessionInfo(
            id: "s-\(taskId)", taskId: taskId, runtime: .claude, taskName: project, project: project, branch: nil,
            cwd: "/tmp/\(project)", canNudge: true, state: .live, connectedAt: isoAgo(7200), lastSeenAt: isoAgo(60),
            sessionTitle: title)
    }

    /// Draws the main window's queue and pane side by side (as `MainWindowView` lays them out) at 2x, as the shots.
    private func renderWindow(_ name: String, model: AppModel, detail: CaseDetail, width: CGFloat, height: CGFloat) throws {
        model.setSelectionForTests(detail)
        let view = HStack(spacing: 0) {
            QueueListView(model: model, onFold: {})
            CasePaneDetailView(model: model, detail: detail)
        }
        .frame(width: width, height: height)
        try renderView(name, width: width, height: height, scale: 2, view)
    }

    /// Mockup B ("Options in place", `shots/inplace-light.png`, 1440 × 900): no artifact, the eyebrow and the 28 pt
    /// title, Needs you · 2 with the first row selected, Answered open with three rows, the footer.
    @Test func windowNoArtifact() throws {
        guard folder != nil else { return }
        let run = UUID().uuidString.prefix(6)
        let options = [
            Option(id: "pixbin", label: "You make a Pixbin account and add a few dollars. I test Pixbin, Cloudframe and Snapstore.",
                   title: "Pixbin pay-as-you-go",
                   pros: ["About $1.70 for 3 services", "No subscription", "Includes Snapstore"],
                   cons: ["The images go to a new service", "Minimum top-up not confirmed", "Terms of use still to read"]),
            Option(id: "wait", label: "Wait for the free tier", title: "Wait for the free tier",
                   pros: ["No new account"], cons: ["Three days on hold", "Slow", "No CDN", "Unknown date"]),
            Option(id: "pro", label: "Pro plan at $19", title: "Pro plan at $19",
                   pros: ["Only one service", "Support"], cons: ["$19 a month", "Lock-in", "No Snapstore"]),
        ]
        let need = """
            For the images we need, yes: Pixbin has all the formats and you pay per use. The test costs about $1.70.

            | Service | Has a CDN | Cost per 1,000 images |
            |---|---|---:|
            | Pixbin standard | Yes | $0.50–0.60 |
            | Cloudframe basic | Yes | $0.375 + $0.15/resize |
            | Snapstore lite | Yes | $0.40 |
            | Lumen media library | Yes (from search) | Not confirmed |

            **Correction:** before, I wrote that Pro adds Lumen. That is not true: Lumen also works with Pixbin.
            """
        let selected = Case(
            id: "blog-\(run)", taskId: "t-blog", kind: .question, title: "Which image host do we use?", need: need,
            why: "the blog images go to a new service, and only you can accept its terms of use.",
            recommendation: "pixbin", recommendationWhy: "it costs much less and adds Snapstore. I stop before any upload if the terms are not OK.",
            options: options, status: .needsYou, hasArtifact: false, sessionState: .live, project: "sample-blog",
            createdAt: isoAgo(30), updatedAt: isoAgo(30))
        let model = connectedModel()
        model.applyLists(
            needsYouRaw: [
                selected,
                sampleCase("docs-\(run)", "Is the search index for the docs site ready to ship?", project: "docs-site", taskId: "t-docs", ago: 14 * 60),
            ],
            waitingRaw: [
                sampleCase("pr-\(run)", "Do I open the PR for the checkout copy?", project: "demo-shop", taskId: "t-shop", ago: 16 * 60,
                           status: .waitingOnAgent, answered: "a"),
                sampleCase("build-\(run)", "When do we send the first test build to the testers?", project: "docs-site", taskId: "t-docs",
                           ago: 2 * 3600, status: .waitingOnAgent, answered: "a"),
                sampleCase("ver-\(run)", "Which version number do we use for this release?", project: "demo-shop", taskId: "t-shop",
                           ago: 2 * 3600 + 120, status: .waitingOnAgent, answered: "b"),
            ])
        model.answeredOpen = true
        model.setSessionsForTests([sampleSession("t-blog", project: "sample-blog", title: "Image hosting")])
        setenv("KNOCK_EVIDENCE_PICK_OPTION", "pixbin", 1)
        defer { unsetenv("KNOCK_EVIDENCE_PICK_OPTION") }
        let shown = CaseDetail(
            case: selected, task: KnockTask(id: "t-blog", name: "sample-blog", project: "sample-blog"),
            messages: [], revisions: [], comments: [], replies: [], planRounds: nil)
        try renderWindow("60-window-no-artifact-1440x900", model: model, detail: shown, width: 1440, height: 900)
    }

    /// The case map (`…-request-page-cases`, template `shots`, 1600 × 758): an artifact beside the 440 pt column, the
    /// top bar with the crumb, the times and the Waiting pill, the artifact card with two tabs and the version.
    @Test func windowWithArtifact() throws {
        guard folder != nil else { return }
        let run = UUID().uuidString.prefix(6)
        let selected = makeCase(hasArtifact: true, id: "dir-\(run)")
        let model = connectedModel()
        model.applyLists(
            needsYouRaw: [
                selected,
                sampleCase("hero-\(run)", "Do I redo the hero photos, or keep the current ones?", project: "demo-shop", taskId: "t-shop", ago: 9 * 60),
                sampleCase("plan-\(run)", "Plan: one layout for every request page", project: "waggle", taskId: "t1", ago: 30 * 60),
            ],
            waitingRaw: [
                sampleCase("old-\(run)", "Which version number do we use for this release?", project: "demo-shop", taskId: "t-shop",
                           ago: 3 * 3600, status: .waitingOnAgent, answered: "b"),
            ])
        model.answeredOpen = false
        model.setSessionsForTests([
            sampleSession("t1", project: "waggle", title: "Request page UI cleanup"),
            sampleSession("t-shop", project: "demo-shop", title: "Checkout copy for the cart page"),
        ])
        let revisions = [
            Revision(id: "r1", caseId: selected.id, n: 1, createdAt: isoAgo(600), author: .agent, baseRevision: nil,
                     name: "Request page mockups", kind: .markdown),
            Revision(id: "r2", caseId: selected.id, n: 2, createdAt: isoAgo(420), author: .agent, baseRevision: nil,
                     name: "Screenshots", kind: .markdown),
        ]
        let shown = CaseDetail(
            case: selected, task: KnockTask(id: "t1", name: "Request page UI cleanup", project: "waggle"),
            messages: [], revisions: revisions, comments: [], replies: [], planRounds: nil)
        setenv("KNOCK_EVIDENCE_PICK_OPTION", "b", 1)
        defer { unsetenv("KNOCK_EVIDENCE_PICK_OPTION") }
        try renderWindow("61-window-artifact-1600x758", model: model, detail: shown, width: 1600, height: 758)
    }

}

/// A plain text view of an attributed string, for the AppKit table render.
private struct AttributedTextBox: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: 404, height: 260)
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 13, height: 11)
        view.textStorage?.setAttributedString(text)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {}
}

/// Evidence only: a window that lays out at 2x, so an offscreen render rounds to half points as on a Retina screen.
final class RetinaRenderWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}
