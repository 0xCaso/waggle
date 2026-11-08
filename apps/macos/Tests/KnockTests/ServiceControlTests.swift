import Testing
import Foundation
@testable import Knock

struct ServiceControlTests {
    @Test func startDaemonRunsTheDaemonSubcommand() {
        var captured: (path: String, arguments: [String])?
        ServiceControl.startDaemon { path, arguments in
            captured = (path, arguments)
        }
        #expect(captured?.path == ServiceControl.knockBinaryPath())
        #expect(captured?.arguments == ["daemon"])
    }

    @Test func knockBinaryPathPointsAtTheBundledBinary() {
        let path = ServiceControl.knockBinaryPath()
        #expect((path as NSString).lastPathComponent == "waggle")
    }

    private func fakeBundle(resources names: [String]) throws -> (Bundle, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knock-bundle-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Knock.app/Contents")
        let resources = app.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".write(
            to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        for name in names {
            let url = resources.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return (try #require(Bundle(url: root.appendingPathComponent("Knock.app"))), root)
    }

    @Test func aBundleLeftAtTheOldKnockAppPathStillResolvesWaggleFirst() throws {
        let (bundle, root) = try fakeBundle(resources: ["knock", "waggle"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect((ServiceControl.knockBinaryPath(bundle: bundle) as NSString).lastPathComponent == "waggle")
    }

    @Test func anOlderBundleWithOnlyKnockStillResolves() throws {
        let (bundle, root) = try fakeBundle(resources: ["knock"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect((ServiceControl.knockBinaryPath(bundle: bundle) as NSString).lastPathComponent == "knock")
    }

    @Test func aKnockSymlinkToWaggleResolvesToTheSameRealFile() throws {
        let (bundle, root) = try fakeBundle(resources: ["waggle"])
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = try #require(bundle.resourceURL)
        try FileManager.default.createSymbolicLink(
            atPath: resources.appendingPathComponent("knock").path, withDestinationPath: "waggle")
        let viaLink = ServiceControl.realPath(resources.appendingPathComponent("knock").path)
        #expect(viaLink == ServiceControl.realPath(resources.appendingPathComponent("waggle").path))
        let status = ServiceStatus(version: "1", dataRoot: "/tmp", sessionsLive: 0, casesOpen: 0, execPath: viaLink)
        #expect(!DaemonEnforcement.needsRestart(
            appVersion: "1", appBinaryPath: ServiceControl.resolvedBinaryPath(bundle: bundle), status: status))
        let throughLink = ServiceStatus(
            version: "1", dataRoot: "/tmp", sessionsLive: 0, casesOpen: 0,
            execPath: resources.appendingPathComponent("knock").path)
        #expect(!DaemonEnforcement.needsRestart(
            appVersion: "1", appBinaryPath: ServiceControl.resolvedBinaryPath(bundle: bundle), status: throughLink))
    }

    @Test func realPathResolvesASymlink() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-realpath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("target")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)

        let resolved = ServiceControl.realPath(link.path)
        #expect(resolved == ServiceControl.realPath(target.path))
        #expect(resolved != link.path)
        #expect(URL(fileURLWithPath: resolved).lastPathComponent == "target")
    }
}
