import Testing
import Foundation
@testable import Knock

/// HAIL-166: the Design kit block's model and its design_kit RPCs.
@MainActor
struct DesignKitSettingsTests {
    private final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var _sets: [[String: Any]] = []
        private var _undos = 0
        var kitJSON: String
        var canUndo: Bool
        init(kitJSON: String, canUndo: Bool = false) { self.kitJSON = kitJSON; self.canUndo = canUndo }
        var sets: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _sets }
        var undos: Int { lock.lock(); defer { lock.unlock() }; return _undos }
        func addSet(_ value: [String: Any]) { lock.lock(); _sets.append(value); lock.unlock() }
        func addUndo() { lock.lock(); _undos += 1; lock.unlock() }
    }

    private nonisolated static func kit(_ ds: String = "", pen: String = "", tone: String = "", enabled: Bool = false,
                            by: String? = nil, at: String? = nil) -> String {
        let by = by.map { "\"\($0)\"" } ?? "null"
        let at = at.map { "\"\($0)\"" } ?? "null"
        return #"{"design_system":"\#(ds)","pen_file":"\#(pen)","tone":"\#(tone)","enabled":\#(enabled),"updated_at":\#(at),"updated_by":\#(by)}"#
    }

    private func connectedClient(_ fake: Fake) async throws -> (KnockClient, FakeKnockServer) {
        let socketPath = makeTempSocketPath()
        let server = FakeKnockServer(socketPath: socketPath)
        server.onRequest = { method, id, line in
            guard let id else { return nil }
            func result() -> Data { jsonRPCOK(id: id, result: #"{"kit":\#(fake.kitJSON),"can_undo":\#(fake.canUndo)}"#) }
            switch method {
            case "design_kit.get":
                return result()
            case "design_kit.set":
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                fake.addSet(object?["params"] as? [String: Any] ?? [:])
                return result()
            case "design_kit.undo":
                fake.addUndo()
                fake.kitJSON = Self.kit("Old", by: "you")
                fake.canUndo = false
                return result()
            default:
                return nil
            }
        }
        try server.start()
        let client = KnockClient(socketPath: socketPath, backoffSchedule: [0.02])
        await client.start()
        try await waitForState(client, .connected)
        return (client, server)
    }

    @Test func loadFillsTheDrafts() async throws {
        let fake = Fake(kitJSON: Self.kit("# DS", pen: "/a/b.pen", tone: "Warm", enabled: true))
        let (client, server) = try await connectedClient(fake)
        defer { server.stop() }
        let model = DesignKitModel(client: client)
        #expect(model.kit.enabled == false)
        await model.load()
        #expect(model.designSystem == "# DS")
        #expect(model.penFile == "/a/b.pen")
        #expect(model.tone == "Warm")
        #expect(model.kit.enabled)
    }

    @Test func saveSendsOnlyTheChangedFields() async throws {
        let fake = Fake(kitJSON: Self.kit("# DS", tone: "Warm"))
        let (client, server) = try await connectedClient(fake)
        defer { server.stop() }
        let model = DesignKitModel(client: client)
        await model.load()
        model.tone = "Plain"
        await model.save()
        #expect(fake.sets.count == 1)
        #expect(fake.sets[0]["tone"] as? String == "Plain")
        #expect(fake.sets[0]["design_system"] == nil)
        await model.save()
        #expect(fake.sets.count == 2)
    }

    @Test func switchSendsEnabledAndOverSizeIsRefusedBeforeTheCall() async throws {
        let fake = Fake(kitJSON: Self.kit())
        let (client, server) = try await connectedClient(fake)
        defer { server.stop() }
        let model = DesignKitModel(client: client)
        await model.load()
        await model.setEnabled(true)
        #expect(fake.sets.last?["enabled"] as? Bool == true)

        model.designSystem = String(repeating: "x", count: DesignKitCopy.maxDesignSystemBytes + 1)
        await model.save()
        #expect(model.message?.contains("limit is 1 MB") == true)
        #expect(fake.sets.count == 1)

        model.designSystem = ""
        model.penFile = "relative.pen"
        await model.save()
        #expect(model.message?.contains("starts with /") == true)
    }

    @Test func undoRestoresThePreviousKit() async throws {
        let fake = Fake(kitJSON: Self.kit("New", by: "claude:abc", at: "2026-10-05T10:00:00.000Z"), canUndo: true)
        let (client, server) = try await connectedClient(fake)
        defer { server.stop() }
        let model = DesignKitModel(client: client)
        await model.load()
        #expect(model.canUndo)
        #expect(model.changedByLine(now: Date())?.hasPrefix("Changed by Claude · ") == true)
        await model.undo()
        #expect(fake.undos == 1)
        #expect(model.designSystem == "Old")
        #expect(!model.canUndo)
        #expect(model.changedByLine() == nil)
    }

    @Test func changedByShowsOnlyForAgents() {
        var kit = DesignKit.empty
        #expect(DesignKitModel.changedByLine(kit: kit, now: Date()) == nil)
        kit.updatedBy = "you"
        #expect(DesignKitModel.changedByLine(kit: kit, now: Date()) == nil)
        kit.updatedBy = "codex:s1"
        #expect(DesignKitModel.changedByLine(kit: kit, now: Date()) == "Changed by Codex")
    }

    @Test func uploadReadsOnlyThePickedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("design.md")
        try "# Colours".write(to: file, atomically: true, encoding: .utf8)
        let big = dir.appendingPathComponent("big.md")
        try String(repeating: "y", count: 9000).write(to: big, atomically: true, encoding: .utf8)
        let huge = dir.appendingPathComponent("huge.txt")
        try String(repeating: "z", count: DesignKitCopy.maxDesignSystemBytes + 1).write(to: huge, atomically: true, encoding: .utf8)
        let binary = dir.appendingPathComponent("bin.md")
        try Data([0xff, 0xfe, 0x00, 0x80]).write(to: binary)

        let model = DesignKitModel(client: KnockClient(socketPath: makeTempSocketPath(), backoffSchedule: [1]))
        model.upload(from: file)
        #expect(model.designSystem == "# Colours")
        #expect(model.uploadedFile?.name == "design.md")
        #expect(model.uploadedFile?.bytes == 9)
        model.upload(from: big)
        #expect(model.designSystem == String(repeating: "y", count: 9000))
        #expect(model.message == nil)
        model.upload(from: huge)
        #expect(model.designSystem == String(repeating: "y", count: 9000))
        #expect(model.message?.contains("limit is 1 MB") == true)
        model.upload(from: binary)
        #expect(model.message?.contains("not text") == true)
    }

    @Test func overCapLineShowsOnlyAbove8KB() {
        #expect(DesignKitModel.overCapLine(bytes: 8 * 1024) == nil)
        #expect(DesignKitModel.overCapLine(bytes: 9000) == "8.8 KB · agents get the first 8 KB")
        #expect(DesignKitModel.overCapLine(bytes: 2 * 1024 * 1024) == "2.0 MB · agents get the first 8 KB")
    }
}
