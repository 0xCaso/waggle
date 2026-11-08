import Testing
import Foundation
@testable import Knock

/// Verifies the resolution order from the orchestrator's binary-resolution
/// amendment: `KNOCK_BIN` env, then the bundled resource, then `PATH`. Each
/// case builds a temp directory with an executable file named `knock` to
/// stand in for a real install location, since `FileManager.isExecutableFile`
/// is what `KnockBinaryLocator` actually checks.
struct KnockBinaryLocatorTests {
    private func makeExecutable(named name: String = "waggle", in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\necho fake\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func withTempDirectory(_ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test func prefersKnockBinOverEverythingElse() throws {
        try withTempDirectory { binDir in
            try withTempDirectory { pathDir in
                let override = try makeExecutable(named: "override-knock", in: binDir)
                let bundled = try makeExecutable(in: pathDir)
                _ = try makeExecutable(in: pathDir)

                let resolved = KnockBinaryLocator.resolve(
                    environment: ["KNOCK_BIN": override.path, "PATH": pathDir.path],
                    bundledBinaryURL: bundled,
                    applicationDirectories: []
                )
                #expect(resolved == override)
            }
        }
    }

    @Test func fallsBackToTheBundledBinaryWhenKnockBinIsUnset() throws {
        try withTempDirectory { bundledDir in
            try withTempDirectory { pathDir in
                let bundled = try makeExecutable(in: bundledDir)
                _ = try makeExecutable(in: pathDir)

                let resolved = KnockBinaryLocator.resolve(
                    environment: ["PATH": pathDir.path],
                    bundledBinaryURL: bundled
                )
                #expect(resolved == bundled)
            }
        }
    }

    @Test func fallsBackToPathWhenKnockBinAndTheBundledBinaryAreUnavailable() throws {
        try withTempDirectory { pathDir in
            let onPath = try makeExecutable(in: pathDir)

            let resolved = KnockBinaryLocator.resolve(
                environment: ["PATH": pathDir.path],
                bundledBinaryURL: nil,
                applicationDirectories: []
            )
            #expect(resolved == onPath)
        }
    }

    @Test func ignoresAKnockBinThatDoesNotExistAndFallsThrough() throws {
        try withTempDirectory { pathDir in
            let onPath = try makeExecutable(in: pathDir)

            let resolved = KnockBinaryLocator.resolve(
                environment: ["KNOCK_BIN": "/nonexistent/knock", "PATH": pathDir.path],
                bundledBinaryURL: nil,
                applicationDirectories: []
            )
            #expect(resolved == onPath)
        }
    }

    @Test func returnsNilWhenNothingResolves() {
        withTempDirectory { emptyDir in
            let resolved = KnockBinaryLocator.resolve(
                environment: ["PATH": emptyDir.path],
                bundledBinaryURL: nil,
                applicationDirectories: []
            )
            #expect(resolved == nil)
        }
    }

    // MARK: HAIL-176: Waggle first, Knock as legacy, both app names

    private func makeApp(_ appName: String, binaries: [String], under dir: URL) throws -> URL {
        let resources = dir.appendingPathComponent("\(appName)/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for name in binaries { _ = try makeExecutable(named: name, in: resources) }
        return resources
    }

    @Test func bundledWaggleWinsOverBundledKnock() throws {
        try withTempDirectory { dir in
            let resources = try makeApp("Knock.app", binaries: ["knock", "waggle"], under: dir)
            #expect(KnockBinaryLocator.firstBinary(inResources: resources)?.lastPathComponent == "waggle")
        }
    }

    @Test func anOldBundleWithOnlyKnockStillResolves() throws {
        try withTempDirectory { dir in
            let resources = try makeApp("Knock.app", binaries: ["knock"], under: dir)
            #expect(KnockBinaryLocator.firstBinary(inResources: resources)?.lastPathComponent == "knock")
        }
    }

    @Test func findsWaggleAppInTheApplicationsFolders() throws {
        try withTempDirectory { dir in
            let resources = try makeApp("Waggle.app", binaries: ["waggle", "knock"], under: dir)
            let resolved = KnockBinaryLocator.resolve(
                environment: ["PATH": ""], bundledBinaryURL: nil, applicationDirectories: [dir])
            #expect(resolved == resources.appendingPathComponent("waggle"))
        }
    }

    @Test func findsAnUpdatedAppThatStayedAtTheOldKnockAppPath() throws {
        try withTempDirectory { dir in
            let resources = try makeApp("Knock.app", binaries: ["waggle", "knock"], under: dir)
            let resolved = KnockBinaryLocator.resolve(
                environment: ["PATH": ""], bundledBinaryURL: nil, applicationDirectories: [dir])
            #expect(resolved == resources.appendingPathComponent("waggle"))
        }
    }

    @Test func waggleAppBeatsKnockAppWhenBothAreInstalled() throws {
        try withTempDirectory { dir in
            _ = try makeApp("Knock.app", binaries: ["knock"], under: dir)
            let resources = try makeApp("Waggle.app", binaries: ["waggle"], under: dir)
            let resolved = KnockBinaryLocator.resolve(
                environment: ["PATH": ""], bundledBinaryURL: nil, applicationDirectories: [dir])
            #expect(resolved == resources.appendingPathComponent("waggle"))
        }
    }

    @Test func pathTriesWaggleBeforeKnock() throws {
        try withTempDirectory { first in
            try withTempDirectory { second in
                _ = try makeExecutable(named: "knock", in: first)
                let waggle = try makeExecutable(named: "waggle", in: second)
                let resolved = KnockBinaryLocator.resolve(
                    environment: ["PATH": "\(first.path):\(second.path)"],
                    bundledBinaryURL: nil, applicationDirectories: [])
                #expect(resolved == waggle)
            }
        }
    }

    @Test func pathFallsBackToLegacyKnock() throws {
        try withTempDirectory { dir in
            let knock = try makeExecutable(named: "knock", in: dir)
            let resolved = KnockBinaryLocator.resolve(
                environment: ["PATH": dir.path], bundledBinaryURL: nil, applicationDirectories: [])
            #expect(resolved == knock)
        }
    }
}
