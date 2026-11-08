import Testing
import Foundation
@testable import Knock

/// The "TEST COPY" gate (docs/stories/HAIL-34.md operator report 21:51):
/// active for anything other than the real data root or the real bundle id,
/// so a worker's evidence build never looks exactly like the operator's own
/// Knock.
struct TestCopyEnvironmentTests {
    private let releaseBundleId = "dev.limone.knock"

    @Test func inactiveWithTheDefaultHomeAndTheReleaseBundleId() {
        #expect(!TestCopyEnvironment.isActive(environment: [:], bundleIdentifier: releaseBundleId))
    }

    @Test func activeWithACustomKnockHome() {
        #expect(TestCopyEnvironment.isActive(environment: ["KNOCK_HOME": "/tmp/knock-evidence"], bundleIdentifier: releaseBundleId))
    }

    @Test func inactiveWhenKnockHomeIsSetButEmpty() {
        #expect(!TestCopyEnvironment.isActive(environment: ["KNOCK_HOME": ""], bundleIdentifier: releaseBundleId))
    }

    @Test func activeWithAnyNonReleaseBundleId() {
        #expect(TestCopyEnvironment.isActive(environment: [:], bundleIdentifier: "dev.limone.knock.dev"))
    }

    @Test func activeWithANilBundleId() {
        #expect(TestCopyEnvironment.isActive(environment: [:], bundleIdentifier: nil))
    }

    @Test func activeWhenBothConditionsAreNonDefault() {
        #expect(TestCopyEnvironment.isActive(environment: ["KNOCK_HOME": "/tmp/knock-evidence"], bundleIdentifier: "com.example.dev"))
    }

    @Test func stripLabelReadsTheExactOperatorCopy() {
        let label = TestCopyEnvironment.stripLabel
        #expect(label.hasPrefix("TEST COPY · data in "))
        #expect(label.hasSuffix(". Not your real Waggle."))
        #expect(label.contains(TestCopyEnvironment.dataRootLabel))
    }

    @Test func dataRootLabelMatchesKnockClientsOwnDefault() {
        #expect(TestCopyEnvironment.dataRootLabel == KnockClient.defaultDataRoot())
    }
}
