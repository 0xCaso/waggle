import Foundation

/// The version words of the full-size artifact toolbar (WAG-309). The artifact's version shows once,
/// as in the box header ("v8"). The capture position lives in the filmstrip only.
enum ArtifactVersionLabel {
    /// "Screenshots · v8": the artifact's name and its version, once.
    static func chrome(title: String, revision: Int) -> String { "\(title) · v\(revision)" }

    /// The version words of the artifact header, once. `title` is the artifact's name, or `nil` when a tab
    /// already names it. `latest` is the newest version, passed only while an older one is on show:
    /// "v2 of 3" then, else "v3". The name and the version each appear one time in the header.
    static func header(title: String?, revision: Int, latest: Int?) -> String {
        var version = "v\(revision)"
        if let latest, latest > revision { version += " of \(latest)" }
        guard let title else { return version }
        return "\(title) · \(version)"
    }

    /// What the header watches to see a version arrive: the request and how many versions it has.
    struct Arrivals: Equatable {
        let caseId: String?
        let count: Int
    }

    /// The version to mark as "new" in the header: the newest one, when the same request gets one more
    /// version while its page is on show. `nil` on the first load, on a move to another request, and on a
    /// tab or older-version switch (the count stays the same).
    static func newMark(from old: Arrivals, to new: Arrivals, latest: Int?) -> Int? {
        guard let id = new.caseId, id == old.caseId, old.count > 0, new.count > old.count else { return nil }
        return latest
    }
    /// How long the "new" mark stays, in seconds.
    static let newMarkSeconds: Double = 4

    /// "from v7" when a capture was taken on another version than the artifact on show, else `nil`:
    /// the capture then adds no version words, because the toolbar already says it.
    static func captureOrigin(captureRevision: Int, artifactRevision: Int?) -> String? {
        guard let artifactRevision, captureRevision != artifactRevision else { return nil }
        return "from v\(captureRevision)"
    }

    /// "Capture 1 · 14:02" or "Capture 1 · from v7 · 14:02".
    static func captureChip(n: Int, captureRevision: Int, artifactRevision: Int?, time: String) -> String {
        var parts = ["Capture \(n)"]
        if let origin = captureOrigin(captureRevision: captureRevision, artifactRevision: artifactRevision) { parts.append(origin) }
        parts.append(time)
        return parts.joined(separator: " · ")
    }
}
