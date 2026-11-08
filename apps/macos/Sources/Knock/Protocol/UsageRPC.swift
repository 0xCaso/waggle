import Foundation

// usage.summary / usage.control / usage.export (HAIL-195): the Data & privacy page's Usage section.
// docs/protocol-mvp.md "Usage log". Every number is an estimate; no text of any ask is in them.

struct UsageToolRow: Decodable, Sendable, Equatable {
    let tool: String
    let calls: Int
    let tokensWritten: Int
    let tokensReceived: Int
    let contextTokens: Int
    let waitedS: Double

    private enum CodingKeys: String, CodingKey {
        case tool, calls
        case tokensWritten = "tokens_written"
        case tokensReceived = "tokens_received"
        case contextTokens = "context_tokens"
        case waitedS = "waited_s"
    }
}

struct UsageSessionRow: Decodable, Sendable, Equatable {
    let sessionId: String
    let clientName: String?
    let calls: Int
    let tokens: Int

    private enum CodingKeys: String, CodingKey {
        case calls, tokens
        case sessionId = "session_id"
        case clientName = "client_name"
    }
}

struct UsageSummary: Decodable, Sendable, Equatable {
    let days: Int
    let record: Bool
    let transcript: Bool
    /// "Include my notes and comments in the export" (WAG-366). Nil from an older daemon.
    let exportText: Bool?
    let retentionDays: Int
    let calls: Int
    let tokensWritten: Int
    let tokensReceived: Int
    let contextTokens: Int
    let contextMeasuredCalls: Int
    let tools: [UsageToolRow]
    let waitCalls: Int
    let waitShare: Double?
    let waitedS: Double
    let topSessions: [UsageSessionRow]
    let tokensPerImage: Int
    let bytesPerToken: Int

    private enum CodingKeys: String, CodingKey {
        case days, record, transcript, calls, tools
        case retentionDays = "retention_days"
        case tokensWritten = "tokens_written"
        case tokensReceived = "tokens_received"
        case contextTokens = "context_tokens"
        case contextMeasuredCalls = "context_measured_calls"
        case waitCalls = "wait_calls"
        case waitShare = "wait_share"
        case waitedS = "waited_s"
        case topSessions = "top_sessions"
        case tokensPerImage = "tokens_per_image"
        case bytesPerToken = "bytes_per_token"
        case exportText = "export_text"
    }
}

struct UsageControlResult: Decodable, Sendable, Equatable {
    let record: Bool
    let transcript: Bool
    let retentionDays: Int
    let toolCalls: Int
    let usageEvents: Int
    let deleted: Int

    private enum CodingKeys: String, CodingKey {
        case record, transcript, deleted
        case retentionDays = "retention_days"
        case toolCalls = "tool_calls"
        case usageEvents = "usage_events"
    }
}

struct UsageExportResult: Decodable, Sendable, Equatable {
    let jsonPath: String
    let csvPath: String
    let toolCalls: Int
    let usageEvents: Int
    /// The replies whose text is in the file (WAG-366). Nil from an older daemon.
    let notes: Int?

    private enum CodingKeys: String, CodingKey {
        case jsonPath = "json_path"
        case csvPath = "csv_path"
        case toolCalls = "tool_calls"
        case usageEvents = "usage_events"
        case notes
    }
}

struct UsageSummaryParams: Encodable, Sendable {
    let days: Int
}

/// Only the fields that are set are sent, so one switch never changes the other.
struct UsageControlParams: Encodable, Sendable {
    var record: Bool?
    var transcript: Bool?
    var delete: Bool?
    var exportText: Bool?

    private enum CodingKeys: String, CodingKey {
        case record, transcript, delete
        case exportText = "export_text"
    }
}

struct UsageExportParams: Encodable, Sendable {
    let path: String
}

extension KnockClient {
    func usageSummary(days: Int) async throws -> UsageSummary {
        try await call("usage.summary", params: UsageSummaryParams(days: days))
    }

    func usageControl(_ params: UsageControlParams) async throws -> UsageControlResult {
        try await call("usage.control", params: params)
    }

    func usageExport(path: String) async throws -> UsageExportResult {
        try await call("usage.export", params: UsageExportParams(path: path))
    }
}
