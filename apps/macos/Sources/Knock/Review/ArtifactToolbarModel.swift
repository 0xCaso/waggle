import Foundation

/// The version words of the full-size artifact toolbar (WAG-309). The artifact's version shows once,
/// as in the box header ("v8"). The capture position lives in the filmstrip only.
enum ArtifactVersionLabel {
    /// "Screenshots · v8": the artifact's name and its version, once.
    static func chrome(title: String, revision: Int) -> String { "\(title) · v\(revision)" }

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
