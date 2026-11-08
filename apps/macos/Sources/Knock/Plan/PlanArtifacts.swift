import Foundation

/// HAIL-156: which artifact a plan round shows, and when the stage should say it is out of date.
enum PlanArtifacts {
    /// "Still showing vN" (HAIL-146) on a plan case. Every round of a plan is an update, so the plain
    /// case rule would fire on each round that sends no artifact. A round that sends none keeps showing
    /// the latest artifact and says so only when its stage differs from the stage of the round that sent
    /// the artifact on screen (approaches after the questions, for example). More rounds of the same
    /// stage (question 3 after question 2, design section 2 after section 1) stay quiet.
    static func staleNote(rounds: [PlanRound]) -> StaleArtifactNote? {
        guard let newest = rounds.last, !newest.ownArtifact, let revision = newest.revision,
              let owner = rounds.last(where: { $0.ownArtifact && $0.revision == revision }),
              owner.stage.name != newest.stage.name,
              let changeAt = KnockDateFormat.date(from: newest.createdAt)
        else { return nil }
        return StaleArtifactNote(shownRevision: revision, changeAt: changeAt)
    }

    /// The label of a round's "See vN" link in the answered history. `nil` when the round had no artifact.
    static func seeLabel(_ round: PlanRound) -> String? {
        round.revision.map { "See v\($0)" }
    }
}

extension CaseDetail {
    /// The stale-artifact line for this case: the plan rule for a plan ask, the plain rule otherwise.
    var staleArtifactNote: StaleArtifactNote? {
        guard self.case.plan != nil, let planRounds else { return self.case.staleArtifactNote }
        return PlanArtifacts.staleNote(rounds: planRounds)
    }
}
