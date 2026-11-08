import Testing
@testable import Knock

// The no-key path (KNOCK-17 fold pass 2): a dev or local build has no
// SUPublicEDKey, so Sparkle must never start and every "Check for Updates…"
// affordance is disabled.
struct UpdaterTests {
    @Test func updatesAreOffWithoutAPublicKey() {
        #expect(!Updater.hasPublicKey([:]))
    }

    @Test func updatesAreOffWithAnEmptyPublicKey() {
        #expect(!Updater.hasPublicKey(["SUPublicEDKey": ""]))
    }

    @Test func updatesAreOnWithANonEmptyPublicKey() {
        #expect(Updater.hasPublicKey(["SUPublicEDKey": "ed25519 abcdef"]))
    }

    @Test func updatesAreOffWhenTheKeyIsNotAString() {
        #expect(!Updater.hasPublicKey(["SUPublicEDKey": 123]))
    }
}
