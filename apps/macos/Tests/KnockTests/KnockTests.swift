import Testing
@testable import Knock

struct KnockTests {
    @Test func appTargetBuildsASwiftUIApp() {
        // KNOCK-01 scaffolds one empty window; reference the app type to prove
        // the test target links against the executable module.
        _ = KnockApp.self
        #expect(Bool(true))
    }
}
