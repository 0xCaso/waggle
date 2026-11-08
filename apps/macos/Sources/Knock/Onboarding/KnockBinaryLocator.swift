import Foundation

/// Finds the `waggle` binary to run for the onboarding window's commands.
///
/// `/usr/bin/env waggle` only finds the binary when it is on `PATH`, which is true in a terminal
/// but not for an app launched from Finder or Spotlight: those inherit launchd's minimal PATH.
/// Resolve in a fixed order instead:
/// 1. `KNOCK_BIN`: an explicit override, used by evidence runs to point at a fake script instead of
///    the real CLI (see AGENTS.md: never run the real `waggle install` outside a test).
/// 2. The binary the running bundle carries: `Contents/Resources/waggle`, then (legacy switch)
///    `Contents/Resources/knock`. The running bundle can be `Waggle.app` or an old `Knock.app`
///    that Sparkle updated in place.
/// 3. The same two names inside `Waggle.app` and `Knock.app` in `~/Applications` and `/Applications`.
/// 4. `PATH`: `waggle`, then (legacy switch) `knock`.
enum KnockBinaryLocator {
    static let binaryName = "waggle"
    static let legacyBinaryName = "knock"
    /// Bundle folder names to look for, current name first. The old name stays even with the switch
    /// off, because a Sparkle update can leave the app at the old path.
    static let appBundleNames = ["Waggle.app", "Knock.app"]

    /// Names to try inside a bundle or a PATH directory, best first.
    static var binaryNames: [String] {
        LegacyNames.aliasesEnabled ? [binaryName, legacyBinaryName] : [binaryName]
    }

    static func defaultApplicationDirectories(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [home.appendingPathComponent("Applications", isDirectory: true), URL(fileURLWithPath: "/Applications", isDirectory: true)]
    }

    /// The binary in the running bundle's Resources folder, `waggle` first.
    static func bundledBinary(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        return firstBinary(inResources: resources, fileManager: fileManager)
    }

    static func firstBinary(inResources resources: URL, fileManager: FileManager = .default) -> URL? {
        for name in binaryNames {
            let candidate = resources.appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledBinaryURL: URL? = KnockBinaryLocator.bundledBinary(),
        applicationDirectories: [URL] = KnockBinaryLocator.defaultApplicationDirectories(),
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment["KNOCK_BIN"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }
        if let bundled = bundledBinaryURL, fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for directory in applicationDirectories {
            for app in appBundleNames {
                let resources = directory
                    .appendingPathComponent(app, isDirectory: true)
                    .appendingPathComponent("Contents/Resources", isDirectory: true)
                if let found = firstBinary(inResources: resources, fileManager: fileManager) { return found }
            }
        }
        if let path = environment["PATH"] {
            for name in binaryNames {
                for directory in path.split(separator: ":") where !directory.isEmpty {
                    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
                    if fileManager.isExecutableFile(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }
        return nil
    }
}
