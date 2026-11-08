import Foundation

/// What one queue row says (HAIL-191): the question, then one meta line in product words. Pure, so the
/// title, the meta line, the icon and the state dot are unit-tested without a window.
struct RequestRowModel: Equatable {
    /// Red: needs you. Blue: the agent works on your answer. Green: done.
    enum Dot: Equatable { case needsYou, working, done }

    /// What you will review, shown as a small icon on the right.
    enum Icon: Equatable {
        case prototype, doc, chart, screenshots

        var systemImage: String {
            switch self {
            case .prototype: "macwindow"
            case .doc: "doc.text"
            case .chart: "flowchart"
            case .screenshots: "photo.stack"
            }
        }

        var label: String {
            switch self {
            case .prototype: "Prototype"
            case .doc: "Doc"
            case .chart: "Chart"
            case .screenshots: "Screenshots"
            }
        }
    }

    let dot: Dot
    let title: String
    /// "Pricing page · Claude Code · 2m ago", with the session title after the project when it adds
    /// something: "Pricing page · Launch email copy · Claude Code · 2m ago" (WAG-279).
    let meta: String
    let icon: Icon?

    init(item: Case, timeLabel: String, artifactKind: ArtifactKind?, sessionTitle: String? = nil) {
        dot = Self.dotState(for: item)
        title = item.rowTitle
        let line = Self.meta(
            project: ProjectName.display(project: item.project), sessionTitle: sessionTitle,
            agent: item.runtimeLabel, time: timeLabel)
        // A plan shows its stage first (WAG-297): "Plan · Questions · <project> · ...".
        meta = item.plan.map { "Plan · \(SidebarSections.stageWord($0.stage.name)) · \(line)" } ?? line
        icon = Self.iconFor(item.plan != nil ? item.plan?.artifactKind : artifactKind)
    }

    static func dotState(for item: Case) -> Dot {
        if item.isDone { return .done }
        return item.status == .needsYou ? .needsYou : .working
    }

    static func iconFor(_ kind: ArtifactKind?) -> Icon? {
        switch kind {
        case .htmlBundle: .prototype
        case .markdown: .doc
        case .diagram: .chart
        case .screenshot, .screenshots: .screenshots
        case nil: nil
        }
    }

    /// "project · agent · time"; an empty part drops out.
    static func meta(project: String, sessionTitle: String? = nil, agent: String, time: String) -> String {
        // The title joins only when it is not the folder name again.
        let title = sessionTitle.flatMap { $0.caseInsensitiveCompare(project) == .orderedSame ? nil : $0 } ?? ""
        return [project, title, agent, time].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The name a person uses for the work behind an ask (HAIL-191): the topic when the ask has one, else a
/// readable name from the project folder. Never the branch.
enum ProjectName {
    /// A topic task has the topic as both its name and its project (HAIL-163). A name with a space is a
    /// topic: it shows as the agent wrote it. A folder name is cleaned.
    static func display(project: String) -> String {
        let trimmed = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(where: \.isWhitespace) { return trimmed }
        return readable(folder: trimmed)
    }

    /// Last path component, no hash suffix ("-fc8f1973"), dashes and underscores to spaces, first letter
    /// upper case: "/work/fragrant-hospital-fc8f1973" reads "Fragrant hospital".
    static func readable(folder: String) -> String {
        var name = folder.split(separator: "/").last.map(String.init) ?? folder
        if let range = name.range(of: #"[-_][0-9a-f]{6,}$"#, options: .regularExpression),
           name[range].contains(where: \.isNumber) {
            name.removeSubrange(range)
        }
        name = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let first = name.first else { return "" }
        // A name that already has capitals ("Syllotips", "waggleApp") keeps them.
        return name == name.lowercased() ? first.uppercased() + name.dropFirst() : name
    }
}
