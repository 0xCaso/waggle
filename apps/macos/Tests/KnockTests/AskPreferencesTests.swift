import Testing
import Foundation
@testable import Knock

/// HAIL-101: the ask preferences model, its settings RPC and the new pages.
@MainActor
struct AskPreferencesTests {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any] = [
            "askTopics": ["scope": "any", "picked": ["design", "code"]],
            "askFrequency": "choice",
            "askDetail": "brief",
            "askReach": "everything",
            "askWords": "asd",
        ]
        private var _sets: [String] = []
        var failSet = false
        var sets: [String] { lock.lock(); defer { lock.unlock() }; return _sets }

        func get(_ key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func set(_ key: String, _ value: Any, label: String) {
            lock.lock(); values[key] = value; _sets.append(label); lock.unlock()
        }
    }

    private func json(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(["v": any]),
              let data = try? JSONSerialization.data(withJSONObject: ["v": any]),
              let text = String(data: data, encoding: .utf8) else { return "null" }
        // Strip the {"v": ...} wrapper.
        return String(text.dropFirst(5).dropLast())
    }

    private func connectedClient(store: Store) async throws -> (KnockClient, FakeKnockServer) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { [self] method, id, line in
            guard let id else { return nil }
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            let params = object?["params"] as? [String: Any]
            let key = params?["key"] as? String ?? ""
            if method == "settings.get" {
                if key == "askText" { return jsonRPCOK(id: id, result: #"{"key":"askText","value":"TEXT for \#(store.sets.count)"}"#) }
                return jsonRPCOK(id: id, result: #"{"key":"\#(key)","value":\#(json(store.get(key) ?? NSNull()))}"#)
            }
            if method == "settings.set" {
                if store.failSet {
                    return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32603,"message":"no"}}"#.utf8)
                }
                let value = params?["value"] ?? NSNull()
                store.set(key, value, label: "\(key):\(json(value))")
                return jsonRPCOK(id: id, result: #"{"key":"\#(key)","value":\#(json(value))}"#)
            }
            return nil
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return (client, server)
    }

    @Test func settingsPageSitsAfterArtifacts() {
        let pages = SettingsPage.allCases
        #expect(pages.firstIndex(of: .asks) == pages.firstIndex(of: .artifacts)! + 1)
        #expect(SettingsPage.asks.title == "Requests")
        #expect(SettingsPage.initial(environment: ["KNOCK_SETTINGS_PAGE": "asks"]) == .asks)
    }

    @Test func tenTopicsAndTheOptionCopy() {
        #expect(AskTopic.allCases.count == 10)
        #expect(AskTopic.allCases.map(\.rawValue) == [
            "marketing", "design", "operations", "pricing", "code", "writing", "data", "personal", "reviews", "private_info",
        ])
        #expect(AskScope.allCases.map(\.title) == ["Anything", "Let me pick"])
        #expect(AskFrequency.allCases.map(\.title) == ["Only when blocked", "When there's a real choice", "Anything they'd ask in chat"])
        #expect(AskDetail.allCases.map(\.title) == ["Brief", "Rich"])
    }

    @Test func wordsCopyAndDefaults() {
        #expect(AskWords.allCases.map(\.rawValue) == ["asd", "normal"])
        #expect(AskWords.allCases.map(\.title) == ["Simple, exact English (ASD-STE100)", "Normal"])
    }

    @Test func reachCopyForTheLevels() {
        // HAIL-193: Off sits left of today's three levels.
        #expect(AskReach.allCases.map(\.rawValue) == ["off", "visual", "written", "everything"])
        #expect(AskReach.kinds.map(\.title) == ["Things to look at", "Write-ups and drafts", "Quick questions"])
        #expect(AskReach.kinds.map(\.kindNote) == [
            "Prototypes, designs, screenshots, charts, pages",
            "A plan, a trade-off, a draft to read",
            "A yes/no, a name, a default",
        ])
        #expect(AskReach.kinds.allSatisfy { $0.examples.count == 2 })
        #expect(AskReach.everything.summary == "Everything · every decision comes to Waggle (today)")
        #expect(AskReach.written.summary == "Things to look at and read · quick questions stay in the terminal")
        #expect(AskReach.visual.summary == "Only things to look at · write-ups and quick questions stay in the terminal")
        #expect(AskReach.off.summary.hasPrefix("Off · agents keep every question in the terminal"))
        // Columns at or left of the level go to Knock; the rest stay in the terminal. Off brings none.
        let goes = { (level: AskReach) in AskReach.kinds.map { level.bringsToKnock($0) } }
        #expect(goes(.off) == [false, false, false])
        #expect(goes(.visual) == [true, false, false])
        #expect(goes(.written) == [true, true, false])
        #expect(goes(.everything) == [true, true, true])
    }

    @Test func menuBarSwitchNamesTheFourLevels() {
        #expect(AskReach.allCases.map(\.menuTitle) == ["Off", "Things to look at", "Look and read", "Everything"])
    }

    @Test func offPersistsThroughTheDaemonAndTheSameModelServesSettingsAndMenuBar() async throws {
        let store = Store()
        let (client, server) = try await connectedClient(store: store)
        defer { server.stop() }
        // One model is shared by Settings and the menu bar: a pick through it is the saved value.
        let model = AskPreferencesModel(client: client)
        await model.load()
        await model.setReach(.off)
        #expect(model.reach == .off)
        #expect(store.sets.last == #"askReach:"off""#)
        // Another place changed it: refreshReach shows it.
        store.set("askReach", "written", label: "askReach:\"written\"")
        await model.refreshReach()
        #expect(model.reach == .written)
    }

    @Test func setupPreselectsThingsToLookAtOnlyForAFirstSetup() async throws {
        let store = Store()
        let (client, server) = try await connectedClient(store: store)
        defer { server.stop() }
        let first = makeOnboardingModel(askPreferences: AskPreferencesModel(client: client))
        await first.askPreferences.load()
        await first.preselectRecommendedReach(isOnboarded: false)
        #expect(first.askPreferences.reach == .visual)
        #expect(store.sets.last == #"askReach:"visual""#)
        // A pick made on the step is not undone when the step shows again.
        await first.askPreferences.setReach(.everything)
        await first.preselectRecommendedReach(isOnboarded: false)
        #expect(first.askPreferences.reach == .everything)

        // Someone who finished setup keeps the saved choice.
        let existing = makeOnboardingModel(askPreferences: AskPreferencesModel(client: client))
        await existing.askPreferences.load()
        let before = store.sets.count
        await existing.preselectRecommendedReach(isOnboarded: true)
        #expect(existing.askPreferences.reach == .everything)
        #expect(store.sets.count == before)
    }

    @Test func sharingNoteOffersTheInstallLink() {
        #expect(AgentsSharingNote.buttonTitle == "Copy waggle.so/install")
        #expect(AgentsSharingNote.installLink == "https://waggle.so/install")
        #expect(!AgentsSharingNote.subtitle.contains("—"))
    }

    @Test func reachDefaultsToEverythingAndPersistsThroughTheDaemon() async throws {
        let store = Store()
        let (client, server) = try await connectedClient(store: store)
        defer { server.stop() }
        let model = AskPreferencesModel(client: client)
        #expect(model.reach == .everything)
        await model.load()
        #expect(model.reach == .everything)
        await model.setReach(.written)
        #expect(model.reach == .written)
        #expect(store.sets.last == #"askReach:"written""#)
        await model.setReach(.written)
        #expect(store.sets.count == 1)
        store.failSet = true
        await model.setReach(.visual)
        #expect(model.reach == .written)
    }

    @Test func wordsDefaultsToAsdAndPersistsThroughTheDaemon() async throws {
        let store = Store()
        let (client, server) = try await connectedClient(store: store)
        defer { server.stop() }
        let model = AskPreferencesModel(client: client)
        #expect(model.words == .asd)
        await model.load()
        #expect(model.words == .asd)
        await model.setWords(.normal)
        #expect(model.words == .normal)
        #expect(store.sets.last == #"askWords:"normal""#)
        await model.setWords(.normal)
        #expect(store.sets.count == 1)
        store.failSet = true
        await model.setWords(.asd)
        #expect(model.words == .normal)
    }

    @Test func learnDefaultsToShortAndPersistsThroughTheDaemon() async throws {
        let store = Store()
        let (client, server) = try await connectedClient(store: store)
        defer { server.stop() }
        let model = AskPreferencesModel(client: client)
        #expect(AskLearn.allCases.map(\.rawValue) == ["short", "diagram", "steps", "try"])
        #expect(AskLearn.allCases.map(\.title) == ["Short text", "Diagram first", "Step by step", "Something to try"])
        #expect(AskLearn.allCases.allSatisfy { $0.note.hasPrefix("When you ask how something works, agents") })
        // The store has no askLearn: an older daemon reads as "short".
        await model.load()
        #expect(model.learn == .short)
        await model.setLearn(.steps)
        #expect(model.learn == .steps)
        #expect(store.sets.last == #"askLearn:"steps""#)
        await model.setLearn(.steps)
        #expect(store.sets.count == 1)
        store.failSet = true
        await model.setLearn(.diagram)
        #expect(model.learn == .steps)
        store.failSet = false
        await model.load()
        #expect(model.learn == .steps)
    }

    @Test func loadReadsTheStoredPreferencesAndTheText() async throws {
        let store = Store()
        let (client, server) = try await connectedClient(store: store)
        defer { server.stop() }
        let model = AskPreferencesModel(client: client)
        await model.load()
        #expect(model.topics == AskTopics(scope: .any, picked: [.design, .code]))
        #expect(model.frequency == .choice)
        #expect(model.detail == .brief)
        #expect(model.text.hasPrefix("TEXT for"))
        await client.stop()
    }

    @Test func clicksSendSettingsSetAndRefreshTheText() async throws {
        let store = Store()
        let (client, server) = try await connectedClient(store: store)
        defer { server.stop() }
        let model = AskPreferencesModel(client: client)
        await model.load()

        await model.setScope(.pick)
        #expect(model.topics.scope == .pick)
        await model.toggle(.pricing)
        #expect(model.topics.picked == [.design, .code, .pricing])
        await model.toggle(.design)
        #expect(model.topics.picked == [.code, .pricing])
        await model.setFrequency(.blocked)
        await model.setDetail(.rich)
        #expect(model.frequency == .blocked)
        #expect(model.detail == .rich)
        #expect(store.sets.suffix(2) == ["askFrequency:\"blocked\"", "askDetail:\"rich\""])
        #expect(model.text == "TEXT for \(store.sets.count)")

        let before = store.sets.count
        await model.setDetail(.rich)
        #expect(store.sets.count == before, "an unchanged pick sends nothing")
        await client.stop()
    }

    @Test func aFailedSendPutsThePreviousPickBack() async throws {
        let store = Store()
        let (client, server) = try await connectedClient(store: store)
        defer { server.stop() }
        let model = AskPreferencesModel(client: client)
        await model.load()
        store.failSet = true
        await model.setScope(.pick)
        await model.toggle(.data)
        await model.setFrequency(.chat)
        await model.setDetail(.rich)
        #expect(model.topics == AskTopics(scope: .any, picked: [.design, .code]))
        #expect(model.frequency == .choice)
        #expect(model.detail == .brief)
        await client.stop()
    }

    @Test func evidenceHookSwitchesToLetMePick() async throws {
        let store = Store()
        let (client, server) = try await connectedClient(store: store)
        defer { server.stop() }
        let model = AskPreferencesModel(client: client)
        await model.load()
        await AskEvidence.applyIfRequested(to: model, environment: [:])
        #expect(model.topics.scope == .any)
        await AskEvidence.applyIfRequested(to: model, environment: ["KNOCK_EVIDENCE_ASKS_PICK": "1"])
        #expect(model.topics.scope == .pick)
        await client.stop()
    }

    @Test func evidenceHookSwitchesWords() async throws {
        let store = Store()
        let (client, server) = try await connectedClient(store: store)
        defer { server.stop() }
        let model = AskPreferencesModel(client: client)
        await model.load()
        await AskEvidence.applyIfRequested(to: model, environment: ["KNOCK_EVIDENCE_ASKS_WORDS": "normal"])
        #expect(model.words == .normal)
        await AskEvidence.applyIfRequested(to: model, environment: ["KNOCK_EVIDENCE_ASKS_WORDS": "asd"])
        #expect(model.words == .asd)
        await client.stop()
    }
}
