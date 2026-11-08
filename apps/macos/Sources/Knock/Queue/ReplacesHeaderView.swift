import SwiftUI

/// "Replaces: <earlier title>" above a replacing ask's own title, with a
/// compact recap of the earlier ask's answer underneath when it had one
/// before it was withdrawn (HAIL-44, mirrors `FollowUpHeaderView`'s
/// "Follow-up to" treatment). Reuses `FollowedCaseCache`/`FollowedCaseLoader`
/// (HAIL-33 amendment) - both are a plain case-by-id loader/cache, not
/// specific to a follow-up relation, so the same in-memory cache serves both
/// headers without a second lookup for a case shown both ways. Renders
/// nothing until the earlier case loads, and nothing at all for a case that
/// replaces nothing.
///
/// Unlike `FollowUpHeaderView`, this line is not a link: the earlier case is
/// withdrawn (`resolved`, no restore), so its own pane has nothing further
/// to do or show beyond the recap already given here, and none of the
/// pane's own locked-reply states model "withdrawn" - `ReplyLockState`
/// deliberately folds a superseded reply into `.failed` only to stay
/// exhaustive, not to be shown (see `Case.replyLockState`). Opening that
/// pane is not worth the risk of surfacing a stray Retry action on a reply
/// that can never be retried.
struct ReplacesHeaderView: View {
    let replacesCaseId: String
    let client: KnockClient

    @StateObject private var loader: FollowedCaseLoader

    init(replacesCaseId: String, client: KnockClient) {
        self.replacesCaseId = replacesCaseId
        self.client = client
        _loader = StateObject(wrappedValue: FollowedCaseLoader(client: client))
    }

    // A plain `VStack` root, never `Group` - see `FollowUpHeaderView`'s own
    // note: a `Group` whose content is conditionally empty on first
    // appearance never mounts into the view tree, so `.task` never fires.
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let replacedCase = loader.followedCase {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.Colors.ink3)
                    Text("Replaces: \(replacedCase.title)")
                        .knockTextStyle(Theme.Typography.monoMeta12w400)
                        .foregroundColor(Theme.Colors.ink2)
                }

                if let recap = replacedCase.followUpRecapLine {
                    Text(recap)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: replacesCaseId) { await loader.load(caseId: replacesCaseId) }
    }
}
