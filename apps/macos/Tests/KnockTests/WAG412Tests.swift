import Testing
import Foundation
@testable import Knock

/// WAG-412: "Ask less". The settings switches, the folded "Decided for you" list and "Change my mind".
@MainActor
struct WAG412Tests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _items: [String] = []
        var items: [String] { lock.lock(); defer { lock.unlock() }; return _items }
        func add(_ value: String) { lock.lock(); _items.append(value); lock.unlock() }
    }

    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        if try await !pollUntil(timeout, condition) { throw TestClientError.timedOut }
    }

    nonisolated private func decidedJSON(id: String = "c_auto", answer: String = "parseRow", category: String = "naming") -> String {
        #"{"id":"\#(id)","task_id":"t_1","kind":"question","title":"Name the helper","need":"N","why":"W","recommendation":"a","recommendation_why":"RW","options":[{"id":"a","label":"Call it parseRow","title":"parseRow"},{"id":"b","label":"Call it readRow","title":"readRow"}],"status":"resolved","has_artifact":false,"runtime":"claude","created_at":"2026-10-27T10:00:00.000Z","updated_at":"2026-10-27T10:00:00.000Z","auto_decided":{"category":"\#(category)","rule":"ask_less_\#(category)","choice":"a","answer":"\#(answer)","at":"2026-10-27T10:00:00.000Z"}}"#
    }

    nonisolated private func askLessJSON(_ enabled: Bool, naming: Bool = false) -> String {
        #"{"key":"askLess","value":{"enabled":\#(enabled),"rules":{"naming":\#(naming),"wording":false,"formatting":false,"tests":false}}}"#
    }

    /// A fake daemon that holds one AskLess value, lists `decided`, and records what the app sends.
    nonisolated private func startServer(
        stored: Bool = false, namingOn: Bool = false, decided: [String] = [], log: Log, failSet: Bool = false
    ) throws -> (String, FakeKnockServer) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            log.add(method)
            let params = ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["params"] as? [String: Any]
            switch method {
            case "settings.get":
                return jsonRPCOK(id: id, result: self.askLessJSON(stored, naming: namingOn))
            case "settings.set":
                if failSet { return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32603,"message":"no"}}"#.utf8) }
                let value = params?["value"] as? [String: Any]
                let rules = value?["rules"] as? [String: Bool] ?? [:]
                var flags: [String] = []
                for name in ["naming", "wording", "formatting", "tests"] { flags.append("\(rules[name] ?? false)") }
                log.add("set:\(value?["enabled"] as? Bool ?? false):" + flags.joined(separator: ","))
                // The daemon keeps the rules off while the master is off.
                let enabled = value?["enabled"] as? Bool ?? false
                return jsonRPCOK(id: id, result: self.askLessJSON(enabled, naming: enabled && (rules["naming"] ?? false)))
            case "cases.auto_decided":
                let changed = log.items.contains("case.change_mind")
                return jsonRPCOK(id: id, result: changed ? "[]" : "[\(decided.joined(separator: ","))]")
            case "case.change_mind":
                let reopened = self.decidedJSON().replacingOccurrences(of: #""status":"resolved""#, with: #""status":"needs_you""#)
                return jsonRPCOK(id: id, result: reopened)
            case "cases.list":
                return jsonRPCOK(id: id, result: "[]")
            default:
                return jsonRPCOK(id: id, result: "{}")
            }
        }
        try server.start()
        return (socketPath, server)
    }

    private func connected(_ socketPath: String) async throws -> KnockClient {
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return client
    }

    // MARK: Off by default and the page

    @Test func theFeatureStartsOffWithEveryRuleOff() {
        #expect(AskLess.off.enabled == false)
        for category in AskCategory.allCases { #expect(AskLess.off.isOn(category) == false) }
        #expect(AskCategory.allCases.map(\.rawValue) == ["naming", "wording", "formatting", "tests"])
        #expect(AskCategory.allCases.map(\.title) == ["Naming", "Wording", "Formatting", "Test choices"])
    }

    @Test func aRuleCountsOnlyWhileTheMasterIsOn() {
        let rules = AskLess(enabled: false, rules: ["naming": true])
        #expect(rules.isOn(.naming) == false)
        #expect(rules.wire.rules["naming"] == false)
        #expect(AskLess(enabled: true, rules: ["naming": true]).wire.rules.count == 4)
    }

    @Test func thePageSitsAfterPhoneAndKeepsTheCopyPlain() {
        let pages = SettingsPage.allCases
        #expect(pages.firstIndex(of: .askLess) == pages.firstIndex(of: .phone)! + 1)
        #expect(SettingsPage.askLess.title == "Ask less")
        #expect(SettingsPage.initial(environment: ["KNOCK_SETTINGS_PAGE": "askLess"]) == .askLess)
        let words = [AskLessCopy.masterTitle, AskLessCopy.masterBody, AskLessCopy.footer, DecidedForYouCopy.hint, DecidedForYouCopy.changeMind,
                     SettingsPage.askLess.subtitle] + AskCategory.allCases.flatMap { [$0.title, $0.detail] }
        for text in words { #expect(!text.contains("—")) }
        #expect(AskLessCopy.masterTitle == "Let the agent decide small things")
    }

    // MARK: The settings model

    @Test func loadReadsTheStoredValue() async throws {
        let log = Log()
        let (path, server) = try startServer(stored: true, namingOn: true, log: log)
        defer { server.stop() }
        let client = try await connected(path)
        let model = AskLessSettingsModel(client: client)
        #expect(model.value == .off)
        await model.load()
        #expect(model.value.enabled)
        #expect(model.isOn(.naming))
        #expect(model.isOn(.wording) == false)
        await client.stop()
    }

    @Test func categorySwitchesAreDisabledWhileTheMasterIsOff() async throws {
        let log = Log()
        let (path, server) = try startServer(log: log)
        defer { server.stop() }
        let client = try await connected(path)
        let model = AskLessSettingsModel(client: client)
        await model.load()
        #expect(model.rulesEnabled == false)
        await model.set(.naming, true)
        #expect(model.isOn(.naming) == false)
        #expect(!log.items.contains { $0.hasPrefix("set:") })
        await client.stop()
    }

    @Test func masterOnSendsEveryRuleOffAndThenARuleFlips() async throws {
        let log = Log()
        let (path, server) = try startServer(log: log)
        defer { server.stop() }
        let client = try await connected(path)
        let model = AskLessSettingsModel(client: client)
        await model.load()
        await model.setMaster(true)
        #expect(model.rulesEnabled)
        #expect(log.items.contains("set:true:false,false,false,false"))
        await model.set(.naming, true)
        #expect(log.items.contains("set:true:true,false,false,false"))
        #expect(model.isOn(.naming))
        // The master off turns every rule off.
        await model.setMaster(false)
        #expect(log.items.contains("set:false:false,false,false,false"))
        #expect(model.value == .off)
        #expect(model.isOn(.naming) == false)
        await client.stop()
    }

    @Test func aFailedSaveKeepsTheOldValueAndSaysSo() async throws {
        let log = Log()
        let (path, server) = try startServer(log: log, failSet: true)
        defer { server.stop() }
        let client = try await connected(path)
        let model = AskLessSettingsModel(client: client)
        await model.load()
        await model.setMaster(true)
        #expect(model.value == .off)
        #expect(model.problem != nil)
        await client.stop()
    }

    // MARK: The folded list and Change my mind

    @Test func aCaseDecodesItsRuleDecision() throws {
        let decoded = try JSONDecoder().decode(Case.self, from: Data(decidedJSON().utf8))
        #expect(decoded.autoDecided?.category == .naming)
        #expect(decoded.autoDecided?.answer == "parseRow")
        #expect(DecidedForYouCopy.chosenLine(decoded) == "Chose: parseRow")
        let plain = decidedJSON().replacingOccurrences(of: #","auto_decided":{"category":"naming","rule":"ask_less_naming","choice":"a","answer":"parseRow","at":"2026-10-27T10:00:00.000Z"}"#, with: "")
        #expect(try JSONDecoder().decode(Case.self, from: Data(plain.utf8)).autoDecided == nil)
        #expect(DecidedForYouCopy.headerTitle(count: 3) == "Decided for you · 3 today")
    }

    @Test func theFolderListsDecidedCasesAndNeverCountsThemAsNeedsYou() async throws {
        let log = Log()
        let (path, server) = try startServer(stored: true, namingOn: true, decided: [decidedJSON(id: "c_one"), decidedJSON(id: "c_two")], log: log)
        defer { server.stop() }
        let model = AppModel(client: KnockClient(socketPath: path, backoffSchedule: [0.02]), environment: isolatedKnockEnvironment())
        model.start()
        try await waitUntil { model.autoDecidedToday.count == 2 }
        #expect(model.autoDecidedToday.map(\.id) == ["c_one", "c_two"])
        #expect(model.needsYouCases.isEmpty)
        #expect(model.autoDecidedOpen == false)
        model.stop()
    }

    @Test func withTheFeatureOffTheAppNeverAsksForTheList() async throws {
        let log = Log()
        let (path, server) = try startServer(stored: false, log: log)
        defer { server.stop() }
        let model = AppModel(client: KnockClient(socketPath: path, backoffSchedule: [0.02]), environment: isolatedKnockEnvironment())
        model.start()
        try await waitUntil { log.items.contains("cases.list") }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!log.items.contains("cases.auto_decided"))
        #expect(model.autoDecidedToday.isEmpty)
        model.stop()
    }

    @Test func changeMyMindReopensTheCaseAndTakesItOutOfTheList() async throws {
        let log = Log()
        let (path, server) = try startServer(stored: true, namingOn: true, decided: [decidedJSON()], log: log)
        defer { server.stop() }
        let model = AppModel(client: KnockClient(socketPath: path, backoffSchedule: [0.02]), environment: isolatedKnockEnvironment())
        model.start()
        try await waitUntil { model.autoDecidedToday.count == 1 }
        await model.changeMind(caseId: "c_auto")
        #expect(log.items.contains("case.change_mind"))
        #expect(model.autoDecidedToday.isEmpty)
        model.stop()
    }

    @Test func todayStartsAtMidnightOnThisMac() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let start = AppModel.startOfToday(now: now, calendar: calendar)
        #expect(start <= now)
        #expect(now.timeIntervalSince(start) < 86_400)
        #expect(calendar.component(.hour, from: start) == 0)
    }
}
