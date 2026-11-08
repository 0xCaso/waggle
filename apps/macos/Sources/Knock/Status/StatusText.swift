import AppKit
import Combine
import SwiftUI

/// A font for the status labels and timers (HAIL-66). They are AppKit views, so
/// this names the Inter or JetBrains Mono face the way `Theme.Typography` does.
struct StatusFont: Equatable {
    var size: CGFloat
    var weight: NSFont.Weight = .regular
    var mono = false

    static let label = StatusFont(size: 12.5, weight: .medium)
    static let labelStrong = StatusFont(size: 12.5, weight: .semibold)
    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> StatusFont {
        StatusFont(size: size, weight: weight)
    }
    static let timer = StatusFont(size: 11.5, mono: true)

    /// Resolved once per face: font matching costs more than a layout pass can
    /// spare, and the labels ask for it in every `sizeThatFits` and baseline guide.
    var nsFont: NSFont {
        let key = FontKey(size: size, weight: weight.rawValue, mono: mono)
        if let font = Self.resolved.font(for: key) { return font }
        let family = mono ? Theme.FontFamily.mono : Theme.FontFamily.sans
        let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
            .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        let font = NSFont(descriptor: descriptor, size: size)
            ?? (mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight))
        Self.resolved.store(font, for: key)
        return font
    }

    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let mono: Bool
    }

    /// NSFont is immutable, so handing one across threads is safe.
    private final class FontCache: @unchecked Sendable {
        private let lock = NSLock()
        private var fonts: [FontKey: NSFont] = [:]
        func font(for key: FontKey) -> NSFont? { lock.withLock { fonts[key] } }
        func store(_ font: NSFont, for key: FontKey) { lock.withLock { fonts[key] = font } }
    }

    private static let resolved = FontCache()
}

/// The width a one-line string needs in a label (without the field's own 2 pt
/// inset on each side), from the font's own advances. `NSTextField.
/// intrinsicContentSize` came out short for Inter at small sizes and truncated
/// the label.
@MainActor
private func textWidth(_ field: NSTextField) -> CGFloat {
    guard let font = field.font else { return field.intrinsicContentSize.width }
    let measured = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
    return ceil(max(measured, field.intrinsicContentSize.width - 4))
}

extension StatusFont {
    /// Where the baseline of this font's one line sits below the top of a view
    /// `height` tall that centres the line (HAIL-70). SwiftUI does not read an
    /// AppKit label's own baseline, so the status views state it.
    func baselineFromTop(height: CGFloat) -> CGFloat {
        let font = nsFont
        let line = font.ascender - font.descender + font.leading
        return (height - line) / 2 + font.ascender
    }
}

extension View {
    /// Centres a pixel grid on the x-height of the text beside it. Use in an
    /// `HStack(alignment: .firstTextBaseline)` (HAIL-70).
    func centredOnXHeight(of fontSize: CGFloat) -> some View {
        alignmentGuide(.firstTextBaseline) { $0.height / 2 + fontSize * 0.55 / 2 - 1 }
    }
}

/// A one-line, non-editable text field with no chrome.
@MainActor
private func makeLabel() -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.isBezeled = false
    field.drawsBackground = false
    field.isSelectable = false
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.cell?.usesSingleLineMode = true
    return field
}

/// A label with a light band sweeping across it (HAIL-66): ink-3, then ink,
/// then ink-3 again, one 1.4 s linear loop, drawn through a gradient mask. The
/// sweep is one Core Animation animation, so it costs the app nothing per
/// frame. Frozen (plain ink-3) under Reduce Motion or with no visible window.
struct ShimmerLabel: View {
    let text: String
    var font: StatusFont = .label
    /// False draws a still label in `base`.
    var shimmers = true
    var base: Color = Theme.Colors.ink3

    static let period: TimeInterval = 1.4

    /// Where the band sits, 0 (left of the text) ... 1 (right of it).
    nonisolated static func sweep(at time: TimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: period) / period
    }

    var body: some View {
        ShimmerRepresentable(text: text, font: font, shimmers: shimmers, base: base)
            .alignmentGuide(.firstTextBaseline) { font.baselineFromTop(height: $0.height) }
    }
}

private struct ShimmerRepresentable: NSViewRepresentable {
    let text: String
    var font: StatusFont = .label
    /// False draws a still label in `base`.
    var shimmers = true
    var base: Color = Theme.Colors.ink3

    func makeNSView(context: Context) -> ShimmerNSView { ShimmerNSView() }

    func updateNSView(_ view: ShimmerNSView, context: Context) {
        view.configure(text: text, font: font, base: NSColor(base), shimmers: shimmers)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShimmerNSView, context: Context) -> CGSize? {
        nsView.configure(text: text, font: font, base: NSColor(base), shimmers: shimmers)
        return nsView.fitting(width: proposal.width)
    }
}

@MainActor
final class ShimmerNSView: NSView {
    private let baseField = makeLabel()
    private let bandField = makeLabel()
    private let mask = CAGradientLayer()
    private var shimmers = false
    /// The size the sweep was last set up for: a layout pass at the same size keeps the running animation.
    private var animatedSize: CGSize?
    private var subscription: AnyCancellable?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(baseField)
        addSubview(bandField)
        bandField.textColor = NSColor(Theme.Colors.ink)
        bandField.wantsLayer = true
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0.35, 0.5, 0.65]
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        bandField.layer?.mask = mask
        setAccessibilityElement(false)
        subscription = MotionGate.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyMotion() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }


    func configure(text: String, font: StatusFont, base: NSColor, shimmers: Bool) {
        let nsFont = font.nsFont
        if baseField.stringValue != text { baseField.stringValue = text; bandField.stringValue = text }
        if baseField.font != nsFont { baseField.font = nsFont; bandField.font = nsFont }
        if baseField.textColor != base { baseField.textColor = base }
        if self.shimmers != shimmers {
            self.shimmers = shimmers
            applyMotion()
        }
    }

    func fitting(width: CGFloat?) -> CGSize {
        let ideal = baseField.intrinsicContentSize
        let wide = textWidth(baseField)
        return CGSize(width: ceil(min(wide, width ?? wide)), height: ceil(ideal.height))
    }

    override func layout() {
        super.layout()
        // NSTextField insets its text by 2 pt; pull it back so the text sits on the view's edge.
        let textFrame = bounds.insetBy(dx: -2, dy: 0)
        baseField.frame = textFrame
        bandField.frame = textFrame
        if bounds.size != animatedSize { applyMotion() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMotion()
    }

    private func applyMotion() {
        let running = shimmers && window != nil && MotionGate.shared.animates && bounds.width > 0
        animatedSize = running ? bounds.size : nil
        bandField.isHidden = !running
        mask.removeAllAnimations()
        guard running else { return }
        let width = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A gradient twice the text wide, its band in the middle third.
        mask.bounds = CGRect(x: 0, y: 0, width: width * 2, height: bounds.height)
        mask.position = CGPoint(x: -width * 0.3, y: bounds.height / 2)
        CATransaction.commit()
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -width * 0.3
        sweep.toValue = width * 1.3
        sweep.duration = ShimmerLabel.period
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.beginTime = mask.convertTime(PixelClock.epoch, from: nil)
        mask.add(sweep, forKey: "sweep")
    }
}

/// How long something took, as text (HAIL-66): whole seconds only (operator,
/// 29 Sep: "no need to show the .x s"). "12s" under a minute, "3m 12s" under
/// an hour, "1h 4m" after.
enum ElapsedFormat {
    static func string(seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        let minutes = total / 60
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// Ticks every visible timer from one 10 Hz clock (HAIL-66): one `Timer` for
/// the whole app, alive only while a timer sits in a visible window, and each
/// timer only redraws when it is on screen.
@MainActor
final class ElapsedClock {
    static let shared = ElapsedClock()
    private let members = NSHashTable<ElapsedNSView>.weakObjects()
    private var timer: Timer?
    private var subscription: AnyCancellable?

    private init() {
        subscription = MotionGate.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.update() }
        }
    }

    func register(_ view: ElapsedNSView) {
        members.add(view)
        update()
    }

    func unregister(_ view: ElapsedNSView) {
        members.remove(view)
        update()
    }

    private func update() {
        let wanted = MotionGate.shared.isVisible && members.count > 0
        if wanted, timer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !wanted {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        let now = Date()
        for view in members.allObjects { view.tick(now: now) }
    }
}

/// The live timer (HAIL-66): mono, tabular, counting up from `since`. It ticks
/// only while a Knock window is visible and the timer is on screen, and keeps
/// ticking under Reduce Motion.
struct ElapsedTimer: View {
    let since: Date
    var font: StatusFont = .timer
    var color: Color = Theme.Colors.ink3

    /// Bumped when the text gets a digit wider or narrower, to ask SwiftUI for a new size.
    @State private var layoutToken = 0

    var body: some View {
        ElapsedRepresentable(since: since, font: font, color: NSColor(color), layoutToken: $layoutToken)
            .alignmentGuide(.firstTextBaseline) { font.baselineFromTop(height: $0.height) }
    }
}

private struct ElapsedRepresentable: NSViewRepresentable {
    let since: Date
    let font: StatusFont
    let color: NSColor
    @Binding var layoutToken: Int

    func makeNSView(context: Context) -> ElapsedNSView {
        let view = ElapsedNSView()
        // Deferred: refresh() also runs inside SwiftUI's own layout pass (sizeThatFits), where a
        // state write is dropped and the timer keeps the width of its shorter, earlier text.
        view.onWidthChange = { [binding = $layoutToken] in
            DispatchQueue.main.async { binding.wrappedValue += 1 }
        }
        return view
    }

    func updateNSView(_ view: ElapsedNSView, context: Context) {
        _ = layoutToken
        view.configure(since: since, font: font, color: color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ElapsedNSView, context: Context) -> CGSize? {
        nsView.configure(since: since, font: font, color: color)
        return nsView.fitting
    }
}

@MainActor
final class ElapsedNSView: NSView {
    private let field = makeLabel()
    private var since = Date()
    private var lastUpdate = Date.distantPast
    private var shownWidth: CGFloat = 0
    var onWidthChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(field)
        field.lineBreakMode = .byClipping
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }


    func configure(since: Date, font: StatusFont, color: NSColor) {
        self.since = since
        let nsFont = font.nsFont
        if field.font != nsFont { field.font = nsFont }
        if field.textColor != color { field.textColor = color }
        refresh(now: Date())
    }

    var fitting: CGSize {
        return CGSize(width: textWidth(field), height: ceil(field.intrinsicContentSize.height))
    }

    override func layout() {
        super.layout()
        field.frame = bounds.insetBy(dx: -2, dy: 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { ElapsedClock.shared.register(self) } else { ElapsedClock.shared.unregister(self) }
        refresh(now: Date())
    }

    /// One tick of the shared clock. Skips a timer nobody can see, and past a
    /// minute redraws once a second.
    func tick(now: Date) {
        guard window != nil, !visibleRect.isEmpty else { return }
        if now.timeIntervalSince(since) >= 60, now.timeIntervalSince(lastUpdate) < 0.99 { return }
        refresh(now: now)
    }

    private func refresh(now: Date) {
        lastUpdate = now
        let text = ElapsedFormat.string(seconds: now.timeIntervalSince(since))
        guard field.stringValue != text else { return }
        field.stringValue = text
        let width = fitting.width
        if width != shownWidth {
            shownWidth = width
            if window != nil { onWidthChange?() }
        }
    }
}

/// Grid, label and timer on one line (HAIL-66): a status of an ask or session.
struct AgentStatusLine: View {
    let status: AgentStatus
    var cell: CGFloat = 3
    /// Replaces the status's own label (the ask pane's longer copy).
    var label: String?
    /// Starts the timer; nil shows none.
    var since: Date?
    var labelFont: StatusFont = .label
    var spacing: CGFloat = 6

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            PixelStatusGrid(pattern: status.pattern, color: status.color, cell: cell)
                .centredOnXHeight(of: labelFont.size)
            ShimmerLabel(
                text: label ?? status.label, font: labelFont, shimmers: status.shimmers,
                base: status.shimmers ? Theme.Colors.ink3 : status.labelColor)
            if let since { ElapsedTimer(since: since) }
        }
    }
}

/// The loading state of the whole app (HAIL-66): the grey Drive grid, a
/// shimmering label and a timer from the moment it appears. `timedOut` freezes
/// it to a still grey grid with the "taking long" copy.
struct LoadingStatus: View {
    let label: String
    var cell: CGFloat = 4
    var since: Date?
    var labelFont: StatusFont = .label

    @State private var appearedAt = Date()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PixelStatusGrid(pattern: .drive, color: Theme.Colors.ink3, cell: cell)
                .centredOnXHeight(of: labelFont.size)
            ShimmerLabel(text: label, font: labelFont)
            ElapsedTimer(since: since ?? appearedAt)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
