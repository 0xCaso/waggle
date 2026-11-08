import SwiftUI

/// One case's `Case`, fetched once per follow-up header shown and cached in
/// memory (HAIL-33 amendment) - the earlier ask a follow-up points to is
/// often already resolved (delivered, its session ended) so it may no
/// longer be in `AppModel`'s `needsYouCases`/`waitingOnAgentCases` lists;
/// this loader fetches it directly with `cases.get`, the same pattern
/// `ArtifactPreviewLoader`/`ArtifactPreviewCache` already use for a case's
/// artifact.
@MainActor
final class FollowedCaseCache {
    static let shared = FollowedCaseCache()

    private var casesById: [String: Case] = [:]

    init() {}

    func get(_ id: String) -> Case? { casesById[id] }

    func store(_ item: Case) { casesById[item.id] = item }
}

@MainActor
final class FollowedCaseLoader: ObservableObject {
    @Published private(set) var followedCase: Case?

    private let client: KnockClient
    private let cache: FollowedCaseCache

    init(client: KnockClient, cache: FollowedCaseCache = .shared) {
        self.client = client
        self.cache = cache
    }

    func load(caseId: String) async {
        if let cached = cache.get(caseId) {
            followedCase = cached
            return
        }
        guard let detail = try? await client.casesGet(id: caseId) else { return }
        cache.store(detail.case)
        followedCase = detail.case
    }
}

/// "Follow-up to: <earlier title>" above a follow-up ask's own title, with a
/// compact recap of the earlier ask's answer underneath (HAIL-33 amendment:
/// "the app shows a follow-up with a 'Follow-up to: <earlier title>' line
/// above the title. It links to the earlier ask. Under it is a compact
/// recap of the earlier answer"). Renders nothing until the earlier case
/// loads, and nothing at all for a case that follows nothing.
struct FollowUpHeaderView: View {
    let followsCaseId: String
    let client: KnockClient
    let onOpen: (String) -> Void

    @StateObject private var loader: FollowedCaseLoader

    init(followsCaseId: String, client: KnockClient, onOpen: @escaping (String) -> Void) {
        self.followsCaseId = followsCaseId
        self.client = client
        self.onOpen = onOpen
        _loader = StateObject(wrappedValue: FollowedCaseLoader(client: client))
    }

    // A plain `VStack` root, never `Group` (docs/stories/HAIL-33.md Choices
    // ledger): a `Group` whose content is conditionally empty on first
    // appearance - true here, since `loader.followedCase` starts `nil` - is
    // never mounted into the view tree at all, so `.task`/`.onAppear` on it
    // never fires (confirmed empirically: `ArtifactPreviewCard`'s own working
    // loader pattern always renders *something*, even a bare loader,
    // so it never hits this). A zero-size `Color.clear` anchor keeps this
    // view concrete before the fetch resolves.
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let followedCase = loader.followedCase {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.up.left")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.ink3)
                    Text("Follow-up to: \(followedCase.title)")
                        .knockTextStyle(Theme.Typography.monoMeta12w400)
                        .foregroundColor(Theme.Colors.ink2)
                }
                .contentShape(Rectangle())
                .onTapGesture { onOpen(followsCaseId) }.pointerCursor()

                if let recap = followedCase.followUpRecapLine {
                    Text(recap)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: followsCaseId) { await loader.load(caseId: followsCaseId) }
    }
}
