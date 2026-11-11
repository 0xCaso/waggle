import Foundation

/// The built-in sample request of the first run. It is a plain local fixture shown by the same views as a
/// real request (`CasePaneDetailView`). Decide on it is delivered to this process only: it never reaches the
/// daemon, an agent or the network (`SendCoordinator.local`). Its artifact is one small markdown file written
/// under the `KNOCK_HOME`-scoped data root.
enum SampleRequest {
    static let caseId = "sample-request"
    static let taskId = "sample-task"
    static let project = "Waggle"
    static let compactId = "compact"
    static let detailedId = "detailed"
    static let tableId = "compare-table"
    static let artifactName = "Pricing card"
    static let stamp = "2026-01-01T00:00:00.000Z"

    static let options: [Option] = [
        Option(
            id: compactId, label: "Compact card: price, plan name and one button. Fast to scan.", title: "Compact card",
            proPoints: [OptionPoint(detail: "Fits three cards in a row.")], conPoints: [OptionPoint(detail: "Hides the feature list.")]),
        Option(
            id: detailedId, label: "Detailed card: price, plan name, the feature list and one button.", title: "Detailed card",
            proPoints: [OptionPoint(detail: "Answers questions on the card itself.")], conPoints: [OptionPoint(detail: "Takes twice the height.")]),
        Option(
            id: tableId, label: "Compact card with a compare table under the cards.", title: "Compact with a compare table",
            proPoints: [OptionPoint(detail: "Scannable cards and the full detail for people who want it.")],
            conPoints: [OptionPoint(detail: "One more block to build and keep in sync.")]),
    ]

    /// The request, as a real one would arrive from an agent.
    static let knockCase = Case(
        id: caseId, taskId: taskId, kind: .question, title: FirstRunRules.sampleTitle,
        need: "Pick the shape of the pricing card. This is a sample: answering it teaches the flow.",
        why: "A compact card scans faster. A detailed card answers more questions. Three cards sit in a row on the page.",
        recommendation: compactId, recommendationWhy: "People compare three plans at a glance, so a short card wins.",
        options: options, status: .needsYou, hasArtifact: true, project: project, createdAt: stamp, updatedAt: stamp)

    static let revision = Revision(
        id: "sample-revision-1", caseId: caseId, n: 1, createdAt: stamp, name: artifactName, kind: .markdown)

    static let detail = CaseDetail(
        case: knockCase, task: KnockTask(id: taskId, name: "Pricing page", project: project),
        messages: [], revisions: [revision], comments: [], replies: [])

    static let artifactText = """
    # Pricing card

    Three plans sit side by side. Here is the same plan in the two shapes.

    ## Compact card

    **Team** · $12 per seat per month

    One button: Start free trial.

    ## Detailed card

    **Team** · $12 per seat per month

    - Unlimited requests
    - Shared history
    - Priority support

    One button: Start free trial.
    """

    static func artifactDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: KnockClient.defaultDataRoot(environment: environment)).appendingPathComponent("sample", isDirectory: true)
    }

    /// Writes the artifact file and returns where the client finds it. Local files only.
    @discardableResult
    static func writeArtifact(environment: [String: String] = ProcessInfo.processInfo.environment) -> ArtifactPathResult? {
        let dir = artifactDirectory(environment: environment)
        let file = dir.appendingPathComponent("pricing-card.md")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(artifactText.utf8).write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return ArtifactPathResult(kind: .markdown, root: dir.path, entry: file.path, items: nil, viewport: nil, preview: nil)
    }

    /// Writes the artifact and tells the client about it, so the page opens it without asking the daemon.
    static func prepare(client: KnockClient, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard let result = writeArtifact(environment: environment) else { return }
        await client.registerLocalArtifact(caseId: caseId, result: result)
    }

    /// The reply Decide gives back on the sample: queued in memory, nothing stored or sent.
    static func localReply(for reply: PendingReply) -> Reply {
        Reply(
            id: "sample-reply", caseId: reply.caseId, idempotencyKey: reply.idempotencyKey, choice: reply.choice,
            message: reply.message, comments: [], captures: [], intent: reply.intent, state: .queued,
            createdAt: stamp, choices: reply.choices)
    }
}
