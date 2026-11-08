import AppKit
import Foundation
import SwiftUI

/// Where one opened artifact sits: beside the questions, or on the whole page.
struct OpenArtifact: Equatable {
    enum Placement: Equatable { case beside, fullPage }
    let card: ArtifactCardModel
    /// The question the card sits under; `nil` for the one artifact of an ask with no questions.
    let questionId: String?
    var placement: Placement
}

/// What a card's Open does outside the page.
enum ArtifactExternalOpen: Equatable {
    case fullSize
    case ownWindow
    case browser
}

/// The answers of the asks that are not sent yet, by case id, so a decision keeps its picks, notes and step
/// when you leave it and come back (WAG-287). The app keeps one; it lives until the app quits.
@MainActor
final class AskDocMemory {
    private var docs: [String: QuestionsDocModel] = [:]

    func doc(for caseId: String) -> QuestionsDocModel? { docs[caseId] }

    func save(_ doc: QuestionsDocModel?) {
        guard let doc else { return }
        // A sent ask comes back from the daemon with its answers; only open work needs a copy here.
        if doc.isLocked { docs[doc.caseId] = nil } else { docs[doc.caseId] = doc }
    }
}

/// Owns what the decision doc keeps between renders: the answers of an ask with questions, the artifact
/// that is open and the viewer behind it. One per ask (the pane is keyed by case id).
@MainActor
final class AskDocController: ObservableObject {
    @Published var doc: QuestionsDocModel? { didSet { store?.save(doc) } }
    @Published private(set) var open: OpenArtifact?
    let viewer: ReviewViewModel
    private let memory: OpenTargetMemory
    private let store: AskDocMemory?
    /// The answers of the sent reply, by item id: a sent request with items shows them (WAG-315).
    private var itemAnswers: [ItemAnswer]

    init(
        client: KnockClient, usage: UsageReporter? = nil, request: Case, memory: OpenTargetMemory = OpenTargetMemory(),
        commentsStore: CommentsSessionStore = CommentsSessionStore(), store: AskDocMemory? = nil,
        itemAnswers: [ItemAnswer] = []
    ) {
        self.viewer = ReviewViewModel(client: client, usage: usage, commentsStore: commentsStore)
        self.memory = memory
        self.store = store
        self.itemAnswers = itemAnswers
        if !request.hasQuestionsDoc {
            self.doc = nil
        } else if var kept = store?.doc(for: request.id) {
            kept.refresh(with: request, itemAnswers: itemAnswers)
            self.doc = kept
        } else {
            var fresh = QuestionsDocModel(request: request, itemAnswers: itemAnswers)
            fresh.applyEvidence()
            self.doc = fresh
        }
    }

    /// The target a bare tap on a card's Open uses: the last one chosen for that kind of card, else its default.
    func lastTarget(fullSize: Bool) -> ArtifactOpenTarget { memory.last(fullSize: fullSize) }

    /// Opens `card` at `target` and remembers the choice. A page or panel target opens here; the window and
    /// the browser come back to the caller, who owns the scene action.
    func choose(_ target: ArtifactOpenTarget, card: ArtifactCardModel, questionId: String?) -> ArtifactExternalOpen? {
        memory.setLast(target, fullSize: card.opensFullSize)
        switch target {
        case .beside:
            show(OpenArtifact(card: card, questionId: questionId, placement: .beside))
            return nil
        case .fullPage:
            show(OpenArtifact(card: card, questionId: questionId, placement: .fullPage))
            return nil
        case .fullSize: return .fullSize
        case .ownWindow: return .ownWindow
        case .browser: return .browser
        }
    }

    private func show(_ artifact: OpenArtifact) {
        open = artifact
        viewer.pageFragment = fragment(for: artifact.questionId)
    }

    /// Loads the artifact into the viewer the first time something opens. A newer revision refreshes it.
    /// `revision` is the card's own, so each artifact of the case opens, not only the newest.
    func ensureLoaded(detail: CaseDetail, revision: Int? = nil) async {
        if viewer.detail == nil { await viewer.load(detail: detail, revision: revision) } else {
            await viewer.refresh(detail: detail)
            if let revision { await viewer.show(revision: revision) }
        }
    }

    /// The side panel follows the step: it shows `card` at the page of `questionId` (WAG-287).
    func retarget(card: ArtifactCardModel, questionId: String) {
        guard let current = open, current.placement == .beside else { return }
        show(OpenArtifact(card: card, questionId: questionId, placement: .beside))
    }

    func close() {
        open = nil
    }

    /// The page hash of a question: the question id, then the variant picked, if any.
    func fragment(for questionId: String?) -> String? {
        guard let questionId, let doc, let question = doc.questions.first(where: { $0.id == questionId }) else { return nil }
        return doc.fragment(for: question)
    }

    func selectVariant(_ variant: String, question: String) {
        UsageReporter.current?.record(.artifactVariantSelected)
        doc?.selectVariant(variant, question: question)
        viewer.pageFragment = fragment(for: question)
    }

    func refresh(with request: Case, itemAnswers answers: [ItemAnswer]? = nil) {
        if let answers { itemAnswers = answers }
        if !request.hasQuestionsDoc { doc = nil; return }
        if doc == nil { doc = QuestionsDocModel(request: request, itemAnswers: itemAnswers) } else { doc?.refresh(with: request, itemAnswers: itemAnswers) }
    }
}

/// The page that "In the browser" opens. A bundle is untrusted, so it does not run bare in the browser:
/// this page frames it with a sandbox that has no same-origin access, a CSP that blocks connections,
/// and a CSP of its own that allows only that frame. The frame cannot read `file:` subresources (its
/// origin is opaque), so the framed page is a copy with the bundle's local files inlined (`BundleInliner`).
enum BrowserWrapper {
    /// The one plain line on the page: the browser has no bridge to the app, so no pin can be placed here.
    static let notice = "You can look at this page here, but comments only work in the Waggle app."

    /// Where "Back to Waggle" goes: the app opens this case. `caseId` is limited to safe characters.
    static func appURL(caseId: String) -> String {
        let safe = caseId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "waggle://case/\(safe)"
    }

    static func html(entry: URL, fragment: String?, title: String, caseId: String) -> String {
        var src = entry
        if let fragment, var parts = URLComponents(url: entry, resolvingAgainstBaseURL: false) {
            parts.fragment = fragment
            src = parts.url ?? entry
        }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src file:; style-src 'unsafe-inline'">
        <title>\(escape(title))</title>
        <style>
        html,body{margin:0;width:100%;height:100%;background:#fff}
        body{display:flex;flex-direction:column;font:13.5px/1.4 -apple-system,'Inter Tight',sans-serif;color:#4A4C50}
        .bar{flex:none;display:flex;align-items:center;gap:12px;padding:8px 14px;background:#FDF4DA;border-bottom:1px solid #E6E6E6}
        .bar span{flex:1}
        .bar a{flex:none;padding:5px 12px;border-radius:9px;background:#16181A;color:#fff;font-weight:600;text-decoration:none}
        iframe{flex:1;width:100%;border:0;background:#fff}
        </style>
        </head><body>
        <div class="bar"><span>\(escape(notice))</span><a href="\(escape(appURL(caseId: caseId)))">Back to Waggle</a></div>
        <iframe sandbox="allow-scripts allow-forms" csp="default-src 'self' 'unsafe-inline' data: blob:; connect-src 'none'; form-action 'none'" src="\(escape(src.absoluteString))"></iframe>
        </body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Writes the inlined copy of the bundle page and the wrapper to the temporary folder, and returns the
    /// wrapper's URL. Both files are replaced on each call, and files from other runs older than a day go.
    static func write(entry: URL, root: URL, fragment: String?, title: String, caseId: String = "", name: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("waggle-in-browser", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = Date().addingTimeInterval(-86_400)
        for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < stale {
                try? fm.removeItem(at: old)
            }
        }
        let source = try String(contentsOf: entry, encoding: .utf8)
        let page = dir.appendingPathComponent("\(name)-page.html")
        try BundleInliner.inline(html: source, entry: entry, root: root).write(to: page, atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("\(name).html")
        try html(entry: page, fragment: fragment, title: title, caseId: caseId).write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
