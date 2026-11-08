import Foundation

/// HAIL-146: an agent update changed the ask (a message, new options) but sent
/// no new artifact, so the stage still shows the older one. The stage header
/// says so, so the pictures are not read as current.
struct StaleArtifactNote: Equatable {
    let shownRevision: Int
    let changeAt: Date

    /// "Still showing v1 · not updated with the 14:27 change".
    var text: String {
        "Still showing v\(shownRevision) \u{00B7} not updated with the \(KnockDateFormat.shortTime(from: changeAt)) change"
    }
}

/// Which of the two lines over the artifact shows (WAG-377). "vN arrived" says a new version came. The stale
/// note says the newest change did not update the artifact. They cannot both be true for the person reading,
/// so the stale note wins: it is the newer fact and it stops them trusting a picture that is out of date.
enum ArtifactStatusLine {
    static func arrivalToShow(arrival: RevisionArrival?, staleNote: StaleArtifactNote?) -> RevisionArrival? {
        staleNote == nil ? arrival : nil
    }
}

extension Case {
    /// Non-nil when the case has an artifact and its newest agent update (a
    /// message after the first reply, or a new option set) is later than its
    /// newest revision. An update that brought its own revision shares the
    /// revision's timestamp, so it never counts.
    var staleArtifactNote: StaleArtifactNote? {
        guard hasArtifact, let revisionAt = latestRevisionAt.flatMap(KnockDateFormat.date(from:)) else { return nil }
        let changes = [latestUpdateAt, optionsUpdatedAt].compactMap { $0.flatMap(KnockDateFormat.date(from:)) }
        guard let changeAt = changes.max(), changeAt > revisionAt else { return nil }
        return StaleArtifactNote(shownRevision: Swift.max(revisionCount ?? 1, 1), changeAt: changeAt)
    }
}
