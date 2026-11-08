import Combine
import Testing
@testable import Knock

@MainActor
struct DockBadgeControllerTests {
    @Test func labelForCounts() {
        #expect(DockBadgeController.label(for: 0) == nil)
        #expect(DockBadgeController.label(for: 1) == "1")
        #expect(DockBadgeController.label(for: 12) == "12")
        #expect(DockBadgeController.label(for: 99) == "99")
        #expect(DockBadgeController.label(for: 100) == "99+")
        #expect(DockBadgeController.label(for: 150) == "99+")
    }

    @Test func followsTheNeedsYouCountSource() {
        let counts = CurrentValueSubject<Int, Never>(0)
        var labels: [String?] = []
        let controller = DockBadgeController(counts: counts, environment: [:]) { labels.append($0) }
        counts.send(1)
        counts.send(12)
        counts.send(0)
        #expect(labels == [nil, "1", "12", nil])
        _ = controller
    }
}
