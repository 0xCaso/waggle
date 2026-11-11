import AppKit

/// The pure rules of the prompt bar (HAIL-77, Beautiful UI "Prompt Bar",
/// variant A): how tall the reply field grows, when the controls move to
/// their own row, what Return does, and when Send is live. No SwiftUI, so
/// every rule is unit-testable without hosting a view.
enum PromptBarLogic {
    /// One text line, in points (prototype `line-height:18px`).
    static let lineHeight: CGFloat = 18
    /// Field padding around the text: 5 pt top and bottom, 4 pt left and right
    /// (prototype `padding:5px 4px`). One line is therefore 28 pt tall.
    static let textInset = CGSize(width: 4, height: 5)
    /// One line of the field's own text view: 18 + 2 × 5 (the bordered box around it is 36, see `fieldBoxPadding`).
    static let controlSize: CGFloat = 28
    /// The answer area's side padding (mockup `.ans` padding `10px 14px 12px`).
    static let barPadding: CGFloat = 14
    static let barTopPadding: CGFloat = 10
    static let barBottomPadding: CGFloat = 12
    /// The tools row's gap (mockup `.ans .tools` gap 14), also between the last quiet button and Send.
    static let controlGap: CGFloat = 14
    /// Field to tools row (mockup `.ans .tools` margin-top 8).
    static let rowGap: CGFloat = 8
    /// The bordered box around the text view: with the text view's own `textInset` (4 / 5) and the 1 pt border,
    /// the text sits 12 from the box's sides and 9 from its top, as the mockup's `.note` (border 1, padding 8 / 11).
    static let fieldBoxPadding = CGSize(width: 8, height: 4)
    static let fieldRadius: CGFloat = 9
    /// The answer box's text (mockup `.note` 12.5). Other fields built on the same text view keep `font` (13.5).
    static let answerFontSize: CGFloat = 12.5
    /// Send: 12.5 / 600 on a CSS line box of 1.45 plus 8 pt padding top and bottom (mockup `.send`) = 34.
    static let sendHeight: CGFloat = 34
    static let sendHorizontalPadding: CGFloat = 12
    /// The "+" attach glyph's box: quiet, no fill, as tall as the row.
    static let attachWidth: CGFloat = 16
    /// The "⋯" menu that holds the tools a narrow row cannot fit.
    static let overflowWidth: CGFloat = 20
    static let minSingleRowFieldWidth: CGFloat = 40
    /// The field keeps about this width on the shared row; under it the controls move to a second row (WAG-336).
    /// This sets the buttons' plan (which label form, which quiet buttons in More), not where the field goes.
    static let minFieldWidth: CGFloat = 200
    /// The field stays on the buttons' row while it keeps at least this width there and its text fits on one line
    /// (C6, app check 2026-11-09): an empty field's placeholder wraps in it (never "…"), so a wide Send label
    /// ("Send comments") no longer pushes an empty field onto its own row. Under it, the field moves.
    static let minSharedFieldWidth: CGFloat = 140
    /// Six lines: the least the answer box grows to before it scrolls, and the reply items' cap.
    static let paneMaxLines = 6

    /// The bundled Inter Tight face for `weight`, by PostScript name: 400 Regular, 500 Medium, 600 SemiBold,
    /// 700 Bold. Each weight snaps down to the nearest bundled face, so `.semibold` is SemiBold 600 (as the
    /// mockups' CSS draws it), not the bold trait (Bold 700), and `.medium` keeps its 500.
    static func sansFaceName(for weight: NSFont.Weight) -> String {
        switch weight.rawValue {
        case NSFont.Weight.bold.rawValue...: "InterTight-Bold"
        case NSFont.Weight.semibold.rawValue...: "InterTight-SemiBold"
        case NSFont.Weight.medium.rawValue...: "InterTight-Medium"
        default: "InterTight-Regular"
        }
    }

    static func sansFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard FontRegistration.didRegisterBundledFonts, let base = NSFont(name: Theme.FontFamily.sans, size: size) else {
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        if let face = NSFont(name: sansFaceName(for: weight), size: size) { return face }
        return weight.rawValue >= NSFont.Weight.semibold.rawValue
            ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            : base
    }

    static var font: NSFont { sansFont(size: 13.5) }
    static var answerFont: NSFont { sansFont(size: answerFontSize) }

    static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    // MARK: - Growth (request page C6)

    /// Lines another field (a reply item, a note) occupies when laid out in `textWidth` points. The answer box
    /// does not use it: its height comes from its own text view (`PromptNSTextView.measure`). Counts the empty
    /// last line after a trailing newline. Always at least 1.
    static func lineCount(
        text: String, textWidth: CGFloat, font: NSFont = PromptBarLogic.font, paragraphStyle: NSParagraphStyle = PromptBarLogic.paragraphStyle
    ) -> Int {
        let storage = NSTextStorage(
            string: text,
            attributes: [.font: font, .paragraphStyle: paragraphStyle]
        )
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(textWidth, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var count = 0
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, _, _ in
            count += 1
        }
        if manager.extraLineFragmentRect.height > 0 { count += 1 }
        return max(count, 1)
    }

    /// Lines drawn before the field scrolls inside itself.
    static func visibleLines(totalLines: Int, maxLines: Int) -> Int {
        min(max(totalLines, 1), max(maxLines, 1))
    }

    static func fieldHeight(totalLines: Int, maxLines: Int) -> CGFloat {
        CGFloat(visibleLines(totalLines: totalLines, maxLines: maxLines)) * lineHeight + textInset.height * 2
    }

    static func scrolls(totalLines: Int, maxLines: Int) -> Bool { totalLines > maxLines }

    /// The answer box grows to this share of the column or pane it sits in (C6)...
    static let capShare: CGFloat = 0.4
    /// ...but always to at least this many lines.
    static let minCapLines = paneMaxLines

    /// The field's height for the text height its own layout manager reports: never under one line.
    static func contentHeight(usedTextHeight: CGFloat) -> CGFloat {
        max(ceil(usedTextHeight), lineHeight) + textInset.height * 2
    }

    /// Tallest the answer box grows before it scrolls: 40 % of `availableHeight`, at least six lines.
    /// `nil` or 0 (a host that does not say) gives the six lines.
    static func maxFieldHeight(availableHeight: CGFloat?) -> CGFloat {
        let floor = fieldHeight(totalLines: minCapLines, maxLines: minCapLines)
        guard let availableHeight, availableHeight > 0, availableHeight.isFinite else { return floor }
        return max((availableHeight * capShare).rounded(.down), floor)
    }

    static func fieldHeight(contentHeight: CGFloat, maxHeight: CGFloat) -> CGFloat { min(contentHeight, maxHeight) }

    /// Past the cap the field scrolls, and its scroller stays on screen.
    static func scrolls(contentHeight: CGFloat, maxHeight: CGFloat) -> Bool { contentHeight > maxHeight + 0.5 }

    /// What the answer box's own text view reports after an edit or a width change.
    struct FieldMetrics: Equatable {
        /// Height of the text plus the insets, laid out at `width`.
        var contentHeight: CGFloat
        /// Width of the widest paragraph on one line, without the insets.
        var naturalWidth: CGFloat
        /// The text view's width when it measured.
        var width: CGFloat
    }

    /// Width the field gets on the row it shares with the controls.
    /// `leadingWidth` is what sits left of the field: the "+" alone, or "+" and "Ask for…" (C5).
    static func sharedRowFieldWidth(barWidth: CGFloat, controlsWidth: CGFloat, leadingWidth: CGFloat = controlSize) -> CGFloat {
        barWidth - barPadding * 2 - leadingWidth - controlGap * 2 - controlsWidth
    }

    /// The left of the send row: the "+" and, where the host offers it, the "Ask for…" button after a gap (C5).
    static func leadingWidth(askForLabelWidth: CGFloat?) -> CGFloat {
        guard let askForLabelWidth else { return attachWidth }
        return attachWidth + controlGap + quietButtonWidth(labelWidth: askForLabelWidth)
    }

    /// The button at the left of the send row that opens the ask-for-detail panel (C5).
    static let askForLabel = "Ask for…"

    /// The field leaves the controls' row for its own full-width row above them when the text needs more
    /// width than the shared row gives (it would wrap there), has a line break, or the controls leave it under
    /// `minSharedFieldWidth` (C6: only when the text needs the width). The rule reads the text's one-line width,
    /// never the row the field is on now, so it cannot flip back and forth. Before the bar is measured only a line
    /// break, or controls already on their own row, move the field. An empty field stays on the shared row while it
    /// keeps `minSharedFieldWidth` (WAG-305); its placeholder wraps there.
    static func fieldTakesOwnRow(
        text: String, naturalTextWidth: CGFloat?, barWidth: CGFloat, controlsWidth: CGFloat, controlsOwnRow: Bool = false,
        leadingWidth: CGFloat = controlSize
    ) -> Bool {
        if text.contains(where: \.isNewline) { return true }
        guard barWidth > 0 else { return controlsOwnRow }
        let shared = sharedRowFieldWidth(barWidth: barWidth, controlsWidth: controlsWidth, leadingWidth: leadingWidth)
        if shared < minSharedFieldWidth { return true }
        guard !text.isEmpty, let naturalTextWidth else { return false }
        return naturalTextWidth > shared - textInset.width * 2
    }

    // MARK: - Widths of the controls

    private static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = sansFont(size: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Width of a quiet text button ("Let's discuss", "Open review") for a label `labelWidth` wide: plain text,
    /// no padding (mockup `.ans .tools span`).
    static func quietButtonWidth(labelWidth: CGFloat) -> CGFloat { ceil(labelWidth) }

    /// Width of the Send button for a label `labelWidth` wide: 12 pt padding each side, and room for the arrow
    /// (6 pt gap, 12 pt) that shows beside the label when comments or an edit go with the reply.
    static func sendPillWidth(labelWidth: CGFloat) -> CGFloat { ceil(labelWidth) + 6 + 12 + sendHorizontalPadding * 2 }

    /// Estimate of a quiet button, before the bar has measured its label (12 pt, 400).
    static func quietButtonWidth(_ label: String) -> CGFloat {
        quietButtonWidth(labelWidth: textWidth(label, size: 12, weight: .regular))
    }

    /// Estimate of the Send button, before the bar has measured its label: a 34 pt square, or the labelled button.
    static func sendButtonWidth(pillLabel: String?) -> CGFloat {
        guard let pillLabel else { return sendHeight }
        return sendPillWidth(labelWidth: textWidth(pillLabel, size: answerFontSize, weight: .semibold))
    }

    /// The widths the controls plan uses. The bar passes the label widths it measured in the real text
    /// styles; until then (and in tests) the estimates above.
    struct ControlWidths {
        var quiet: (String) -> CGFloat
        var send: (String?) -> CGFloat

        static var estimated: ControlWidths { ControlWidths(quiet: { quietButtonWidth($0) }, send: { sendButtonWidth(pillLabel: $0) }) }

        /// Measured label widths by label; a label not measured yet falls back to the estimate.
        static func measured(quiet: [String: CGFloat], pill: [String: CGFloat]) -> ControlWidths {
            ControlWidths(
                quiet: { label in quiet[label].map { quietButtonWidth(labelWidth: $0) } ?? quietButtonWidth(label) },
                send: { label in
                    guard let label else { return sendHeight }
                    return pill[label].map { sendPillWidth(labelWidth: $0) } ?? sendButtonWidth(pillLabel: label)
                })
        }
    }

    /// The right-hand controls together, with the gaps between them and a few
    /// points of slack so the field is never made too wide.
    /// `hasOverflow` adds the 28 pt "More" menu that holds the quiet buttons that do not fit.
    static func controlsWidth(
        quietLabels: [String], sendPillLabel: String?, hasOverflow: Bool = false, widths: ControlWidths = .estimated,
        leadingLabels: [String] = []
    ) -> CGFloat {
        var all = (leadingLabels + quietLabels).map(widths.quiet)
        if hasOverflow { all.append(overflowWidth) }
        all.append(widths.send(sendPillLabel))
        return all.reduce(0, +) + controlGap * CGFloat(all.count - 1) + 8
    }

    // MARK: - Fitting the controls row

    /// What the controls row shows at a given width, so the primary button is never cut
    /// (bug 4 Oct 2026: "Approve section + 1 comment" read "rove section + 1 commen" in a
    /// narrow ask column). The quiet buttons give way first, into a "More" menu; only then
    /// does the primary label take a shorter form.
    struct ControlsPlan: Equatable {
        /// Quiet buttons shown in the row, left to right.
        var quietLabels: [String]
        /// Quiet buttons moved into the "More" menu, in their row order.
        var overflowLabels: [String]
        /// The primary button's label; `nil` for the plain 28 pt arrow.
        var sendPillLabel: String?
        /// The controls leave the field under `minFieldWidth` on the shared row, so they take a second row (WAG-336).
        var ownRow = false
        /// The tools shown at the left of the row after "+" ("Let's discuss", "Show me more"); the ones that do not
        /// fit are in `overflowLabels`.
        var leadingLabels: [String] = []

        var width: CGFloat { width(.estimated) }

        func width(_ widths: ControlWidths) -> CGFloat {
            PromptBarLogic.controlsWidth(
                quietLabels: quietLabels, sendPillLabel: sendPillLabel, hasOverflow: !overflowLabels.isEmpty, widths: widths,
                leadingLabels: leadingLabels)
        }
    }

    /// The controls for a row `rowWidth` wide (the bar's width less its padding; `nil` or 0
    /// before it is measured). `pillLabels` are the primary label's forms, longest first (see
    /// `sendPillLabels`). For each form, longest first, quiet buttons move into the menu from
    /// the left ("Ask for more detail" first, a plan round's "Change" last) until the row
    /// fits. If nothing fits: the shortest form, every quiet button in the menu. A quiet button
    /// is never cut with "…": it is shown whole or it is in the menu (C7).
    ///
    /// `fieldOnOwnRow` (the answer box, 2026-11-10): the field never shares the row, so the whole row is the
    /// controls'. `leadingLabels` are the tools after "+" ("Let's discuss", "Show me more"): they give way into
    /// the menu first, the last one first, then the quiet buttons; only then does the Send label get shorter.
    static func controlsPlan(
        rowWidth: CGFloat?, quietLabels: [String], pillLabels: [String?], widths: ControlWidths = .estimated,
        leadingWidth: CGFloat = attachWidth, leadingLabels: [String] = [], fieldOnOwnRow: Bool = false
    ) -> ControlsPlan {
        let forms = pillLabels.isEmpty ? [nil] : pillLabels
        let full = ControlsPlan(quietLabels: quietLabels, overflowLabels: [], sendPillLabel: forms[0], leadingLabels: leadingLabels)
        guard let rowWidth, rowWidth > 0 else { return full }
        // The attach button (and "Ask for…") and its gap sit left of the controls.
        let available = rowWidth - leadingWidth - controlGap
        if fieldOnOwnRow {
            return ownRowPlan(available: available, leadingLabels: leadingLabels, quietLabels: quietLabels, forms: forms, widths: widths)
        }
        // First, the longest label that leaves the field its width on the shared row, quiet buttons kept (WAG-336).
        // Then the short forms ("Rule out 3"). Only when none fits do the controls take a second row.
        let shared = available - minFieldWidth - controlGap
        for form in forms {
            let plan = ControlsPlan(quietLabels: quietLabels, overflowLabels: [], sendPillLabel: form)
            if plan.width(widths) <= shared { return plan }
        }
        var onOwnRow = controlsPlanOwnRow(available: available, quietLabels: quietLabels, forms: forms, widths: widths)
        onOwnRow.ownRow = true
        return onOwnRow
    }

    /// The row under a field on its own row: tools give way into the menu (the last tool first, then the quiet
    /// buttons from the left), for each Send form, longest first.
    private static func ownRowPlan(
        available: CGFloat, leadingLabels: [String], quietLabels: [String], forms: [String?], widths: ControlWidths
    ) -> ControlsPlan {
        let movable = Array(leadingLabels.reversed()) + quietLabels
        func plan(_ moved: Int, _ form: String?) -> ControlsPlan {
            let out = Set(movable.prefix(moved))
            return ControlsPlan(
                quietLabels: quietLabels.filter { !out.contains($0) },
                overflowLabels: (leadingLabels + quietLabels).filter { out.contains($0) },
                sendPillLabel: form, ownRow: true,
                leadingLabels: leadingLabels.filter { !out.contains($0) })
        }
        for form in forms {
            for moved in 0...movable.count where plan(moved, form).width(widths) <= available { return plan(moved, form) }
        }
        return plan(movable.count, forms[forms.count - 1])
    }

    private static func controlsPlanOwnRow(
        available: CGFloat, quietLabels: [String], forms: [String?], widths: ControlWidths
    ) -> ControlsPlan {
        for form in forms {
            for moved in 0...quietLabels.count {
                let plan = ControlsPlan(
                    quietLabels: Array(quietLabels.dropFirst(moved)),
                    overflowLabels: Array(quietLabels.prefix(moved)),
                    sendPillLabel: form
                )
                if plan.width(widths) <= available { return plan }
            }
        }
        return ControlsPlan(quietLabels: [], overflowLabels: quietLabels, sendPillLabel: forms[forms.count - 1])
    }

    // MARK: - Return key

    enum ReturnKeyAction: Equatable {
        /// Send the reply (same action as the Send button).
        case send
        /// Insert a newline.
        case newline
        /// Return with nothing to send: do nothing.
        case ignore
        /// Let AppKit handle the key (IME composition, or a ⌘↵ shortcut).
        case passThrough
    }

    static func returnKeyAction(shift: Bool, command: Bool, hasMarkedText: Bool, canSend: Bool) -> ReturnKeyAction {
        if hasMarkedText || command { return .passThrough }
        if shift { return .newline }
        return canSend ? .send : .ignore
    }

    // MARK: - Send

    /// Something to send: a picked option, typed text, or pending comments.
    static func canSend(hasChoice: Bool, hasMessage: Bool, commentCount: Int, hasEdit: Bool = false, hasFiles: Bool = false) -> Bool {
        hasChoice || hasMessage || commentCount > 0 || hasEdit || hasFiles
    }

    /// The quiet text buttons, left to right. There is no "Accept" button:
    /// the operator picks the recommended option and sends, or presses ⌘D.
    static let askForDetailLabel = "Ask for more detail"
    static let openReviewLabel = "Open review"

    /// "Use this reply" (a reply-only ask with an empty field, spec section 9) comes last, so it is the last to
    /// move into "More".
    static func quietLabels(
        hasOpenReview: Bool, hasDetail: Bool = true, planSecondary: String? = nil, suggestsReply: Bool = false
    ) -> [String] {
        (hasDetail ? [askForDetailLabel] : []) + (hasOpenReview ? [openReviewLabel] : []) + (planSecondary.map { [$0] } ?? [])
            + (suggestsReply ? [ComposerFooterView.useSuggestedReply] : [])
    }

    /// "Send + 2 comments" once comments are pending; `nil` for the plain square. With several
    /// options ticked (HAIL-123) it reads "Send 2", or "Send 2 + 1 comment".
    /// A plan round (HAIL-151) passes its stage's words as `planLabel` ("Next question"); they take
    /// the place of "Send" and make the button a labelled pill.
    static func sendPillLabel(
        commentCount: Int, pickCount: Int = 0, planLabel: String? = nil, hasEdit: Bool = false
    ) -> String? {
        var label = planLabel ?? (pickCount > 0 ? "Send \(pickCount)" : "Send")
        let plain = (pickCount > 0 || planLabel != nil) && commentCount == 0
        if commentCount > 0 { label += " + \(commentCount) comment\(commentCount == 1 ? "" : "s")" }
        // HAIL-168: a document edit travels with the reply, and the label says so.
        if hasEdit { return label + " + edit" }
        return commentCount > 0 || plain ? label : nil
    }

    /// The primary label's forms for a narrow row, longest first, without repeats: the full
    /// label, then the plan's short words with the count ("Approve + 1 comment"), then the
    /// short words alone ("Approve"; the arrow beside it still shows that comments go too).
    /// The longest option title the Decide button carries before it is cut at a word.
    static let decideTitleLimit = 28
    static let feedbackLabel = "Send feedback"
    static let commentsLabel = "Send comments"
    /// The line under a review's rows while none is picked (WAG-316).
    static let reviewPickHint = "Pick Approve or Request changes to decide."

    /// "1", "1 and 2", "1, 2 and 3": option positions as the discuss labels say them (WAG-301).
    static func positionList(_ positions: [Int]) -> String {
        let words = positions.map(String.init)
        guard words.count > 1, let last = words.last else { return words.joined() }
        return words.dropLast().joined(separator: ", ") + " and " + last
    }

    // MARK: - One placeholder per mode (WAG-305)

    enum PlaceholderMode: Equatable {
        /// A decision with options.
        case decide
        /// An ask with no options and no questions.
        case reply
        /// A decision step by step.
        case steps
        /// A revision of a page that came back for comments.
        case revision
    }

    static func placeholder(_ mode: PlaceholderMode) -> String {
        switch mode {
        case .decide: return "Add a note, or ask something…"
        case .reply: return "Reply in your own words…"
        // One placeholder for one decision or many (WAG-326).
        case .steps: return "Add a note, or ask something…"
        case .revision: return "Add a comment, or reply…"
        }
    }

    /// The placeholder of a case's bar: a returned revision wins, then the ask's own mode.
    static func placeholder(for mode: AskBarMode, hasRevision: Bool) -> String {
        if hasRevision { return placeholder(.revision) }
        switch mode {
        case .decide: return placeholder(.decide)
        case .reply: return placeholder(.reply)
        case .answers: return placeholder(.steps)
        }
    }

    /// The primary button of the steps bar (WAG-305): "Next" or "Review and send" while there
    /// are steps to go; on the review step, or on the one-page document, what a send does ("Send 2 answers").
    /// Longest form first. A pinned comments count shows only on a send.
    static let backLabel = "Back"

    /// "Back" on every step after the first.
    static func answersQuietLabels(doc: QuestionsDocModel, comments: Int = 0) -> [String] {
        (doc.isStepped && doc.canGoBack ? [backLabel] : []) + stepNextQuietLabels(doc: doc, comments: comments)
    }

    /// "Next" stays as a quiet button while the primary button sends a question or a lean now (WAG-330).
    static func stepNextQuietLabels(doc: QuestionsDocModel, comments: Int = 0) -> [String] {
        doc.stepTalksNow(comments: comments) ? (doc.nextLabel.map { [$0] } ?? []) : []
    }

    static func answersPillLabels(doc: QuestionsDocModel, comments: Int) -> [String?] {
        if doc.isStepped, let next = doc.nextLabel {
            // A note or a lean on the step sends now as Keep talking; "Next" moves to the quiet side (WAG-330).
            let marks = doc.stepMarkPositions
            if let discuss = discussLabels(leaning: marks.leaning, ruledOut: marks.ruledOut) {
                return sendPillLabels(commentCount: comments, discuss: discuss)
            }
            if doc.message != nil { return sendPillLabels(commentCount: comments, asks: true) }
            // Pinned comments go first: "Send comments", and "Next" moves to the quiet side (operator, 6 Nov).
            if comments > 0 { return [commentsLabel] }
            return [next]
        }
        let full = doc.sendLabel(comments: comments)
        let bare = doc.sendLabel(comments: 0)
        return full == bare ? [full] : [full, bare]
    }

    static let askLabel = "Ask"
    /// The button of a request where the person leaned or ruled out options and has not decided every item (WAG-326).
    static let keepTalkingLabel = "Keep talking"
    static let decideLabel = "Decide"

    /// The button of a bar where the person leaned or ruled options out (WAG-301): says what they did.
    /// Returns the full words and a shorter form for a narrow row. `nil` with neither leans nor rule-outs.
    ///   leans only: "Lean to 1 and 2, keep talking"; both: "Lean to 1 and 2, not 3";
    ///   rule-outs only: "Rule out 3, keep talking".
    static func discussLabels(leaning: [Int], ruledOut: [Int]) -> (full: String, short: String)? {
        switch (leaning.isEmpty, ruledOut.isEmpty) {
        case (true, true): return nil
        case (false, true):
            let lean = "Lean to \(positionList(leaning))"
            return ("\(lean), keep talking", lean)
        case (false, false):
            let lean = "Lean to \(positionList(leaning))"
            return ("\(lean), not \(positionList(ruledOut))", lean)
        case (true, false):
            let out = "Rule out \(positionList(ruledOut))"
            return ("\(out), keep talking", out)
        }
    }

    /// The button of a pick-many ask with ticks (WAG-329): "Decide: 2 picked".
    static func manyDecideLabel(_ count: Int) -> String { "\(decideLabel): \(count) picked" }

    /// The button of a pick-many ask with nothing yet: disabled until a tick, a comment or a note (WAG-329).
    static let sendLabel = "Send"

    /// The button while only the pre-pick stands (WAG-328): "Decide: Flagged first", cut at a word when long;
    /// "Decide" alone for a narrow row.
    static func prePickPillLabels(title: String?) -> [String?] {
        let full = AskDocRules.decideLabel(choiceTitle: title.map(shortTitle))
        return full == decideLabel ? [decideLabel] : [full, decideLabel]
    }

    private static func shortTitle(_ title: String) -> String {
        guard title.count > decideTitleLimit else { return title }
        let cut = String(title.prefix(decideTitleLimit))
        let head = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return head + "…"
    }

    private static func withComments(_ label: String, _ count: Int) -> String {
        count > 0 ? "\(label) + \(count) comment\(count == 1 ? "" : "s")" : label
    }

    /// "Send: <title> ↵", then "Send ↵". With comments the arrow beside the label says it sends: "Send: <title> +
    /// 1 comment", "Send + 1 comment", "Send".
    static func sendTitleLabels(_ title: String, commentCount: Int) -> [String?] {
        guard commentCount > 0 else { return ["\(sendLabel): \(title) ↵", "\(sendLabel) ↵"] }
        return [withComments("\(sendLabel): \(title)", commentCount), withComments(sendLabel, commentCount), sendLabel]
    }

    /// A plan round with options and nothing to send: no stage words on a grey button (WAG-336).
    static func plansBareArrow(isPlanRound: Bool, hasOptions: Bool, canSend: Bool) -> Bool {
        isPlanRound && hasOptions && !canSend
    }

    static func sendPillLabels(
        commentCount: Int, pickCount: Int = 0, planLabel: String? = nil, shortPlanLabel: String? = nil,
        hasEdit: Bool = false, decideTitle: String? = nil, isFeedback: Bool = false,
        discuss: (full: String, short: String)? = nil, asks: Bool = false, sendsComments: Bool = false,
        isMany: Bool = false, withChanges: WithChanges.Kind? = nil, sendTitle: String? = nil
    ) -> [String?] {
        // Ticks on a pick-many ask: "Decide: 2 picked", with the comments count when it fits (WAG-329).
        if isMany, planLabel == nil, pickCount > 0, !hasEdit {
            let full = withComments(manyDecideLabel(pickCount), commentCount)
            return full == manyDecideLabel(pickCount) ? [full] : [full, manyDecideLabel(pickCount)]
        }
        // One option chosen and text in the field: "Approve with changes" or "Decide with changes" (WAG-353).
        // Comments keep their count words; an edit keeps its own mark, so it uses the old forms.
        if let withChanges, pickCount == 0, !hasEdit { return WithChanges.buttonLabels(withChanges, commentCount: commentCount) }
        // Leans and rule-outs say what they did, on a plain ask and on a plan round alike (WAG-301).
        if let discuss, pickCount == 0, !hasEdit {
            var forms: [String?] = []
            for form in [withComments(discuss.full, commentCount), discuss.full, discuss.short] where !forms.contains(form) {
                forms.append(form)
            }
            return forms
        }
        // A review with comments and no row picked sends the comments and keeps talking (WAG-316).
        if sendsComments, commentCount > 0, pickCount == 0, !hasEdit { return [commentsLabel] }
        // Text with no pick, lean or rule-out is a question: "Ask" (WAG-301).
        if asks, pickCount == 0, !hasEdit {
            let full = withComments(askLabel, commentCount)
            return full == askLabel ? [askLabel] : [full, askLabel]
        }
        // A note with no option ticked on a tick list is feedback on the page (WAG-285), worded as the answers bar words it.
        if isFeedback, planLabel == nil, pickCount == 0, !hasEdit {
            let full = commentCount > 0
                ? "Send feedback + \(commentCount) comment\(commentCount == 1 ? "" : "s")" : feedbackLabel
            return full == feedbackLabel ? [feedbackLabel] : [full, feedbackLabel]
        }
        // The plain decision of the request page names the pick: "Send: B · Options in place ↵" (mockups,
        // 2026-11-10). A narrow row gets "Send ↵"; the title is never cut with "…".
        if let sendTitle, !sendTitle.isEmpty, planLabel == nil, pickCount == 0, !hasEdit {
            return sendTitleLabels(sendTitle, commentCount: commentCount)
        }
        // A simple ask with one option chosen reads "Decide" (WAG-257, WAG-301), with the comments count appended.
        if decideTitle != nil, planLabel == nil, pickCount == 0, !hasEdit {
            let full = withComments(decideLabel, commentCount)
            return full == decideLabel ? [decideLabel] : [full, decideLabel]
        }
        let shortWords = shortPlanLabel ?? planLabel
        let full = sendPillLabel(commentCount: commentCount, pickCount: pickCount, planLabel: planLabel, hasEdit: hasEdit)
        let short = sendPillLabel(commentCount: commentCount, pickCount: pickCount, planLabel: shortWords, hasEdit: hasEdit)
        // The edit keeps its mark while the comments count gives way: "Approve + edit".
        let withEdit = hasEdit
            ? sendPillLabel(commentCount: 0, pickCount: pickCount, planLabel: shortWords, hasEdit: true) : nil
        let bare = sendPillLabel(commentCount: 0, pickCount: pickCount, planLabel: shortWords)
            ?? (commentCount > 0 || hasEdit ? "Send" : nil)
        var forms: [String?] = []
        let candidates: [String?] = hasEdit ? [full, short, withEdit, bare] : [full, short, bare]
        for form in candidates where !forms.contains(form) { forms.append(form) }
        return forms
    }
}

/// The words of a discuss reply (WAG-301) in the delivery banner and the thread. Pure, so they are unit-tested.
enum DiscussCopy {
    /// The option titles of the ids, in the order given; an id with no option reads as itself.
    static func titles(_ ids: [String]?, in options: [Option]) -> [String] {
        (ids ?? []).map { id in options.first(where: { $0.id == id })?.displayTitle ?? id }
    }

    /// "Leaning: Compact, Detailed" and "Ruled out: Wizard", one line each. A side with nothing in it has no line.
    static func lines(leaning: [String], ruledOut: [String]) -> [String] {
        var lines: [String] = []
        if !leaning.isEmpty { lines.append("Leaning: " + leaning.joined(separator: ", ")) }
        if !ruledOut.isEmpty { lines.append("Ruled out: " + ruledOut.joined(separator: ", ")) }
        return lines
    }

    /// "Leaning: Compact, Detailed. Ruled out: Wizard. Does the sidebar hide?" Parts with nothing in them are left out.
    static func banner(leaning: [String], ruledOut: [String], message: String?) -> String {
        var parts: [String] = []
        if !leaning.isEmpty { parts.append("Leaning: " + leaning.joined(separator: ", ")) }
        if !ruledOut.isEmpty { parts.append("Ruled out: " + ruledOut.joined(separator: ", ")) }
        if let message, !message.isEmpty { parts.append(message) }
        return parts.isEmpty ? "Talking it over" : parts.joined(separator: ". ")
    }
}
