import Foundation

// The project page (WAG-260): the decision log, the taste themes and the repo-record switch.
// docs/protocol-mvp.md "Project page". The daemon is the only writer.

struct ProjectDecision: Decodable, Equatable, Sendable, Identifiable {
    let caseId: String
    let question: String
    let decidedAt: String
    let pick: String
    let why: String
    let optionCount: Int
    let artifactKind: String?
    var id: String { caseId }

    private enum CodingKeys: String, CodingKey {
        case caseId = "case_id", question, decidedAt = "decided_at", pick, why
        case optionCount = "option_count", artifactKind = "artifact_kind"
    }
}

struct ProjectDecisionsResult: Decodable, Equatable, Sendable {
    let items: [ProjectDecision]
    let total: Int
}

struct ProjectTheme: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let text: String
    let evidenceCount: Int
    let quotes: [String]
    var enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id, text, evidenceCount = "evidence_count", quotes, enabled
    }
}

struct ProjectInfo: Decodable, Equatable, Sendable {
    let project: String
    let decisions: Int
    let comments: Int
    let lastDecisionAt: String?
    let repoRecords: Bool
    let themes: [ProjectTheme]

    private enum CodingKeys: String, CodingKey {
        case project, decisions, comments, lastDecisionAt = "last_decision_at", repoRecords = "repo_records", themes
    }
}

struct ProjectDecisionsParams: Encodable, Sendable {
    let project: String
    let limit: Int
    let offset: Int
}

struct ProjectGetParams: Encodable, Sendable {
    let project: String
}

struct ProjectThemeToggleParams: Encodable, Sendable {
    let id: String
    let enabled: Bool
}

struct ProjectRepoRecordsParams: Encodable, Sendable {
    let project: String
    let enabled: Bool
}

struct ProjectRepoRecordsResult: Decodable, Equatable, Sendable {
    let repoRecords: Bool
    private enum CodingKeys: String, CodingKey { case repoRecords = "repo_records" }
}

extension KnockClient {
    func projectInfo(_ project: String) async throws -> ProjectInfo {
        try await call("project.get", params: ProjectGetParams(project: project))
    }

    func projectDecisions(_ project: String, limit: Int, offset: Int) async throws -> ProjectDecisionsResult {
        try await call("project.decisions", params: ProjectDecisionsParams(project: project, limit: limit, offset: offset))
    }

    @discardableResult
    func setProjectTheme(id: String, enabled: Bool) async throws -> ProjectTheme {
        try await call("project.theme_toggle", params: ProjectThemeToggleParams(id: id, enabled: enabled))
    }

    @discardableResult
    func setProjectRepoRecords(_ project: String, enabled: Bool) async throws -> Bool {
        let result: ProjectRepoRecordsResult = try await call(
            "project.set_repo_records", params: ProjectRepoRecordsParams(project: project, enabled: enabled))
        return result.repoRecords
    }
}
