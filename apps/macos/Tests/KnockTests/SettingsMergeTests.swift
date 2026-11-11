import Foundation
import Testing
@testable import Knock

/// Task 5 of the 2026-11-11 UI audit: nine Settings pages. Ask less moved into Requests ("Small things") and
/// Previews moved into Artifacts. Each moved setting keeps its stored key and value.
@MainActor
struct SettingsMergeTests {
    private final class Keys: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [String] = []
        var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
        func add(_ value: String) { lock.lock(); _sent.append(value); lock.unlock() }
    }

    @Test func theSidebarShowsNinePagesInOrder() {
        let titles = SettingsPage.visible(sharingAvailable: false).map(\.title)
        #expect(titles == [
            "Agents", "Notifications", "Artifacts", "Requests", "Phone", "Screenshots", "Updates", "Data & privacy", "Help",
        ])
    }

    @Test func theHiddenPagesKeepTheirRule() {
        let shown = SettingsPage.visible(sharingAvailable: true)
        #expect(shown.count == 11)
        #expect(shown.contains(.sharing) && shown.contains(.account))
        #expect(!SettingsPage.visible(sharingAvailable: false).contains(.sharing))
    }

    @Test func oldPageNamesOpenTheNewPlace() async throws {
        #expect(SettingsPage.initial(environment: ["KNOCK_SETTINGS_PAGE": "askLess"]) == .asks)
        #expect(SettingsPage.initial(environment: ["KNOCK_SETTINGS_PAGE": "previews"]) == .artifacts)
        #expect(SettingsPage.page(named: "nope") == nil)
        let navigation = SettingsNavigationModel(environment: [:])
        NotificationCenter.default.post(name: .knockShowSettingsPage, object: "askLess")
        #expect(try await pollUntil(.seconds(10)) { navigation.selected == .asks })
        NotificationCenter.default.post(name: .knockShowSettingsPage, object: "previews")
        #expect(try await pollUntil(.seconds(10)) { navigation.selected == .artifacts })
    }

    @Test func askLessStillWritesTheAskLessKey() async throws {
        let keys = Keys()
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            let params = ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["params"] as? [String: Any]
            if method == "settings.set" {
                keys.add(params?["key"] as? String ?? "?")
                return jsonRPCOK(id: id, result: #"{"key":"askLess","value":{"enabled":true,"rules":{"naming":false,"wording":false,"formatting":false,"tests":false}}}"#)
            }
            if method == "settings.get" {
                return jsonRPCOK(id: id, result: #"{"key":"askLess","value":{"enabled":false,"rules":{"naming":false,"wording":false,"formatting":false,"tests":false}}}"#)
            }
            return jsonRPCOK(id: id, result: "{}")
        }
        try server.start()
        defer { server.stop() }
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        let model = AskLessSettingsModel(client: client)
        await model.load()
        await model.setMaster(true)
        #expect(keys.sent == ["askLess"])
        #expect(model.value.enabled)
        await client.stop()
    }

    @Test func previewsStillUseTheirOwnStoredKeys() throws {
        // "Show HTML previews": a marker file under the data root.
        let home = isolatedKnockEnvironment()
        #expect(HTMLPreviewSettings.markerURL(environment: home).lastPathComponent == "html-preview-off")
        HTMLPreviewSettings.setDisabled(true, environment: home)
        #expect(HTMLPreviewSettings.isDisabled(environment: home))
        #expect(!HTMLPreviewSettings.isEnabled(isolationPassed: true, environment: home))
        HTMLPreviewSettings.setDisabled(false, environment: home)
        #expect(HTMLPreviewSettings.isEnabled(isolationPassed: true, environment: home))
        // "Ask before opening links": the `linkConfirmDisabled` default, on until set to true.
        let suite = "SettingsMergeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(LinkConfirmSettings.isEnabled(defaults: defaults))
        LinkConfirmSettings.setDisabled(true, defaults: defaults)
        #expect(defaults.bool(forKey: "linkConfirmDisabled"))
        #expect(!LinkConfirmSettings.isEnabled(defaults: defaults))
    }
}
