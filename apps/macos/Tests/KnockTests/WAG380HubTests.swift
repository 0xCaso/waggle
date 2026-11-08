import Combine
import Foundation
import Testing
@testable import Knock

/// WAG-380: a host that SwiftUI builds again for the same write-up must not make the hub publish, or the
/// header redraws, the page lays out again and builds the host again, without end.
@MainActor
struct WAG380HubTests {
    private func store() -> ArtifactSeenStore {
        ArtifactSeenStore(defaults: UserDefaults(suiteName: "wag380-\(UUID().uuidString)")!)
    }

    private func make(_ store: ArtifactSeenStore) -> WriteUpChangesModel {
        WriteUpChangesModel(plan: WriteUpChangesPlan(base: 1, opensAtFirstChange: false), result: WriteUpDiff.diff(old: "a", new: "b"), store: store)
    }

    @Test func aRebuiltHostGetsTheSameModelAndPublishesNothing() {
        let hub = WriteUpChangesHub()
        let store = store()
        var sends = 0
        let watch = hub.objectWillChange.sink { sends += 1 }
        defer { watch.cancel() }
        var built = 0
        for _ in 0..<5 {
            // Each pass is a new host: it asks for its model, then appears.
            let model = hub.model(for: "c|a|2|box") { built += 1; return make(store) }
            hub.activate(model)
        }
        #expect(built == 1)
        #expect(sends == 1, "only the first appearance publishes")
    }

    @Test func aNewWriteUpGetsANewModelAndPublishes() {
        let hub = WriteUpChangesHub()
        let store = store()
        let first = hub.model(for: "c|a|2|box") { make(store) }
        hub.activate(first)
        let second = hub.model(for: "c|a|3|box") { make(store) }
        #expect(first !== second)
        hub.activate(second)
        #expect(hub.active === second)
        hub.deactivate(second)
        #expect(hub.active == nil, "the header clears when the write-up goes away")
    }

    @Test func theOldWayPublishedOnEveryPass() {
        // The 0.2.47 host built a new model on every pass. That is why `active !== model` was always true.
        let hub = WriteUpChangesHub()
        let store = store()
        var sends = 0
        let watch = hub.objectWillChange.sink { sends += 1 }
        defer { watch.cancel() }
        for _ in 0..<5 { hub.activate(make(store)) }
        #expect(sends == 5)
    }
}
