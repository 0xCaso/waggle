import Testing
import Foundation
@testable import Knock

/// HAIL-100: the Artifacts page model and its settings RPC.
@MainActor
struct ArtifactsSettingsTests {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _sets: [String] = []
        var sets: [String] { lock.lock(); defer { lock.unlock() }; return _sets }
        func add(_ value: String) { lock.lock(); _sets.append(value); lock.unlock() }
    }

    private func connectedClient(stored: String, log: Log, failSet: Bool = false) async throws -> (KnockClient, FakeKnockServer) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            if method == "settings.get" {
                return jsonRPCOK(id: id, result: #"{"key":"artifactPreset","value":"\#(stored)"}"#)
            }
            if method == "settings.set" {
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                let params = object?["params"] as? [String: Any]
                let value = params?["value"] as? String ?? ""
                log.add("\(params?["key"] as? String ?? ""):\(value)")
                if failSet {
                    return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32603,"message":"no"}}"#.utf8)
                }
                return jsonRPCOK(id: id, result: #"{"key":"artifactPreset","value":"\#(value)"}"#)
            }
            return nil
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return (client, server)
    }

    @Test func pageSitsAfterNotificationsWithItsSubtitle() {
        let pages = SettingsPage.allCases
        #expect(pages.firstIndex(of: .artifacts) == pages.firstIndex(of: .notifications)! + 1)
        #expect(SettingsPage.artifacts.title == "Artifacts")
        #expect(SettingsPage.artifacts.subtitle == "How your agents build the pages and screenshots they send you, and how they show in a decision.")
        #expect(SettingsPage.initial(environment: ["KNOCK_SETTINGS_PAGE": "artifacts"]) == .artifacts)
    }

    @Test func startsOnVisualAndThreePresetsInOrder() {
        #expect(ArtifactPreset.allCases == [.quick, .visual, .rich])
        #expect(ArtifactPreset.allCases.map(\.title) == ["Quick", "Visual", "Rich"])
    }

    @Test func loadReadsTheStoredPreset() async throws {
        let log = Log()
        let (client, server) = try await connectedClient(stored: "rich", log: log)
        defer { server.stop() }
        let model = ArtifactsSettingsModel(client: client)
        #expect(model.preset == .visual)
        await model.load()
        #expect(model.preset == .rich)
        await client.stop()
    }

    @Test func loadRetriesUntilTheDaemonAnswers() async throws {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        let calls = Log()
        server.onRequest = { method, id, _ in
            guard method == "settings.get", let id else { return nil }
            calls.add("get")
            if calls.sets.count < 3 {
                return Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32603,"message":"starting"}}"#.utf8)
            }
            return jsonRPCOK(id: id, result: #"{"key":"artifactPreset","value":"rich"}"#)
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        let model = ArtifactsSettingsModel(client: client, retryDelay: .milliseconds(10))
        await model.load()
        #expect(model.preset == .rich)
        #expect(calls.sets.count == 3)
        await client.stop()
    }

    @Test func selectingAPresetSendsSettingsSet() async throws {
        let log = Log()
        let (client, server) = try await connectedClient(stored: "visual", log: log)
        defer { server.stop() }
        let model = ArtifactsSettingsModel(client: client)
        await model.select(.quick)
        #expect(model.preset == .quick)
        #expect(log.sets == ["artifactPreset:quick"])
        await model.select(.quick)
        #expect(log.sets.count == 1)
        await client.stop()
    }

    @Test func aFailedSendPutsThePreviousPickBack() async throws {
        let log = Log()
        let (client, server) = try await connectedClient(stored: "visual", log: log, failSet: true)
        defer { server.stop() }
        let model = ArtifactsSettingsModel(client: client)
        await model.select(.rich)
        #expect(log.sets == ["artifactPreset:rich"])
        #expect(model.preset == .visual)
        await client.stop()
    }
}
