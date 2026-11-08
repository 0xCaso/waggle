import Testing
import Foundation
@testable import Knock

/// Persists unsent replies to the app support dir, never `knock.db`
/// (AGENTS.md: "The daemon is the only writer of knock.db"). Uses a temp
/// `KNOCK_HOME` per test, same isolation rule every other test in this suite
/// follows.
struct PendingReplyStoreTests {
    private func tempHome() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock_pending_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func sampleReply(caseId: String = "c_1", key: String = "key-1") -> PendingReply {
        PendingReply(caseId: caseId, idempotencyKey: key, choice: "a", message: "Go with A.", comments: [], captures: [])
    }

    @Test func aCaseWithNothingSavedHasNoPendingReply() {
        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        #expect(store.load(caseId: "missing") == nil)
        #expect(store.loadAll().isEmpty)
    }

    @Test func savedReplyRoundTripsThroughLoad() throws {
        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        let reply = sampleReply()

        try store.save(reply)

        #expect(store.load(caseId: reply.caseId) == reply)
        #expect(store.loadAll() == [reply])
    }

    @Test func savingAgainForTheSameCaseOverwritesRatherThanAccumulates() throws {
        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        try store.save(sampleReply(key: "key-1"))
        try store.save(sampleReply(key: "key-2"))

        #expect(store.load(caseId: "c_1")?.idempotencyKey == "key-2", "a later send for the same case reuses its own record, not a second file")
        #expect(store.loadAll().count == 1)
    }

    @Test func removeDropsOnlyThatCasesReply() throws {
        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        try store.save(sampleReply(caseId: "c_1"))
        try store.save(sampleReply(caseId: "c_2"))

        store.remove(caseId: "c_1")

        #expect(store.load(caseId: "c_1") == nil)
        #expect(store.load(caseId: "c_2") != nil)
    }

    @Test func doesNotTouchTheRealApplicationSupportDirectoryWhenKnockHomeIsSet() {
        let home = tempHome()
        let store = PendingReplyStore(environment: ["KNOCK_HOME": home])
        #expect(store.directoryURL.path.hasPrefix(home))
    }

    /// AC: "A pending file that fails to decode is moved to
    /// pending-replies/bad/" - a partial write or a format this build no
    /// longer reads must not be retried (and fail) on every future
    /// reconnect.
    @Test func loadAllMovesAnUndecodableFileToBadRatherThanRetryingItForever() throws {
        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        let corruptURL = store.directoryURL.appendingPathComponent("c_corrupt.json")
        try Data("not json".utf8).write(to: corruptURL)
        try store.save(sampleReply(caseId: "c_good"))

        let loaded = store.loadAll()

        #expect(loaded.map(\.caseId) == ["c_good"])
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path), "moved out of pending-replies, not left to retry")
        let movedURL = store.directoryURL.appendingPathComponent("bad").appendingPathComponent("c_corrupt.json")
        #expect(FileManager.default.fileExists(atPath: movedURL.path))
    }

    /// A second `loadAll()` (the next reconnect) must not choke on the `bad/`
    /// subdirectory it created - it is a directory, not a pending-reply file.
    @Test func loadAllIgnoresItsOwnBadSubdirectoryOnALaterCall() throws {
        let store = PendingReplyStore(environment: ["KNOCK_HOME": tempHome()])
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.directoryURL.appendingPathComponent("c_corrupt.json"))
        try store.save(sampleReply(caseId: "c_good"))
        _ = store.loadAll()

        let loadedAgain = store.loadAll()

        #expect(loadedAgain.map(\.caseId) == ["c_good"])
    }
}
