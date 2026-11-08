import Foundation

/// WAG-280: `waggle://case/<id>`, the "Back to Waggle" link on the page "In the browser" opens.
/// It opens that case and does nothing else: no other host, no extra path, no query.
enum AppDeepLink {
    static func caseId(from url: URL) -> String? {
        guard url.scheme == "waggle", url.host == "case" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, !parts[0].isEmpty, parts[0].count <= 80,
              parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return parts[0]
    }
}
