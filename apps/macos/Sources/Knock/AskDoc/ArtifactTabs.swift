import Foundation

/// One artifact of a case, as a tab on the decision page (WAG-276). Revisions that share a name are
/// versions of one artifact: the newest one shows. A revision with no name groups by its kind.
struct ArtifactTab: Equatable, Identifiable {
    /// The grouping key: the artifact's name, else its kind.
    let id: String
    /// What the tab says: the artifact's name, else a plain word for its kind.
    let title: String
    /// The newest revision of this artifact.
    let revision: Int
    /// `nil` from a daemon that does not send the kind.
    let kind: ArtifactKind?
    let hasName: Bool
    /// WAG-320: every revision number of this artifact, oldest first.
    var revisions: [Int] = []
}

/// What selecting an option does to the live artifact: which tab it shows and which anchor it scrolls to.
struct ArtifactLink: Equatable {
    let tabId: String?
    let anchor: String?
}

extension CaseDetail {
    /// WAG-351, WAG-382: the artifact tabs of the round on screen: the round that holds `viewing` (a revision
    /// read from an earlier round), else the newest round. This holds for every case, not only a plan. A case
    /// with one round keeps every artifact. The rounds come from the plan, else from `rounds`, else from the
    /// `round` the daemon puts on each revision.
    func artifactTabs(viewing revision: Int? = nil) -> [ArtifactTab] {
        var rounds: [(seq: Int, refs: [String], shown: Int?)] = []
        if self.case.plan != nil, let plan = planRounds, plan.count > 1 {
            rounds = plan.map { ($0.seq, $0.options.compactMap(\.artifactRef), $0.revision) }
        } else if self.case.plan == nil, let items = self.rounds, items.count > 1 {
            rounds = items.map { ($0.seq, $0.items.flatMap(\.options).compactMap(\.artifactRef), $0.revision) }
        } else if self.case.plan == nil {
            let seqs = Set(revisions.compactMap(\.round)).sorted()
            if seqs.count > 1 { rounds = seqs.map { ($0, [], nil) } }
        }
        guard rounds.count > 1 else { return ArtifactTabs.tabs(revisions: revisions) }
        let seq = revision.flatMap { n in revisions.first { $0.n == n }?.round } ?? rounds.last?.seq
        guard let current = rounds.first(where: { $0.seq == seq }) else { return ArtifactTabs.tabs(revisions: revisions) }
        return ArtifactTabs.tabs(revisions: revisions, round: current.seq, refs: current.refs, shown: current.shown)
    }
}

enum ArtifactTabs {
    /// A tab per artifact, in the order each first appeared. A revision you saved from an edit joins the
    /// artifact it started from.
    static func tabs(revisions: [Revision]) -> [ArtifactTab] {
        let ordered = revisions.sorted { $0.n < $1.n }
        let keyByRevision = keys(revisions: revisions)
        var order: [String] = []
        var newest: [String: Revision] = [:]
        var named: [String: String] = [:]
        for revision in ordered {
            guard let key = keyByRevision[revision.n] else { continue }
            if newest[key] == nil { order.append(key) }
            newest[key] = revision
            if let name = clean(revision.name) { named[key] = folded(name) }
        }
        return order.compactMap { key in
            guard let revision = newest[key] else { return nil }
            let name = named[key]
            return ArtifactTab(
                id: key, title: name ?? defaultTitle(revision.kind), revision: revision.n, kind: revision.kind,
                hasName: name != nil,
                revisions: ordered.filter { keyByRevision[$0.n] == key }.map(\.n))
        }
    }

    /// WAG-351: the tabs of the round on screen. A tab for each artifact whose newest agent revision at or
    /// before `round` was sent in `round`, and for each older artifact an option of the round names with
    /// `artifact_ref` (`refs`). When that gives nothing, the artifact the round shows (`shown`, else the
    /// newest revision at or before the round). Each tab holds its newest revision at or before the round.
    /// With no `round`, or revisions that carry no round (an older daemon), every artifact: `tabs(revisions:)`.
    static func tabs(revisions: [Revision], round: Int?, refs: [String] = [], shown: Int? = nil) -> [ArtifactTab] {
        guard let round, revisions.contains(where: { $0.round != nil }) else { return tabs(revisions: revisions) }
        let keyByRevision = keys(revisions: revisions)
        let visible = revisions.filter { ($0.round ?? 0) <= round }
        let all = tabs(revisions: visible)
        let wanted = Set(refs.compactMap(clean).map { folded($0).lowercased() })
        var sentNow = Set<String>()
        for revision in visible.sorted(by: { $0.n < $1.n }) where revision.author == .agent {
            guard let key = keyByRevision[revision.n] else { continue }
            if revision.round == round { sentNow.insert(key) } else { sentNow.remove(key) }
        }
        let picked = all.filter { sentNow.contains($0.id) || ($0.hasName && wanted.contains($0.title.lowercased())) }
        if !picked.isEmpty { return picked }
        let fallbackKey = shown.flatMap { n in visible.contains { $0.n == n } ? keyByRevision[n] : nil }
            ?? all.last?.id
        return all.filter { $0.id == fallbackKey }
    }

    /// The tab key of each revision number. A revision you saved from an edit takes its base's key.
    private static func keys(revisions: [Revision]) -> [Int: String] {
        var keyByRevision: [Int: String] = [:]
        for revision in revisions.sorted(by: { $0.n < $1.n }) {
            var key = key(of: revision)
            if revision.author == .you, let base = revision.baseRevision, let baseKey = keyByRevision[base] { key = baseKey }
            keyByRevision[revision.n] = key
        }
        return keyByRevision
    }

    /// The tab that holds the revision on show in the full-size view (WAG-309). `nil` when no tab holds it.
    static func tabId(showing revision: Int?, revisions: [Revision]) -> String? {
        guard let revision else { return nil }
        return keys(revisions: revisions)[revision]
    }

    /// WAG-320: the revision numbers of the artifact that holds `revision`, oldest first.
    static func revisionNumbers(holding revision: Int?, revisions: [Revision]) -> [Int] {
        guard let revision, let key = keys(revisions: revisions)[revision] else { return [] }
        return revisions.sorted { $0.n < $1.n }.map(\.n).filter { keys(revisions: revisions)[$0] == key }
    }

    private static func key(of revision: Revision) -> String {
        if let name = clean(revision.name) { return "name:" + folded(name).lowercased() }
        return "kind:" + (revision.kind?.rawValue ?? "artifact")
    }

    /// WAG-382: the name without a trailing version word: "A v2", "A (v4)", "A rev 2", "A version 5", "A V2".
    /// A number that is not a version word stays ("Slide 6", "Step 2", "Option B2"). A name that is only
    /// a version word stays as it is.
    static func folded(_ name: String) -> String {
        let pattern = #"\s+[(\[]?(?:v|rev|version)\.?\s*\d+[)\]]?$"#
        guard let range = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return name }
        let rest = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    private static func clean(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the decision page shows the artifact box (live, with tabs) instead of the still card: a page
    /// does, and so does a case with more than one artifact. `fallbackKind` is the newest artifact's kind
    /// from the case list, for a daemon that sends no kind on revisions.
    static func showsLive(tabs: [ArtifactTab], fallbackKind: ArtifactKind?) -> Bool {
        tabs.count > 1 || (tabs.last?.kind ?? fallbackKind) == .htmlBundle
    }

    /// The plain word for an artifact with no name.
    static func defaultTitle(_ kind: ArtifactKind?) -> String {
        switch kind {
        case .htmlBundle: return "Prototype"
        case .markdown: return "Write-up"
        case .screenshot: return "Screenshot"
        case .screenshots: return "Screenshots"
        case .diagram: return "Diagram"
        case nil: return "Artifact"
        }
    }

    /// The tab an option names with `artifact_ref` (trimmed, not case sensitive), and its anchor. `nil` when
    /// the option links to nothing. An anchor with no artifact_ref belongs to the tab on show.
    static func link(for option: Option?, in tabs: [ArtifactTab], current: String?) -> ArtifactLink? {
        guard let option else { return nil }
        let anchor = clean(option.anchor)
        var tabId: String?
        if let ref = clean(option.artifactRef) {
            tabId = tabs.first { $0.hasName && $0.title.lowercased() == folded(ref).lowercased() }?.id
        }
        if tabId == nil, anchor == nil { return nil }
        return ArtifactLink(tabId: tabId ?? current, anchor: anchor)
    }

    /// The one script an anchor link runs in the sandboxed page. It posts a `waggle:anchor` message, so a
    /// page can react itself, then scrolls to the element with that id or `data-waggle-anchor` and
    /// outlines it for a moment. No network and no way back to the app.
    static func anchorScript(_ anchor: String) -> String {
        let data = (try? JSONEncoder().encode(anchor)) ?? Data("\"\"".utf8)
        let literal = String(data: data, encoding: .utf8) ?? "\"\""
        return """
        (function(a){try{window.postMessage({type:"waggle:anchor",anchor:a},"*");}catch(e){}
        var el=document.getElementById(a);
        if(!el){var all=document.querySelectorAll("[data-waggle-anchor]");for(var i=0;i<all.length;i++){if(all[i].getAttribute("data-waggle-anchor")===a){el=all[i];break;}}}
        if(!el)return;
        try{el.scrollIntoView({behavior:"smooth",block:"center"});}catch(e){el.scrollIntoView();}
        var s=el.style,o=s.outline,f=s.outlineOffset;s.outline="3px solid #F2B01E";s.outlineOffset="3px";
        setTimeout(function(){s.outline=o;s.outlineOffset=f;},1600);})(\(literal))
        """
    }
}

/// How wide a live page lays out and how far it scales down to fit its box (WAG-276). Never scales up.
enum LiveArtifactGeometry {
    static let defaultHeight: CGFloat = 520
    static let minHeight: CGFloat = 320
    static let maxHeight: CGFloat = 640

    /// The page scale in a box `boxWidth` wide. A page with a declared viewport wider than the box scales
    /// down to fit; every other page lays out at the box width, at 100%.
    static func scale(boxWidth: CGFloat, viewport: ViewportSize?) -> CGFloat {
        guard let viewport, viewport.width > 0, CGFloat(viewport.width) > boxWidth, boxWidth > 0 else { return 1 }
        return boxWidth / CGFloat(viewport.width)
    }

    /// The box height: the viewport's own height at the scale, held between the limits; else the default.
    static func height(boxWidth: CGFloat, viewport: ViewportSize?) -> CGFloat {
        guard let viewport, viewport.height > 0 else { return defaultHeight }
        let scaled = CGFloat(viewport.height) * scale(boxWidth: boxWidth, viewport: viewport)
        return min(max(scaled, minHeight), maxHeight)
    }
}
