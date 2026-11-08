import SwiftUI

/// The rules of the calm card as plain functions, so a test can check them without hosting a view.
enum CalmOption {
    /// A closed row shows this many words of the description.
    static let shortWords = 8
    /// Opening animates height over 220 ms ease-out. The panel swaps its text with a 200 ms fade.
    static let openDuration = 0.22
    static let swapDuration = 0.2
    static let cardRadius: CGFloat = 16

    /// A row in the bottom bar never expands (WAG-293). The pick's details show in the page ("YOUR PICK").
    static let rowsExpand = false
    static let rowRadius: CGFloat = 12
    /// A ruled-out row dims to this (WAG-301).
    static let ruledOutOpacity = 0.55
    static let leanTip = "I lean to this, but I am not sure"
    static let ruleOutTip = "Rule this out"
    /// The tooltip of a row shows after the pointer rests on the row this long. A chip shows it at once.
    static let tooltipDelay = 0.4
    /// The block in the page swaps its text with a 150 ms fade.
    static let blockFade = 0.15

    /// The counts on the Good and Watch chips. A zero count has no chip.
    static func chipCounts(pros: [String], cons: [String]) -> (good: Int, watch: Int) { (pros.count, cons.count) }
    /// The title of the effects list and the tooltip of its count (WAG-360): "1 effect", "3 effects".
    static let effectsTitle = "If you pick this"
    static func effectsTip(_ count: Int) -> String { "\(count) \(count == 1 ? "effect" : "effects")" }
    static let recommendedPill = "Recommended"
    /// A row title wraps to at most this many lines (WAG-336).
    static let rowTitleLines = 2
    static let recommendedEdge = Theme.Colors.honey500.opacity(0.4)
    static let recommendedTint = Theme.Colors.honeySoft.opacity(0.45)
    /// A locked row and an unticked row at the limit do not react to a click (WAG-379 keeps the rule of WAG-334).
    static func acceptsPick(isLocked: Bool, isLimitDimmed: Bool, isSelected: Bool) -> Bool {
        !isLocked && !(isLimitDimmed && !isSelected)
    }
    /// The focus that a click gives a row comes within this time of the press. It does not open the tooltip.
    static let pointerFocusWindow = Duration.milliseconds(400)
    static func isPointerFocus(_ sincePress: Duration?) -> Bool {
        guard let sincePress else { return false }
        return sincePress < pointerFocusWindow
    }
    static func showsSoftMark(isRecommended: Bool, isSelected: Bool, isLeaning: Bool, isRuledOut: Bool, isLocked: Bool) -> Bool {
        isRecommended && !isSelected && !isLeaning && !isRuledOut && !isLocked
    }
    /// The pill in a tight row (WAG-311): the whole "✦ Recommended" when it fits, else "✦" alone with the word
    /// in its tooltip. It never shows a cut word.
    static let recommendedMark = "✦"
    static func recommendedPillText(availableWidth: CGFloat, fullWidth: CGFloat) -> String {
        availableWidth >= fullWidth ? "\(recommendedMark) \(recommendedPill)" : recommendedMark
    }
    /// The tooltips of the two count marks (WAG-303): "3 good points", "2 things to watch".
    static func goodTip(_ count: Int) -> String { "\(count) good \(count == 1 ? "point" : "points")" }
    static func watchTip(_ count: Int) -> String { "\(count) \(count == 1 ? "thing" : "things") to watch" }
    /// The block label (WAG-303): the plan round's preselected recommendation is not yet the person's pick.
    static func isPick(selectedId: String?, pickIsDefault: Bool) -> Bool { selectedId != nil && !pickIsDefault }

    /// What the page block shows: the pick, or before any pick the recommendation.
    struct PickBlock: Equatable {
        let option: Option
        let position: Int
        let isPick: Bool
    }

    static func pickBlock(options: [Option], selectedId: String?, recommendationId: String?, pickIsDefault: Bool = false) -> PickBlock? {
        if let selectedId, let index = options.firstIndex(where: { $0.id == selectedId }) {
            return PickBlock(option: options[index], position: index + 1, isPick: !pickIsDefault)
        }
        if let recommendationId, let index = options.firstIndex(where: { $0.id == recommendationId }) {
            return PickBlock(option: options[index], position: index + 1, isPick: false)
        }
        return nil
    }

    /// "YOUR PICK · 2", or "RECOMMENDED · 2" before any pick.
    static func blockLabel(position: Int, isPick: Bool, suffix: String? = nil) -> String {
        let base = "\(isPick ? "YOUR PICK" : "RECOMMENDED") · \(position)"
        return suffix.map { base + " · " + $0 } ?? base
    }

    /// The pick of a step point, plain string answers included (WAG-304). Nil without a pick.
    /// A point has no recommendation in the protocol, so there is no "RECOMMENDED" block before a pick.
    static func pointPick(_ point: QuestionPoint, choice: String?) -> (option: PointOption, position: Int)? {
        guard let choice, let index = point.choices.firstIndex(where: { $0.label == choice }) else { return nil }
        return (point.choices[index], index + 1)
    }

    /// The first words of the description for a closed row, with an ellipsis when it was cut.
    static func shortLine(_ description: String?, words: Int = shortWords) -> String? {
        guard let description else { return nil }
        let line = AgentMarkdown.singleLine(description)
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard !parts.isEmpty else { return nil }
        if parts.count <= words { return parts.joined(separator: " ") }
        return parts.prefix(words).joined(separator: " ") + "…"
    }

    /// The grey note: the recommendation's why on the recommended option; on the others only their own
    /// why, when the agent sent one.
    static func note(for option: Option, isRecommended: Bool, recommendationWhy: String?) -> String? {
        let clean = { (text: String?) -> String? in
            guard let text else { return nil }
            let line = AgentMarkdown.singleLine(text, keepingSources: true)
            return AgentMarkdown.singleLine(line).isEmpty ? nil : line
        }
        if isRecommended, let why = clean(recommendationWhy) { return why }
        return clean(option.why)
    }

    /// The description under the title, unless it only repeats the title.
    static func description(of option: Option, position: Int) -> String? {
        let body = OptionLabelFormatting.decisionBody(label: option.label, title: option.displayTitle)
        let entry = DecisionSectionView.Entry(position: position, title: option.displayTitle, label: body, isRecommended: false)
        return entry.showsLabel ? body : nil
    }

    /// "YOUR PICK · 2 MERGE AS IT IS".
    static func pickLabel(_ option: Option, position: Int) -> String {
        "YOUR PICK · \(position) \(AgentMarkdown.singleLine(option.displayTitle).uppercased())"
    }
}

/// WAG-357: the item and the option the recommended block (and its Good and Watch out lists) speaks of, so a comment on
/// its words names them. `nil` ids mean the block takes no comment (an option row).
struct AskCommentIds: Equatable {
    var itemId: String?
    var optionId: String?
}

/// The Good and Watch out lists (WAG-281): two columns on the decision page, one in the side panel.
struct GoodWatchOutView: View {
    let pros: [String]
    let cons: [String]
    var columns = true
    /// WAG-357: set on the recommended block of the page. The lines of an option row take no comment.
    var commentIds: AskCommentIds? = nil

    var body: some View {
        if !pros.isEmpty || !cons.isEmpty {
            Group {
                if columns {
                    HStack(alignment: .top, spacing: 28) {
                        list("Good", lines: pros, color: Theme.Colors.ok, part: .pro)
                        list("Watch out", lines: cons, color: Theme.AskDoc.Colors.watch, part: .con)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        list("Good", lines: pros, color: Theme.Colors.ok, part: .pro)
                        list("Watch out", lines: cons, color: Theme.AskDoc.Colors.watch, part: .con)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func list(_ title: String, lines: [String], color: Color, part: AskTextPart) -> some View {
        if !lines.isEmpty {
            let bases = commentIds == nil ? [] : AskTextContent.lineBases(lines)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(color).frame(width: 6, height: 6).offset(y: -1)
                        SourcedText(
                            text: line, style: Theme.AskDoc.Typography.optionCard13, color: Theme.Colors.ink2,
                            target: commentIds.map {
                                AskCommentTarget(part, itemId: $0.itemId, optionId: $0.optionId, slot: "\(index)", baseOffset: bases[index])
                            })
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(title): \(AgentMarkdown.singleLine(line))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The effects of an option (WAG-360): "If you pick this" and up to 3 lines. Always one full-width column, below
/// Good and Watch out. It looks like one Good column, with neutral ink3 for the title and the dots.
struct EffectsView: View {
    let effects: [String]
    /// WAG-357: set on the recommended block of the page. The lines of an option row take no comment.
    var commentIds: AskCommentIds? = nil

    var body: some View {
        if !effects.isEmpty {
            let bases = commentIds == nil ? [] : AskTextContent.lineBases(effects)
            VStack(alignment: .leading, spacing: 5) {
                Text(CalmOption.effectsTitle)
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .fontWeight(.semibold)
                    .foregroundColor(Theme.Colors.ink3)
                ForEach(Array(effects.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.Colors.ink3).frame(width: 6, height: 6).offset(y: -1)
                        SourcedText(
                            text: line, style: Theme.AskDoc.Typography.optionCard13, color: Theme.Colors.ink2,
                            target: commentIds.map {
                                AskCommentTarget(.effect, itemId: $0.itemId, optionId: $0.optionId, slot: "\(index)", baseOffset: bases[index])
                            })
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(CalmOption.effectsTitle): \(AgentMarkdown.singleLine(line))")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The quiet grey note "Why I recommend it" (or just "Why" on an option's own reason).
struct CalmNoteView: View {
    let title: String
    let text: String
    /// WAG-357: set on the reason in the recommended block of the page. `nil` in an option row.
    var target: AskCommentTarget? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .fontWeight(.semibold)
                .foregroundColor(OptionText.whyLabelColor)
            SourcedText(text: text, style: OptionText.whyStyle, color: OptionText.whyColor, target: target)
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.list)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    static func title(isRecommended: Bool) -> String { isRecommended ? "Why I recommend it" : "Why" }
}

/// Level 2 of an option's text (WAG-288): the description, body 13 regular in ink2, one step under the
/// semibold ink title. Every view that shows an option's description uses this one view.
struct OptionDescriptionView: View {
    let text: String

    var body: some View {
        AgentMarkdownText(text: text, style: OptionText.descriptionStyle, color: OptionText.descriptionColor, showsSources: true)
    }
}

/// The three text levels of an option (WAG-288): the title, the description (`OptionDescriptionView`) and
/// the why (`CalmNoteView`, a small soft block with a label). One place for the values.
enum OptionText {
    static let descriptionStyle = Theme.Typography.body13w400
    static let descriptionColor = Theme.Colors.ink2
    static let whyStyle = Theme.Typography.body12_5w400
    static let whyColor = Theme.Colors.ink2
    static let whyLabelColor = Theme.Colors.ink3
}

/// The number chip of an option: honey when it is the pick.
struct CalmNumberChip: View {
    let position: Int
    let isSelected: Bool

    var body: some View {
        Text("\(position)")
            .knockTextStyle(Theme.Typography.keyBadge12w600)
            .foregroundColor(Theme.Colors.ink)
            .frame(width: 24, height: 24)
            .background(isSelected ? Theme.Colors.honey500 : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(isSelected ? Theme.Colors.honey600 : Theme.Colors.line, lineWidth: 1))
    }
}

/// One option row of the bottom bar (WAG-293, WAG-296): number, title, "Good n" and "Watch n" chips, then the
/// "✦ Recommended" pill. The description lives in the tooltip. It never expands. The pick has the honey stroke and soft fill. A rest of
/// the pointer on a chip (or on the row for 400 ms), or keyboard focus, opens a tooltip above the bar.
struct CompactOptionRow: View {
    let position: Int
    let title: String
    var description: String? = nil
    var pros: [String] = []
    var cons: [String] = []
    var effects: [String] = []
    var note: String? = nil
    let isSelected: Bool
    var isRecommended = false
    var isLocked = false
    /// Lean and rule out (WAG-301). The two icons show when `onLean` and `onRuleOut` are set and the row is not locked.
    var isLeaning = false
    var isRuledOut = false
    var onLean: (() -> Void)? = nil
    var onRuleOut: (() -> Void)? = nil
    /// A pick-many row (WAG-329): a check box in front of the number, and the tick is the state. Same row, same
    /// pill, same counts and tooltip as a single ask. `isLimitDimmed` is an unticked row once the ticks reach `max`.
    var isCheckbox = false
    var isLimitDimmed = false
    let onSelect: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsTip = false
    @State private var hoverTask: Task<Void, Never>?
    /// The press state is read in no body, so it lives in a class: a write does not draw the row again.
    @State private var press = PressState()
    @FocusState private var isFocused: Bool

    /// The recommended row, not picked, ruled out or leaned to: the Recommended pill plus a light honey edge and tint.
    /// It is not a selection: no check, no filled radio (WAG-336).
    private var softMark: Bool { CalmOption.showsSoftMark(isRecommended: isRecommended, isSelected: isSelected, isLeaning: isLeaning, isRuledOut: isRuledOut, isLocked: isLocked) }
    private var counts: (good: Int, watch: Int) { CalmOption.chipCounts(pros: pros, cons: cons) }
    private var hasTip: Bool { Self.hasTip(description: description, pros: pros, cons: cons, effects: effects, note: note) }

    /// The tooltip opens for a row with a description, a list (Good, Watch out or effects) or a note.
    static func hasTip(description: String?, pros: [String], cons: [String], effects: [String] = [], note: String?) -> Bool {
        description != nil || !pros.isEmpty || !cons.isEmpty || !effects.isEmpty || note != nil
    }

    /// "Recommended" is part of the spoken label of the recommended option.
    static func accessibilityLabel(title: String, isRecommended: Bool) -> String {
        isRecommended ? "\(title), \(CalmOption.recommendedPill)" : title
    }

    private static func stamp() -> String { String(format: "%.1f", ProcessInfo.processInfo.systemUptime * 1000) }

    var body: some View {
        let _ = RunLoopTurnProbe.startIfLogging()
        let _ = isSelected && EvidenceLayoutLog.enabled ? { RunLoopTurnProbe.wantsDrawn = true }() : ()
        let _ = isSelected ? EvidenceLayoutLog.event("opt.sel", "t=\(Self.stamp()) pos=\(position) tip=\(showsTip)") : ()
        HStack(spacing: 10) {
            if isCheckbox { CheckBoxMark(isTicked: isSelected) }
            CalmNumberChip(position: position, isSelected: isSelected && !isCheckbox)
            Text(OptionLabelFormatting.cutAtWord(title, limit: OptionLabelFormatting.maxRowTitleLength))
                .knockTextStyle(Theme.Typography.value13_5w600)
                .foregroundColor(Theme.Colors.ink)
                .strikethrough(isRuledOut, color: Theme.Colors.ink)
                // A long title wraps to two lines, never an ellipsis beside the counts and icons (WAG-336).
                .lineLimit(CalmOption.rowTitleLines)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
            Spacer(minLength: 6)
            if counts.good > 0 { countMark("checkmark.circle", counts.good, Theme.Colors.ok, CalmOption.goodTip(counts.good)) }
            if counts.watch > 0 { countMark("exclamationmark.triangle", counts.watch, Theme.AskDoc.Colors.watch, CalmOption.watchTip(counts.watch)) }
            if !effects.isEmpty { countMark("arrow.right", effects.count, Theme.Colors.ink3, CalmOption.effectsTip(effects.count)) }
            if isLocked && isSelected {
                tag("checkmark", "Your answer", Theme.Colors.ink2)
            } else if isRecommended {
                // The pill gives way before the title does: the word goes first, then only the mark is left.
                ViewThatFits(in: .horizontal) {
                    chip("\(CalmOption.recommendedMark) \(CalmOption.recommendedPill)", Theme.Colors.recommendedTagText, Theme.Colors.honeySoft)
                        .fixedSize()
                    chip(CalmOption.recommendedMark, Theme.Colors.recommendedTagText, Theme.Colors.honeySoft)
                        .fixedSize()
                        .help(CalmOption.recommendedPill)
                }
                .layoutPriority(0)
            }
            if !isLocked, let onLean, let onRuleOut {
                HStack(spacing: 2) {
                    DiscussIconButton(kind: .lean, isOn: isLeaning, optionTitle: title, action: onLean)
                    DiscussIconButton(kind: .ruleOut, isOn: isRuledOut, optionTitle: title, action: onRuleOut)
                }
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.Colors.honeySoft : isLeaning ? Theme.Colors.dsSoft : softMark ? CalmOption.recommendedTint : Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: CalmOption.rowRadius))
        .overlay(
            RoundedRectangle(cornerRadius: CalmOption.rowRadius)
                .stroke(
                    isSelected ? Theme.Colors.honey500 : isLeaning ? Theme.Colors.ds
                        : softMark ? CalmOption.recommendedEdge : Theme.Colors.line,
                    lineWidth: isSelected || isLeaning ? 1.5 : 1))
        .opacity(
            isLimitDimmed && !isSelected ? OptionChipView.limitDimmedOpacity
                : isLocked && !isSelected ? 0.45 : isRuledOut ? CalmOption.ruledOutOpacity : 1
        )
        .contentShape(RoundedRectangle(cornerRadius: CalmOption.rowRadius))
        // The row acts on the press, not on the release (WAG-379): the pick shows at once, and a tooltip that is
        // open or about to open never holds it back. A tooltip window can take the release of a click that opened
        // it, so a tap gesture there could wait for the tooltip, or never fire.
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in pressRow() }.onEnded { _ in press.isPressing = false })
        .pointerCursor()
        .allowsHitTesting(!isLocked)
        .focusable(hasTip).focused($isFocused).focusEffectDisabled()
        .onChange(of: showsTip) { _, shown in EvidenceLayoutLog.event("opt.tipOn", "t=\(Self.stamp()) shown=\(shown) focus=\(isFocused)") }
        .onChange(of: isFocused) { _, focused in
            if focused {
                // A click focuses the row too, but only keyboard focus opens the tooltip.
                showsTip = hasTip && !CalmOption.isPointerFocus(press.at.map { $0.duration(to: .now) })
            } else { hideTip() }
        }
        .onHover { inside in
            hoverTask?.cancel()
            if inside, hasTip {
                hoverTask = Task {
                    try? await Task.sleep(for: .seconds(CalmOption.tooltipDelay))
                    if !Task.isCancelled { showsTip = true }
                }
            } else {
                showsTip = false
            }
        }
        .background(
            OptionTipPresenter(isPresented: showsTip, onDismiss: { showsTip = false }) {
                OptionTooltipView(description: description, pros: pros, cons: cons, effects: effects, note: note, isRecommended: isRecommended)
            })
        .overlay(alignment: .top) {
            // Evidence only: a popover is its own window, which the window snapshot cannot see, so
            // `KNOCK_EVIDENCE_OPTION_TIP=<position>` draws the same tooltip content above that row.
            if hasTip, ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_OPTION_TIP"] == String(position) {
                OptionTooltipView(description: description, pros: pros, cons: cons, effects: effects, note: note, isRecommended: isRecommended)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Theme.Colors.win)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Colors.line, lineWidth: 1))
                    .frame(height: 0, alignment: .bottom)
                    .offset(y: -6)
            }
        }
        .zIndex(ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_OPTION_TIP"] == String(position) ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel(title: title, isRecommended: isRecommended))
        .accessibilityHint(description.map { AgentMarkdown.singleLine($0) } ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(
            (isCheckbox
                ? OptionChipView.checkboxAccessibilityValue(isSelected: isSelected, isLocked: isLocked)
                : OptionChipView.accessibilityValue(isSelected: isSelected, isLocked: isLocked))
                + (isLeaning ? "leaning" : isRuledOut ? "ruled out" : ""))
    }

    final class PressState {
        var isPressing = false
        var at: ContinuousClock.Instant?
    }

    /// One press: closes the tooltip and picks the row. `isPressing` keeps a held press from picking twice.
    private func pressRow() {
        guard !press.isPressing else { return }
        press.isPressing = true
        press.at = .now
        EvidenceLayoutLog.event("opt.tap", "t=\(Self.stamp()) pos=\(position)")
        hideTip()
        if CalmOption.acceptsPick(isLocked: isLocked, isLimitDimmed: isLimitDimmed, isSelected: isSelected) { onSelect() }
    }

    private func hideTip() { hoverTask?.cancel(); showsTip = false }

    private func chip(_ text: String, _ color: Color, _ fill: Color) -> some View {
        Text(text)
            .knockTextStyle(Theme.Typography.tagLabel10_5w500)
            .foregroundColor(color)
            .lineLimit(1)
            .padding(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            .background(fill)
            .clipShape(Capsule())
            // The pill gives way before the title does (WAG-306, F11).
            .layoutPriority(0)
            .onHover { inside in if inside, hasTip { hoverTask?.cancel(); showsTip = true } }
    }

    /// An icon and a number, no words and no fill (WAG-303). It has its own tooltip; a rest on it also opens the row tooltip.
    private func countMark(_ symbol: String, _ count: Int, _ color: Color, _ tip: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text("\(count)").knockTextStyle(Theme.Typography.tagLabel10_5w500).monospacedDigit()
        }
        .foregroundColor(color)
        .lineLimit(1)
        // A count never shows cut ("✓ 2" is never "✓ :"): the title gives way before it does (WAG-311).
        .fixedSize()
        .layoutPriority(0)
        .help(tip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tip)
        .onHover { inside in if inside, hasTip { hoverTask?.cancel(); showsTip = true } }
    }

    private func tag(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundColor(color)
            Text(text).knockTextStyle(Theme.Typography.tagLabel10_5w500).foregroundColor(color).lineLimit(1)
        }
        .layoutPriority(0)
    }
}

/// The right half of a disc. The lean icon (WAG-301, WAG-303) is an outline circle with this half filled:
/// off in ink3, on in `ds`.
struct HalfDiscShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(center: c, radius: r, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// The two small icon buttons at the end of an option row (WAG-301): lean (half circle) and rule out (×).
/// Both toggle. Each is focusable with a visible focus ring, and VoiceOver names the action and the option.
struct DiscussIconButton: View {
    enum Kind { case lean, ruleOut }

    let kind: Kind
    let isOn: Bool
    let optionTitle: String
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var hovered = false

    static func accessibilityLabel(kind: Kind, optionTitle: String) -> String {
        switch kind {
        case .lean: return "Lean to \(optionTitle)"
        case .ruleOut: return "Rule out \(optionTitle)"
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                switch kind {
                case .lean:
                    let color = isOn ? Theme.Colors.ds : Theme.Colors.ink3
                    ZStack {
                        Circle().stroke(color, lineWidth: 1.2)
                        HalfDiscShape().fill(color)
                    }
                    .frame(width: 13, height: 13)
                case .ruleOut:
                    if isOn {
                        Circle().fill(Theme.AskDoc.Colors.watch).frame(width: 16, height: 16)
                            .overlay(Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(Theme.Colors.win))
                    } else {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.Colors.ink3)
                    }
                }
            }
            .frame(width: 24, height: 24)
            .background(hovered && !isOn ? Theme.Colors.hover : Color.clear)
            .clipShape(Circle())
            .overlay(Circle().stroke(Theme.Colors.ds, lineWidth: 2).opacity(isFocused ? 1 : 0))
            .contentShape(Circle())
        }
        .buttonStyle(.plain).pointerCursor()
        .focusable().focused($isFocused).focusEffectDisabled()
        .onHover { hovered = $0 }
        .help(kind == .lean ? CalmOption.leanTip : CalmOption.ruleOutTip)
        .accessibilityLabel(Self.accessibilityLabel(kind: kind, optionTitle: optionTitle))
        .accessibilityValue(isOn ? "on" : "off")
    }
}

/// The tooltip of a bar row: the full description, Good, Watch out and the why of that option.
struct OptionTooltipView: View {
    var description: String? = nil
    let pros: [String]
    let cons: [String]
    var effects: [String] = []
    var note: String? = nil
    var isRecommended = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description { OptionDescriptionView(text: description) }
            GoodWatchOutView(pros: pros, cons: cons, columns: false)
            EffectsView(effects: effects)
            if let note { CalmNoteView(title: CalmNoteView.title(isRecommended: isRecommended), text: note) }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

/// One option in the bottom bar of a decision (WAG-281, WAG-293): a compact row.
struct CalmOptionRowView: View {
    let option: Option
    let position: Int
    let isSelected: Bool
    let isRecommended: Bool
    var isLocked = false
    var recommendationWhy: String? = nil
    var isLeaning = false
    var isRuledOut = false
    var onLean: (() -> Void)? = nil
    var onRuleOut: (() -> Void)? = nil
    var isCheckbox = false
    var isLimitDimmed = false
    let onSelect: () -> Void

    var body: some View {
        CompactOptionRow(
            position: position, title: option.displayTitle,
            description: CalmOption.description(of: option, position: position),
            pros: option.pros, cons: option.cons, effects: option.effects,
            note: CalmOption.note(for: option, isRecommended: isRecommended, recommendationWhy: recommendationWhy),
            isSelected: isSelected, isRecommended: isRecommended, isLocked: isLocked,
            isLeaning: isLeaning, isRuledOut: isRuledOut, onLean: onLean, onRuleOut: onRuleOut,
            isCheckbox: isCheckbox, isLimitDimmed: isLimitDimmed, onSelect: onSelect)
    }
}

/// "YOUR PICK · 2" (or "RECOMMENDED · 2" before any pick) in the page (WAG-293): a honey-stroke card with the
/// title, the full description, Good and Watch out, and the why. A new pick swaps it with a 150 ms fade.
struct YourPickBlockView: View {
    let label: String
    /// `nil` for a recommendation that names no option (an older ask's free text): the card shows the why alone.
    let title: String?
    var description: String? = nil
    var pros: [String] = []
    var cons: [String] = []
    var effects: [String] = []
    var note: String? = nil
    var noteTitle = "Why"
    var columns = true
    /// Changes with the pick, so the card fades.
    let swapId: String
    /// WAG-357: the item and option the card speaks of. Its title, reason, Good and Watch out take comments.
    var commentIds: AskCommentIds? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) { content.id(swapId).transition(reduceMotion ? .identity : .opacity) }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .animation(reduceMotion ? nil : .easeOut(duration: CalmOption.blockFade), value: swapId)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                .foregroundColor(Theme.Colors.honey600)
                .lineLimit(1)
            if let title {
                if let ids = commentIds {
                    SourcedText(
                        text: AgentMarkdown.singleLine(title), style: Theme.Typography.value13_5w600, color: Theme.Colors.ink,
                        target: AskCommentTarget(.recommendation, itemId: ids.itemId, optionId: ids.optionId, slot: "title"), weight: .semibold)
                } else {
                    Text(AgentMarkdown.singleLine(title))
                        .knockTextStyle(Theme.Typography.value13_5w600)
                        .foregroundColor(Theme.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let description { OptionDescriptionView(text: description) }
            GoodWatchOutView(pros: pros, cons: cons, columns: columns, commentIds: commentIds)
            EffectsView(effects: effects, commentIds: commentIds)
            if let note {
                CalmNoteView(
                    title: noteTitle, text: note,
                    target: commentIds.map {
                        // The reason follows the title in the plain text of the recommendation.
                        let start = title.map { AskTextContent.plainLength(of: AgentMarkdown.singleLine($0), mode: .line) + 1 } ?? 0
                        return AskCommentTarget(.recommendation, itemId: $0.itemId, optionId: $0.optionId, slot: "reason", baseOffset: start)
                    })
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: CalmOption.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: CalmOption.cardRadius).stroke(Theme.Colors.honey500, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
    }
}

/// The page block of a simple decision. It watches the composer, so it follows the pick.
struct DecisionPickBlockView: View {
    @ObservedObject var composer: ComposerViewModel
    var isLocked = false
    var yourAnswerOptionId: String? = nil
    var columns = true

    var body: some View {
        if composer.isMultiSelect {
            manyCard
        } else if let block = CalmOption.pickBlock(
               options: composer.options,
               selectedId: isLocked ? yourAnswerOptionId : composer.selectedOptionId,
               recommendationId: composer.knockCase.recommendation,
               pickIsDefault: !isLocked && composer.pickIsDefault) {
            let isRecommended = block.option.id == composer.knockCase.recommendation
            YourPickBlockView(
                label: CalmOption.blockLabel(position: block.position, isPick: block.isPick),
                title: block.option.displayTitle,
                description: CalmOption.description(of: block.option, position: block.position),
                pros: block.option.pros, cons: block.option.cons, effects: block.option.effects,
                note: CalmOption.note(for: block.option, isRecommended: isRecommended, recommendationWhy: composer.knockCase.recommendationWhy),
                noteTitle: CalmNoteView.title(isRecommended: isRecommended),
                columns: columns, swapId: block.option.id + (block.isPick ? "" : "-rec"),
                commentIds: AskCommentIds(itemId: nil, optionId: block.option.id))
        }
    }

    /// A pick-several ask shows its recommendation as one card, "RECOMMENDED · 1 and 2", with the reason (WAG-334).
    /// It goes once the person ticks: their own ticks stand (WAG-329). The same card an item in a step has.
    @ViewBuilder
    private var manyCard: some View {
        if let card = Self.manyCard(
            options: composer.options, recommendations: composer.knockCase.recommendations,
            why: composer.knockCase.recommendationWhy, hasPick: composer.hasPick, isLocked: isLocked) {
            YourPickBlockView(
                label: card.label, title: card.title, note: card.note, noteTitle: CalmNoteView.title(isRecommended: true),
                columns: columns, swapId: "many-rec", commentIds: AskCommentIds(itemId: nil, optionId: nil))
        }
    }

    /// The words of the pick-several card, or `nil` when it does not show (locked, ticked, or nothing recommended).
    static func manyCard(
        options: [Option], recommendations: [String], why: String, hasPick: Bool, isLocked: Bool
    ) -> (label: String, title: String, note: String?)? {
        let picked = options.enumerated().filter { recommendations.contains($0.element.id) }
        guard !isLocked, !hasPick, !picked.isEmpty else { return nil }
        let reason = AgentMarkdown.singleLine(why, keepingSources: true)
        return (
            "RECOMMENDED · " + PromptBarLogic.positionList(picked.map { $0.offset + 1 }),
            picked.map { $0.element.displayTitle }.joined(separator: ", "), reason.isEmpty ? nil : reason)
    }
}
