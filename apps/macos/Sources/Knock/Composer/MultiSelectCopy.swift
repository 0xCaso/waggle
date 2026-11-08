import Foundation

/// The words of a select "many" ask (HAIL-123, Pen `mL74C` and `r5BvHO`). Pure, so the copy is
/// unit-tested.
enum MultiSelectCopy {
    /// The decision card's head: "Decision · pick any" / "Decision · pick up to 2".
    static func decisionHead(max: Int?) -> String {
        "Decision · " + pickPhrase(max: max)
    }

    /// The dock label: "Pick any · 2 selected" / "Pick up to 2 · 1 of 2".
    static func dockLabel(count: Int, max: Int?) -> String {
        let phrase = pickPhrase(max: max).prefix(1).uppercased() + pickPhrase(max: max).dropFirst()
        // Nothing is counted until the person ticks (WAG-329).
        guard count > 0 else { return phrase }
        guard let max else { return "\(phrase) · \(count) selected" }
        return "\(phrase) · \(count) of \(max)"
    }

    /// Shown in the accent colour next to the dock label once the ticks reach `max`.
    static let limitReached = "limit reached"
    static let clear = "Clear"
    static let tickRecommended = "Tick the recommended"

    static func isAtLimit(count: Int, max: Int?) -> Bool {
        max.map { count >= $0 } ?? false
    }

    private static func pickPhrase(max: Int?) -> String {
        max.map { "pick up to \($0)" } ?? "pick any"
    }
}
