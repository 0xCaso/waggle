import Foundation

/// A review is a request whose item has two rows: Approve and Request changes (WAG-310 spec 4.3, WAG-316).
/// The daemon sends them as the review's options. A review stored before that (no options) gets the same two
/// rows here. A recommendation that names a row marks it. Free text marks no row: it leads the why (Q2).
enum ReviewRows {
    static let approveId = "approve"
    static let changesId = "request_changes"

    static let options: [Option] = [
        Option(id: approveId, label: "Approve: ship it as it is", title: "Approve"),
        Option(id: changesId, label: "Request changes: use my comments", title: "Request changes"),
    ]

    /// The row a recommendation names, by id or by its words ("Approve", "request-changes"); `nil` for free text.
    static func rowId(for recommendation: String, in options: [Option]) -> String? {
        let text = recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = options.first(where: { $0.id == text }) { return match.id }
        let key = text.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        return options.first { $0.id == key }?.id
    }

    struct Rows: Equatable {
        var options: [Option]
        var recommendation: String
        var recommendationWhy: String
        var recommendations: [String]
    }

    /// The rows and recommendation of a review as the app shows them. A request that is not a review, or a review
    /// that asks something else (questions), is returned as it came.
    static func normalized(
        kind: Case.Kind, options: [Option], recommendation: String, recommendationWhy: String,
        recommendations: [String], hasQuestions: Bool
    ) -> Rows {
        let same = Rows(
            options: options, recommendation: recommendation, recommendationWhy: recommendationWhy,
            recommendations: recommendations)
        guard kind == .review, !hasQuestions else { return same }
        let rows = options.isEmpty ? Self.options : options
        if let id = rowId(for: recommendation, in: rows) {
            return Rows(options: rows, recommendation: id, recommendationWhy: recommendationWhy, recommendations: [id])
        }
        let text = recommendation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return Rows(options: rows, recommendation: "", recommendationWhy: recommendationWhy, recommendations: [])
        }
        // The daemon already puts free text at the start of the why. An old review does not.
        let why = recommendationWhy.hasPrefix(text) ? recommendationWhy : Self.join(text, recommendationWhy)
        return Rows(options: rows, recommendation: "", recommendationWhy: why, recommendations: [])
    }

    /// A lead sentence and the why after it. Either may be empty.
    static func join(_ lead: String, _ why: String) -> String {
        if lead.isEmpty { return why }
        let sentence = [".", "!", "?"].contains { lead.hasSuffix($0) } ? lead : lead + "."
        return why.isEmpty ? sentence : sentence + " " + why
    }
}
