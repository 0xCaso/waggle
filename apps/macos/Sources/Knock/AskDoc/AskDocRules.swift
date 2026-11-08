import Foundation

/// The rules of the decision doc that need no view (WAG-257): which bottom bar an ask gets, where its
/// options live, how artifact cards lay out and where an artifact opens. Pure, so each rule is unit-tested.
enum AskBarMode: Equatable {
    /// A simple ask: its options, the note field and "Decide: <option>".
    case decide
    /// An ask with no options and no questions: the note field and Send.
    case reply
    /// An ask with questions: "N answered", the note field and "Send N answers".
    case answers

    static func forCase(_ item: Case) -> AskBarMode {
        if item.hasQuestionsDoc { return .answers }
        // A message-only update settles the earlier round: reply field only (WAG-337).
        if item.earlierRoundIsReadOnly { return .reply }
        return item.options.isEmpty ? .reply : .decide
    }
}

/// Where an ask's options show. An option sits in one place only: the bottom bar of a simple ask.
/// The old boxed Decision card is gone, so no ask ever lists its options twice.
enum AskOptionsPlace: Equatable {
    case bottomBar
}

/// The decision layouts that have a fixed bottom bar (WAG-291). On each, the options to decide sit in the
/// bar and never in the scroll above it; the review step has no options, only the picks summary.
enum DecisionLayout: CaseIterable, Equatable {
    /// A simple ask: the options, the note and Decide.
    case single
    /// One step of a decision step by step: the points of the step, the note, Back and Next.
    case step
    /// The last step: the picks summary scrolls, Send stays in the bar.
    case review
    /// A plan question beside its artifact: the option cards in the bottom of the right column.
    case plan
}

enum DecisionDock {
    /// Options live in the bar on every layout that has any.
    static func optionsInDock(_ layout: DecisionLayout) -> Bool { layout != .review }

    /// No layout lists its options in the scrolling page.
    static func optionsInScroll(_ layout: DecisionLayout) -> Bool { false }

    /// The tallest the options part of a step bar gets: about 40% of the window height.
    static let stepShare: CGFloat = 0.4
    /// The tallest the options part of the plan bar gets: about 45% of the window height.
    static let planShare: CGFloat = 0.45
    /// Never so short that a card cannot show.
    static let minCap: CGFloat = 120

    static func cap(_ layout: DecisionLayout, windowHeight: CGFloat) -> CGFloat? {
        switch layout {
        case .step: max(minCap, windowHeight * stepShare)
        case .plan: max(minCap, windowHeight * planShare)
        case .single, .review: nil
        }
    }

    /// Which layout a case page is in.
    static func layout(_ doc: QuestionsDocModel?, hasPlanBesideArtifact: Bool) -> DecisionLayout {
        if hasPlanBesideArtifact { return .plan }
        guard let doc, doc.isStepped else { return .single }
        return doc.currentQuestion == nil ? .review : .step
    }
}

enum AskDocRules {
    static func optionsPlaces(for item: Case) -> [AskOptionsPlace] {
        AskBarMode.forCase(item) == .decide ? [.bottomBar] : []
    }

    /// "Decide: Flagged first": the button of a simple ask, with the chosen option's short title.
    /// Without a choice it reads "Decide".
    static func decideLabel(choiceTitle: String?) -> String {
        guard let choiceTitle, !choiceTitle.isEmpty else { return "Decide" }
        return "Decide: \(choiceTitle)"
    }
}

/// How the cards of one ask or question sit (Pen Round 4): one is a wide card, two or three share the row,
/// more than three scroll sideways.
enum ArtifactCardsLayout: Equatable {
    case none
    case wide
    case sideBySide(columns: Int)
    case scrollingRow

    static func rule(count: Int) -> ArtifactCardsLayout {
        switch count {
        case ..<1: return .none
        case 1: return .wide
        case 2, 3: return .sideBySide(columns: count)
        default: return .scrollingRow
        }
    }
}

/// Where a card's Open puts the artifact.
enum ArtifactOpenTarget: String, CaseIterable, Equatable, Sendable {
    case beside
    case fullPage
    case fullSize
    case ownWindow
    case browser

    /// A write-up, a diagram or one image opens in the side panel.
    static let `default`: ArtifactOpenTarget = .beside

    /// A prototype or a screens set opens full size: the artifact large, the mini decision doc on the right.
    static func `default`(fullSize: Bool) -> ArtifactOpenTarget { fullSize ? .fullSize : .beside }

    /// The Open menu of a card, top to bottom. A full size card has no side panel.
    static func menu(fullSize: Bool) -> [ArtifactOpenTarget] {
        fullSize ? [.fullSize, .ownWindow, .browser] : [.beside, .fullPage, .ownWindow, .browser]
    }

    var menuLabel: String {
        switch self {
        case .beside: "Side panel"
        case .fullPage: "Full Waggle page"
        case .fullSize: "Full size"
        case .ownWindow: "In a new window"
        case .browser: "In the browser"
        }
    }
}

/// The last place the person chose from a card's Open menu, kept apart for full size cards (prototypes,
/// screens sets) and the others. The next Open of that group uses it.
struct OpenTargetMemory {
    /// The first version kept one choice for every card.
    static let key = "knock.askdoc.openTarget"
    static let fullSizeKey = "knock.askdoc.openTarget.fullSize"
    static let panelKey = "knock.askdoc.openTarget.panel"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// For a test that opens the same store a second time.
    var defaultsForTests: UserDefaults { defaults }

    func last(fullSize: Bool) -> ArtifactOpenTarget {
        let allowed = ArtifactOpenTarget.menu(fullSize: fullSize)
        let stored = defaults.string(forKey: fullSize ? Self.fullSizeKey : Self.panelKey)
            ?? defaults.string(forKey: Self.key)
        guard let target = stored.flatMap(ArtifactOpenTarget.init(rawValue:)) else { return .default(fullSize: fullSize) }
        // A saved side panel or Waggle page for a prototype becomes full size.
        if fullSize, target == .beside || target == .fullPage { return .fullSize }
        return allowed.contains(target) ? target : .default(fullSize: fullSize)
    }

    func setLast(_ target: ArtifactOpenTarget, fullSize: Bool) {
        defaults.set(target.rawValue, forKey: fullSize ? Self.fullSizeKey : Self.panelKey)
    }
}

/// The type icon and the mono label of an artifact card.
enum ArtifactCardType: Equatable {
    case prototype, chart, flow, writeUp, screenshots

    init(kind: ArtifactKind) {
        switch kind {
        case .htmlBundle: self = .prototype
        case .diagram: self = .flow
        case .markdown: self = .writeUp
        case .screenshot, .screenshots: self = .screenshots
        }
    }

    var label: String {
        switch self {
        case .prototype: "PROTOTYPE"
        case .chart: "CHART"
        case .flow: "FLOW"
        case .writeUp: "WRITE-UP"
        case .screenshots: "SCREENSHOTS"
        }
    }

    var symbol: String {
        switch self {
        case .prototype: "iphone"
        case .chart: "chart.bar"
        case .flow: "rectangle.connected.to.line.below"
        case .writeUp: "doc.text"
        case .screenshots: "photo.on.rectangle"
        }
    }
}

/// What one artifact card shows.
struct ArtifactCardModel: Equatable, Identifiable {
    let id: String
    let type: ArtifactCardType
    let revision: Int
    let name: String
    let meta: String
    /// Only a prototype with variants opens at a question and switches them.
    let variantCount: Int
    /// A prototype or a screens set opens full size, not in the side panel.
    var opensFullSize: Bool = false

    /// "PROTOTYPE · V2".
    var kindLine: String { "\(type.label) · V\(revision)" }

    /// The cards of an ask: one for each artifact on the case (WAG-289), in the order of the tabs. A case
    /// with no tab data (a daemon that sends no revisions) gets one card for its newest artifact.
    static func cards(
        for item: Case, revision: Int, question: Question? = nil, tabs: [ArtifactTab] = []
    ) -> [ArtifactCardModel] {
        guard item.hasArtifact else { return [] }
        guard tabs.count > 1 else { return single(for: item, revision: revision, question: question) }
        return tabs.compactMap { tab in
            guard let kind = tab.kind ?? item.artifactKind else { return nil }
            return card(
                for: item, kind: kind, revision: tab.revision, question: question, name: tab.hasName ? tab.title : nil,
                idSuffix: "/" + tab.id)
        }
    }

    private static func single(for item: Case, revision: Int, question: Question?) -> [ArtifactCardModel] {
        guard let kind = item.artifactKind else { return [] }
        return [card(for: item, kind: kind, revision: revision, question: question, name: nil, idSuffix: "")]
    }

    private static func card(
        for item: Case, kind: ArtifactKind, revision: Int, question: Question?, name given: String?, idSuffix: String
    ) -> ArtifactCardModel {
        let type = ArtifactCardType(kind: kind)
        let variants = question?.variants?.count ?? 0
        let meta: String
        if variants > 1 {
            meta = "\(variants) ways to compare"
        } else {
            switch type {
            case .prototype: meta = question == nil ? "A live page you can try" : "Opens at this question"
            case .writeUp: meta = "Read it beside the questions"
            case .screenshots: meta = "Screens to flip through"
            case .flow, .chart: meta = "Opens in a viewer"
            }
        }
        let name: String
        switch type {
        case .prototype: name = "Prototype"
        case .chart: name = "Chart"
        case .flow: name = "Diagram"
        case .writeUp: name = "Write-up"
        case .screenshots: name = "Screens"
        }
        return ArtifactCardModel(
            id: "\(item.id)/\(question?.id ?? "ask")" + idSuffix, type: type, revision: revision, name: given ?? name,
            meta: meta, variantCount: variants, opensFullSize: type == .prototype || kind == .screenshots)
    }
}
