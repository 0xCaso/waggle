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

    private let client: KnockClient?
    private let cache: FollowedCaseCache

    /// `client` is nil where no daemon is reachable (a preview): only a cached case shows.
    init(client: KnockClient?, cache: FollowedCaseCache = .shared) {
        self.client = client
        self.cache = cache
    }

    func load(caseId: String) async {
        if let cached = cache.get(caseId) {
            followedCase = cached
            return
        }
        guard let client, let detail = try? await client.casesGet(id: caseId) else { return }
        cache.store(detail.case)
        followedCase = detail.case
    }
}
