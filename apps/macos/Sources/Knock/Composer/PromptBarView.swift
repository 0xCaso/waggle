import AppKit
import SwiftUI

/// The reply field of the prompt bar: an `NSTextView` in a scroll view. The
/// host sets its height (`PromptBarLogic.layout`); this view only edits text,
/// scrolls once the host caps the height, and turns Return into the decision
/// `PromptBarLogic.returnKeyAction` makes.
struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let canSend: Bool
    let onSend: () -> Void
    /// Called on every edit the person makes (never for text the app sets).
    var onEdit: () -> Void = {}
    /// Cmd-V: offered the clipboard first. True when it took a file or an image, so no text is pasted (WAG-345).
    var onPaste: ((NSPasteboard) -> Bool)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false

        let view = PromptNSTextView()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = PromptBarLogic.font
        view.textColor = NSColor(Theme.Colors.ink)
        view.insertionPointColor = NSColor(Theme.Colors.ink)
        view.defaultParagraphStyle = PromptBarLogic.paragraphStyle
        view.typingAttributes = [
            .font: PromptBarLogic.font,
            .foregroundColor: NSColor(Theme.Colors.ink),
            .paragraphStyle: PromptBarLogic.paragraphStyle,
        ]
        view.textContainerInset = PromptBarLogic.textInset
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.string = text
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? PromptNSTextView else { return }
        if view.string != text, !view.hasMarkedText() {
            view.string = text
        }
        context.coordinator.syncFocus(view)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextView
        init(_ parent: PromptTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
            parent.onEdit()
        }

        /// Follows the host's `isFocused` (set by a click on the row, or by
        /// "Open review" asking for the caret).
        func syncFocus(_ view: NSTextView) {
            guard parent.isFocused, let window = view.window, window.firstResponder !== view else { return }
            Task { @MainActor in window.makeFirstResponder(view) }
        }

        func focusChanged(_ focused: Bool) {
            Task { @MainActor in
                if self.parent.isFocused != focused { self.parent.isFocused = focused }
            }
        }
    }
}

final class PromptNSTextView: NSTextView {
    weak var coordinator: PromptTextView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func paste(_ sender: Any?) {
        if let onPaste = coordinator?.parent.onPaste, onPaste(.general) { return }
        super.paste(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { coordinator?.focusChanged(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { coordinator?.focusChanged(false) }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.coordinator?.syncFocus(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter.
        guard event.keyCode == 36 || event.keyCode == 76, let coordinator else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags
        let action = PromptBarLogic.returnKeyAction(
            shift: flags.contains(.shift),
            command: flags.contains(.command),
            hasMarkedText: hasMarkedText(),
            canSend: coordinator.parent.canSend
        )
        switch action {
        case .send: coordinator.parent.onSend()
        case .newline: insertText("\n", replacementRange: selectedRange())
        case .ignore: break
        case .passThrough: super.keyDown(with: event)
        }
    }
}

/// The one prompt bar (WAG-305): "+" attach, the growing field, the quiet buttons and the primary button.
/// Every composer builds it: the options dock, the reply-only footer, the steps bar and the workspace
/// column. It knows nothing of a composer or a doc: the host gives it text, labels and actions.
struct PromptBarCore: View {
    @Binding var text: String
    let placeholder: String
    var maxLines: Int = PromptBarLogic.paneMaxLines
    var quietLabels: [String] = []
    /// The primary label's forms, longest first; `[nil]` is the plain arrow.
    var pillLabels: [String?] = [nil]
    let canSend: Bool
    /// Whether Return sends; `nil` follows `canSend`. False when the button alone may decide (WAG-328).
    var returnSends: Bool? = nil
    /// The arrow stays beside the label when comments or an edit go with the reply.
    var keepsArrow = false
    var quietHelp: (String) -> String? = { _ in nil }
    var onQuiet: (String) -> Void = { _ in }
    let onSend: () -> Void
    var onEdit: () -> Void = {}
    /// The files of the next reply (WAG-345). `nil` keeps a plain "+" that does nothing.
    var files: ComposerAttachments? = nil
    @Binding var isFocused: Bool

    @State private var barWidth: CGFloat = 0

    private var controlsPlan: PromptBarLogic.ControlsPlan {
        PromptBarLogic.controlsPlan(
            rowWidth: barWidth > 0 ? barWidth - PromptBarLogic.barPadding * 2 : nil,
            quietLabels: quietLabels,
            pillLabels: pillLabels
        )
    }

    /// The placeholder is not passed: an empty field keeps the one row and the placeholder is cut at the
    /// tail, so the button never drops to a second row (WAG-305).
    private func layout(_ plan: PromptBarLogic.ControlsPlan) -> PromptBarLogic.Layout {
        PromptBarLogic.layout(text: text, barWidth: barWidth, controlsWidth: plan.width, maxLines: maxLines, forcesOwnRow: plan.ownRow)
    }

    var body: some View {
        let plan = controlsPlan
        let current = layout(plan)
        // The width is read from a zero-height sibling that only ever sees the
        // width offered to the bar, never the width the content asks for.
        // Measuring the content itself feeds the field's own width back into
        // the layout and never settles.
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { barWidth = $0 }
            if let files { AttachmentChipsRow(files: files) }
            barContent(current, plan)
        }
        .modifier(OptionalAttachDrop(files: files))
    }

    private func barContent(_ current: PromptBarLogic.Layout, _ plan: PromptBarLogic.ControlsPlan) -> some View {
        Group {
            if current.isMultiline {
                VStack(alignment: .leading, spacing: PromptBarLogic.rowGap) {
                    field(current)
                        .frame(maxWidth: .infinity)
                    HStack(spacing: PromptBarLogic.controlGap) {
                        attachButton
                        Spacer(minLength: 0)
                        quietButtons(plan)
                        sendButton(plan)
                    }
                }
            } else {
                // Top aligned: every control is one line tall, so the "+" sits on the first text line.
                HStack(alignment: .top, spacing: PromptBarLogic.controlGap) {
                    attachButton
                        .frame(width: PromptBarLogic.controlSize, height: PromptBarLogic.controlSize)
                    field(current)
                        .frame(width: current.singleRowFieldWidth)
                    Spacer(minLength: 0)
                    quietButtons(plan)
                    sendButton(plan)
                }
            }
        }
        .padding(PromptBarLogic.barPadding)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Field

    private func field(_ current: PromptBarLogic.Layout) -> some View {
        ZStack(alignment: .topLeading) {
            if ComposerPlaceholder.isVisible(draftText: text) {
                Text(placeholder)
                    .knockTextStyle(Theme.Typography.body13_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: PromptBarLogic.lineHeight, alignment: .leading)
                    .padding(EdgeInsets(
                        top: PromptBarLogic.textInset.height, leading: PromptBarLogic.textInset.width,
                        bottom: 0, trailing: PromptBarLogic.textInset.width
                    ))
                    .allowsHitTesting(false)
            }
            PromptTextView(
                text: $text,
                isFocused: $isFocused,
                canSend: returnSends ?? canSend,
                onSend: onSend,
                onEdit: onEdit,
                onPaste: files.map { files in { files.add(from: $0) } }
            )
        }
        .frame(height: current.fieldHeight)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }

    // MARK: - Controls

    /// The "+" (WAG-345): a click opens the file picker. Where a host gives no files it stays a plain icon.
    @ViewBuilder
    private var attachButton: some View {
        if let files {
            PromptAttachMenu(files: files)
        } else {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Colors.ink3)
                .frame(width: PromptBarLogic.controlSize, height: PromptBarLogic.controlSize)
        }
    }

    /// The quiet buttons that fit, after a "More" menu holding the ones that do not.
    @ViewBuilder
    private func quietButtons(_ plan: PromptBarLogic.ControlsPlan) -> some View {
        if !plan.overflowLabels.isEmpty {
            PromptOverflowMenu(labels: plan.overflowLabels, action: onQuiet)
        }
        ForEach(plan.quietLabels, id: \.self) { label in
            PromptQuietButton(label: label, help: quietHelp(label), action: { onQuiet(label) })
        }
    }

    private func sendButton(_ plan: PromptBarLogic.ControlsPlan) -> some View {
        let pill = plan.sendPillLabel
        // The full words stay in the tooltip and for VoiceOver when the row shows the short form.
        let fullLabel = pillLabels.first.flatMap { $0 } ?? "Send"
        let foreground = canSend ? Theme.Colors.win : Theme.Colors.ink2
        return Button(action: onSend) {
            HStack(spacing: 6) {
                if let pill {
                    Text(pill)
                        .knockTextStyle(Theme.Typography.promptSend12w600)
                        .fixedSize()
                }
                if pill == nil || keepsArrow {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundColor(foreground)
            .padding(.horizontal, pill == nil ? 0 : 10)
            .frame(minWidth: PromptBarLogic.controlSize)
            .frame(height: PromptBarLogic.controlSize)
            .background(canSend ? Theme.Colors.ink : Theme.Colors.line2)
            .cornerRadius(Theme.Radius.promptButton)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        // Its natural width, always: the row gives way around it, never through it.
        .fixedSize()
        .layoutPriority(1)
        .accessibilityLabel(fullLabel)
        .help(canSend ? (fullLabel == pill || pill == nil ? "Send ⌘↵" : "\(fullLabel) ⌘↵") : "")
    }
}

/// The prompt bar of a composer (HAIL-77): the shared bar, fed by the composer's draft, picks and labels.
struct PromptBarView: View {
    @ObservedObject var composer: ComposerViewModel
    /// Observed so the bar follows every keystroke; the column above does not (HAIL-220).
    @ObservedObject var draft: ComposerDraftText
    @ObservedObject var sendFlow: SendFlowController
    /// The files of the next reply, observed so a chip appears at once and the button wakes (WAG-345).
    @ObservedObject var files: ComposerAttachments
    let commentCount: Int
    let placeholder: String
    var maxLines: Int = PromptBarLogic.paneMaxLines
    /// True for the options card, which accepts the recommendation for a
    /// comments-only reply (its old "Accept recommendation + N comments").
    var acceptsRecommendationWithComments: Bool = false
    /// False in the options card, where "Ask for more detail" is the options list's last row (HAIL-111).
    var showsDetailButton: Bool = true
    var onOpenReview: (() -> Void)? = nil
    /// The simple ask's bar (WAG-257): the button reads "Decide: <option>" once an option is chosen.
    var decides = false
    @Binding var isFocused: Bool
    /// "Change" / "Request changes" was pressed with no note: the field asks what should change until a note exists.
    @State private var asksWhatChanges = false

    private var canSend: Bool {
        PromptBarLogic.canSend(
            hasChoice: composer.hasPick || composer.isDiscussing || composer.hasPrePick,
            hasMessage: composer.currentMessage != nil,
            commentCount: commentCount,
            hasEdit: hasEdit,
            hasFiles: composer.hasFiles
        )
    }

    /// Nothing but the plan round's pre-pick: the button then names it, and only a press on that button decides
    /// (WAG-328). Return and ⌘↵ do nothing.
    private var prePickOnly: Bool { composer.isPrePickOnly(commentCount: commentCount, hasEdit: hasEdit) }

    /// The person's in-place edit travels with this reply (HAIL-168).
    private var hasEdit: Bool { sendFlow.attachedEdit != nil }

    /// Several ticks go out together; the button says how many (HAIL-123).
    private var pickCount: Int { composer.isMultiSelect ? composer.selectedOptionIds.count : 0 }

    private var quietLabels: [String] {
        PromptBarLogic.quietLabels(
            hasOpenReview: onOpenReview != nil, hasDetail: showsDetailButton, planSecondary: composer.planSecondaryLabel)
    }

    /// The short title of the one option chosen, for "Decide: <title>".
    private var decideTitle: String? {
        guard composer.isOptionsCase, !composer.isMultiSelect, let id = composer.selectedOptionId else { return nil }
        let pool = composer.selectedFromFirstOptions ? composer.firstOptions : composer.options
        return pool.first { $0.id == id }?.displayTitle
    }

    /// The primary label's forms, longest first ("Approve section + 1 comment", "Approve + 1 comment", "Approve").
    private var pillLabels: [String?] {
        if prePickOnly {
            return PromptBarLogic.prePickPillLabels(title: decideTitle)
        }
        // A plan round with nothing picked and nothing to send shows the plain arrow, as any request does (WAG-336).
        if PromptBarLogic.plansBareArrow(isPlanRound: composer.planStage != nil, hasOptions: composer.isOptionsCase, canSend: canSend) {
            return [nil]
        }
        if composer.talksOnMany, commentCount == 0, composer.currentMessage == nil, !hasEdit {
            return [PromptBarLogic.sendLabel]
        }
        // Files alone, with no pick, keep the talk going (WAG-345).
        if composer.sendsDiscuss, !composer.isDiscussing, composer.currentMessage == nil, composer.hasFiles,
           commentCount == 0, !hasEdit {
            return [PromptBarLogic.keepTalkingLabel]
        }
        return PromptBarLogic.sendPillLabels(
            commentCount: commentCount, pickCount: pickCount,
            planLabel: composer.planPrimaryLabel, shortPlanLabel: composer.planShortPrimaryLabel, hasEdit: hasEdit,
            decideTitle: decides ? decideTitle : nil,
            isFeedback: !composer.options.isEmpty && !composer.isMultiSelect && !composer.hasPick && composer.currentMessage != nil && !composer.supportsDiscuss,
            discuss: PromptBarLogic.discussLabels(leaning: composer.leaningPositions, ruledOut: composer.ruledOutPositions),
            asks: (composer.sendsDiscuss && !composer.isDiscussing) || (composer.talksOnMany && composer.currentMessage != nil),
            sendsComments: sendFlow.sendsReviewComments || composer.talksOnMany,
            isMany: composer.isMultiSelect,
            withChanges: composer.withChangesKind)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let edit = sendFlow.attachedEdit {
                editChip(edit)
            }
            PromptBarCore(
                text: Binding(get: { composer.draftText }, set: { composer.draftText = $0 }),
                placeholder: composer.currentMessage == nil && asksWhatChanges ? PlanText.whatShouldChange : placeholder,
                maxLines: maxLines,
                quietLabels: quietLabels,
                pillLabels: pillLabels,
                canSend: canSend,
                returnSends: canSend && !prePickOnly,
                keepsArrow: commentCount > 0 || hasEdit,
                quietHelp: quietHelp,
                onQuiet: quietAction,
                onSend: { performSend() },
                onEdit: composer.replyEdited,
                files: files,
                isFocused: $isFocused
            )
        }
        .onAppear {
            applyEvidenceDraft()
            applyEvidenceAttachments()
            EvidenceWindowSnapshot.scheduleIfRequested(delay: 5)
        }
    }

    /// `KNOCK_EVIDENCE_ATTACH=<path>,<path>` (WAG-345 evidence hook): attaches those files on appear, and
    /// `KNOCK_EVIDENCE_ATTACH_SEND=<seconds>` presses Send after that long, since a capture cannot drop or
    /// pick a file. Never set outside evidence runs.
    private func applyEvidenceAttachments() {
        let environment = ProcessInfo.processInfo.environment
        guard files.isEmpty, let list = environment["KNOCK_EVIDENCE_ATTACH"], !list.isEmpty else { return }
        files.add(urls: list.split(separator: ",").map { URL(fileURLWithPath: String($0)) })
        if let raw = environment["KNOCK_EVIDENCE_ATTACH_SEND"], let seconds = Double(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { performSend() }
        }
    }

    /// "Your edit · v2 · 2 passages changed" with Remove (HAIL-168). Remove drops the edit from the
    /// reply; the revision stays in the case's history.
    private func editChip(_ edit: SendFlowController.AttachedEdit) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.line")
                .font(.system(size: 11))
                .foregroundColor(Theme.Colors.ds)
            Text(Self.editChipLabel(revision: edit.revision, passages: edit.passagesChanged))
                .knockTextStyle(Theme.Typography.versionChipLabel11w600)
                .foregroundColor(Theme.Colors.ds)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: sendFlow.removeEdit) {
                Text("Remove")
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            }
            .buttonStyle(.plain).pointerCursor()
            .help("Send the reply without your edit. v\(edit.revision) stays in history.")
        }
        .padding(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
        .background(Theme.Colors.dsSoft)
        .cornerRadius(Theme.Radius.chip)
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 0, trailing: 8))
    }

    static func editChipLabel(revision: Int, passages: Int) -> String {
        "Your edit · v\(revision) · \(passages) \(passages == 1 ? "passage" : "passages") changed"
    }

    /// `KNOCK_EVIDENCE_DRAFT_TEXT=<text>` (HAIL-77 evidence hook): fills an
    /// empty draft on appear so a capture can show a long reply. `\n` in the
    /// value becomes a newline. Never set outside evidence runs.
    private func applyEvidenceDraft() {
        guard composer.draftText.isEmpty,
              let text = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_DRAFT_TEXT"], !text.isEmpty
        else { return }
        composer.draftText = text.replacingOccurrences(of: "\\n", with: "\n")
    }

    private func quietHelp(_ label: String) -> String? {
        guard label == composer.planSecondaryLabel else { return nil }
        return "Write what should change, then press \(label)"
    }

    private func quietAction(_ label: String) {
        switch label {
        case PromptBarLogic.askForDetailLabel:
            composer.beginAskingForDetail()
        case PromptBarLogic.openReviewLabel:
            onOpenReview?()
        case composer.planSecondaryLabel:
            // "Change" / "Request changes" on a design or spec round (HAIL-151): sends the note as a
            // change request; with no note yet it puts the cursor in the field and the field asks what should change.
            if composer.currentMessage == nil { asksWhatChanges = true; isFocused = true } else { sendFlow.sendPlanChange() }
        default:
            break
        }
    }

    /// The button. Every state sends what its title says: a pick, comments or a note go through `send()`, which
    /// never swaps in the recommendation (WAG-328). With only the pre-pick, the title names it ("Decide: X"),
    /// so pressing it makes the pick.
    private func performSend() {
        guard canSend else { return }
        if prePickOnly { composer.confirmPrePick() }
        sendFlow.send()
    }
}

/// A quiet 28 pt text button: 12 pt, weight 500, ink-2, hover fill.
private struct PromptQuietButton: View {
    let label: String
    let help: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .knockTextStyle(Theme.Typography.promptButton12w500)
                .foregroundColor(hovered ? Theme.Colors.ink : Theme.Colors.ink2)
                // Gives way before the primary button if the width estimate is ever short.
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .frame(height: PromptBarLogic.controlSize)
                .background(hovered ? Theme.Colors.hover : Color.clear)
                .cornerRadius(Theme.Radius.promptButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hovered = $0 }
        .help(help ?? "")
    }
}

/// A quiet 28 pt "More" menu holding the quiet buttons a narrow row cannot fit.
private struct PromptOverflowMenu: View {
    let labels: [String]
    let action: (String) -> Void
    @State private var hovered = false

    var body: some View {
        Menu {
            ForEach(labels, id: \.self) { label in
                Button(label) { action(label) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(hovered ? Theme.Colors.ink : Theme.Colors.ink2)
                .frame(width: PromptBarLogic.controlSize, height: PromptBarLogic.controlSize)
                .background(hovered ? Theme.Colors.hover : Color.clear)
                .cornerRadius(Theme.Radius.promptButton)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help("More: \(labels.joined(separator: ", "))")
        .accessibilityLabel("More")
    }
}

/// Applies the drop target only where a host gave files.
private struct OptionalAttachDrop: ViewModifier {
    let files: ComposerAttachments?

    func body(content: Content) -> some View {
        if let files { content.attachesDroppedFiles(to: files) } else { content }
    }
}

/// The "+" of the bar (WAG-345): 28 pt, hover fill. A click opens the file picker at once; "Attach files"
/// is its tooltip (WAG-346). A plain button: a `Menu` adds its own inset and the "+" sat off the text line.
private struct PromptAttachMenu: View {
    @ObservedObject var files: ComposerAttachments
    @State private var hovered = false

    var body: some View {
        Button { files.add(urls: AttachPicker.pick()) } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(hovered ? Theme.Colors.ink : Theme.Colors.ink3)
                .frame(width: PromptBarLogic.controlSize, height: PromptBarLogic.controlSize)
                .background(hovered ? Theme.Colors.hover : Color.clear)
                .cornerRadius(7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .frame(width: PromptBarLogic.controlSize, height: PromptBarLogic.controlSize)
        .onHover { hovered = $0 }
        .help("Attach files")
        .accessibilityLabel("Attach files")
    }
}
