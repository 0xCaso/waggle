import Testing
import Foundation
@testable import Knock

struct PluginRefreshTests {
    @Test func runsForARealAppWithABundledPlugin() {
        #expect(PluginRefresh.shouldRun(environment: [:], bundleIdentifier: "dev.limone.knock", hasBundledPlugin: true))
    }

    @Test func skipsWithoutABundledPlugin() {
        #expect(!PluginRefresh.shouldRun(environment: [:], bundleIdentifier: "dev.limone.knock", hasBundledPlugin: false))
    }

    @Test func skipsWhenKnockHomeIsSetOrForADevBuild() {
        #expect(!PluginRefresh.shouldRun(environment: ["KNOCK_HOME": "/tmp/knock-x"], bundleIdentifier: "dev.limone.knock", hasBundledPlugin: true))
        #expect(!PluginRefresh.shouldRun(environment: [:], bundleIdentifier: "dev.limone.knock.dev", hasBundledPlugin: true))
    }

    @Test func refreshNeverInstallsFresh() {
        #expect(PluginRefresh.arguments == ["install", "claude", "--refresh"])
    }
}
