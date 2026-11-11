import Testing
import SwiftUI
import AppKit
@testable import Knock

/// The pane never sets the window's width (WAG-257, bug seen in 0.2.11): one long line or one unbroken
/// string used to widen the pane past the window, cutting the sidebar on the left and the pane on the right.
/// Each test hosts a view in a 900 pt wide `NSHostingView` and checks the width it asks for.
@MainActor
struct PaneWidthTests {
    private static let limit: CGFloat = 900
    private let url = "https://example.com/" + String(repeating: "segment-0123456789/", count: 15) + "mcp"
    private let longTitle = String(repeating: "Which of the many long plans should the team ship first this quarter? ", count: 6)
    private var command: String {
        "claude mcp add --transport http simone \(url)"
    }

    /// The widest the view asks for: its ideal width (what `fittingSize` reports) and the width it takes
    /// when the window offers 900 pt (what a fixed or unbreakable child could push past the window).
    private func askedWidth<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        let ideal = host.fittingSize.width
        let controller = NSHostingController(rootView: view)
        let offered = controller.sizeThatFits(in: CGSize(width: Self.limit, height: 700)).width
        return max(ideal, offered)
    }

    private func makeCase(
        id: String = "c_now", title: String? = nil, options: [Option] = [], questions: [Question] = [], replyMessage: String? = nil,
        created: String = "2026-10-07T10:00:00Z"
    ) -> Case {
        Case(
            id: id, taskId: "t1", kind: .question, title: title ?? longTitle,
            need: "Run \(command) and then open \(url) to check the result. " + String(repeating: "Longer need text. ", count: 10),
            why: "See \(url)", recommendation: options.first?.id ?? "", recommendationWhy: "It is \(url)",
            options: options, status: .needsYou, hasArtifact: false,
            latestReplyMessage: replyMessage, createdAt: created, updatedAt: created, questions: questions)
    }

    private func detail(_ item: Case) -> CaseDetail {
        CaseDetail(
            case: item, task: KnockTask(id: "t1", name: longTitle, project: String(repeating: "very-long-project-name-", count: 8)),
            messages: [], revisions: [], comments: [], replies: [])
    }

    /// A model shown as connected, with no socket and no background work.
    private func connectedModel() -> AppModel {
        let model = AppModel(
            client: KnockClient(socketPath: "/tmp/knock-nonexistent-\(UUID().uuidString).sock"), environment: isolatedKnockEnvironment(),
            bundleIdentifier: TestCopyEnvironment.releaseBundleIdentifier)
        model.setConnectionStateForTests(.connected)
        return model
    }

    @Test func simpleAskWithLongLinesAndACommandStaysInTheWindow() {
        let model = connectedModel()
        #expect(model.connectionState == .connected)
        let item = makeCase(options: [Option(id: "o0", label: command), Option(id: "o1", label: url)])
        let width = askedWidth(CasePaneDetailView(model: model, detail: detail(item)))
        #expect(width <= Self.limit, "the pane asked for \(width) pt")
    }

    @Test func askWithQuestionsAndLongPointsStaysInTheWindow() {
        let model = connectedModel()
        let points = [QuestionPoint(id: "p", text: "Run \(command)?", options: [
            PointOption(label: url, pros: [command], cons: [url]), PointOption(label: command)])]
        let question = Question(
            id: "q", title: longTitle, now: [command, url], points: points, artifactRef: nil, variants: nil, variantLabel: nil)
        let item = makeCase(questions: [question])
        let width = askedWidth(CasePaneDetailView(model: model, detail: detail(item)))
        #expect(width <= Self.limit, "the pane asked for \(width) pt")
    }

    @Test func answerDockWithLongOptionsStaysInTheWindow() {
        let model = connectedModel()
        let item = makeCase(options: [Option(id: "o0", label: command), Option(id: "o1", label: longTitle)])
        let flow = SendFlowController(
            knockCase: item, commentsStore: CommentsSessionStore(), coordinator: model.sendCoordinator,
            draftStore: ComposerDraftStore(), onSent: {})
        let dock = ComposerCardView(
            composer: flow.composer, sendFlow: flow, deliveryState: flow.deliveryState, recommendationId: "o0",
            commentCount: 0, placeholder: "Add a note", isLocked: false, yourAnswerOptionId: nil, yourAnswerOptionIds: [],
            lockedMessage: nil, onOpenReview: nil, maxOptionsHeight: 280, showsFullOptions: true, showsStatus: false)
        #expect(askedWidth(dock) <= Self.limit)
    }

    @Test func earlierAsksPopoverWithThirtyLongRowsStaysInTheWindow() {
        let now = makeCase()
        let earlier = (0..<30).map { n in
            makeCase(id: "c_\(n)", title: longTitle, replyMessage: "You chose: \(command)", created: "2026-10-07T09:\(String(format: "%02d", n))00Z")
        }
        let model = EarlierAsksModel.make(item: now, cases: earlier)
        #expect(model.rows.count == 30)
        #expect(askedWidth(EarlierAsksPopover(model: model)) <= EarlierAsksPopover.width)
        #expect(askedWidth(EarlierAsksLink(model: model, onOpenCase: { _ in }, onOpenHistory: {})) <= Self.limit)
    }

    @Test func crumbsLineWithAThirtyAskLinkStaysInTheWindow() {
        let model = connectedModel()
        let item = makeCase(options: [Option(id: "o0", label: "Yes")])
        #expect(askedWidth(CasePaneView(model: model)) <= Self.limit)
        #expect(askedWidth(CasePaneDetailView(model: model, detail: detail(item))) <= Self.limit)
    }

    @Test func contextCardWithTwentyOneLongEarlierRequestsStaysInTheWindow() {
        let items = (0..<21).map { n in
            SessionContextBlock.Item(
                caseId: "c_\(n)", kind: .answer, at: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)),
                text: "You chose: \(command)")
        }
        let model = ContextCardModel.make(block: SessionContextBlock(line: nil, earlier: items), thread: nil)
        #expect(model.rows.first?.label == "21 earlier requests")
    }
}
