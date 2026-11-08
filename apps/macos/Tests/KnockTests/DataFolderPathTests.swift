import Testing
@testable import Knock

/// HAIL-50 contract test: "data path abbreviation" - the Data & privacy
/// page's `~`-abbreviated data folder path.
struct DataFolderPathTests {
    @Test func abbreviatesAPathUnderHomeWithATilde() {
        let path = DataFolderPath.abbreviated(
            "/Users/tester/Library/Application Support/Knock",
            home: "/Users/tester"
        )
        #expect(path == "~/Library/Application Support/Knock")
    }

    @Test func leavesAPathOutsideHomeUnchanged() {
        let path = DataFolderPath.abbreviated("/tmp/knock-1234", home: "/Users/tester")
        #expect(path == "/tmp/knock-1234")
    }

    @Test func doesNotAbbreviateAPathThatMerelySharesAPrefixWithHome() {
        // "/Users/tester2" must not be treated as living under "/Users/tester".
        let path = DataFolderPath.abbreviated("/Users/tester2/Waggle", home: "/Users/tester")
        #expect(path == "/Users/tester2/Waggle")
    }

    @Test func homeItselfAbbreviatesToTheBareTilde() {
        let path = DataFolderPath.abbreviated("/Users/tester", home: "/Users/tester")
        #expect(path == "~")
    }
}

/// The "Answered requests" row's label (HAIL-52 contract).
struct AnsweredAsksLabelTests {
    @Test func noneYetWhenCountIsZero() {
        #expect(AnsweredAsksLabel.text(count: 0, bytes: 0) == "No answered decisions yet")
        // Zero bytes with a positive count should never happen in practice
        // (an answered ask with an artifact always has some size), but the
        // count, not the byte total, decides the empty-set wording.
        #expect(AnsweredAsksLabel.text(count: 0, bytes: 1_000_000) == "No answered decisions yet")
    }

    @Test func singularForOneAnsweredAsk() {
        let text = AnsweredAsksLabel.text(count: 1, bytes: 2_000_000)
        #expect(text.hasPrefix("1 answered decision ·"))
        #expect(!text.contains("asks"))
    }

    @Test func pluralForMoreThanOneAnsweredAsk() {
        let text = AnsweredAsksLabel.text(count: 3, bytes: 2_000_000)
        #expect(text.hasPrefix("3 answered decisions ·"))
    }
}

/// The clear confirmation's message (HAIL-236).
struct ClearAnsweredMessageTests {
    @Test func saysHowManyAndThatOpenAsksStay() {
        let text = ClearAnsweredMessage.text(count: 432)
        #expect(text.contains("432 finished decisions"))
        #expect(text.contains("still need you or are waiting on the agent stay"))
        #expect(ClearAnsweredMessage.text(count: 1).contains("1 finished decision,"))
    }
}
