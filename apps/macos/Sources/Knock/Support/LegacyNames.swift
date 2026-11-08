import Foundation

/// HAIL-176 renamed Knock to Waggle. While this switch is `true` the app still understands the old
/// names: `knock_*` tool names, the bundled `knock` binary, the `knock` entry in the Claude app's
/// settings and the `knock@knock` Claude Code plugin. Removing this file (and the `if
/// LegacyNames.aliasesEnabled` checks that use it) deletes all legacy handling.
/// The daemon has the same switch: `LEGACY_KNOCK_ALIASES` in daemon/src/protocol/legacy-aliases.ts.
/// Finding a bundle that stays at an old `Knock.app` path does not depend on this switch: a Sparkle
/// update can leave the app there.
enum LegacyNames {
    static let aliasesEnabled = true
}
