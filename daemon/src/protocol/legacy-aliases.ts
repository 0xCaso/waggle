// HAIL-171/176: the Knock -> Waggle transition switch. While it is true:
//   - `waggle mcp` also lists the old knock_* tool names as aliases of the waggle_* tools;
//   - the app bundle ships `Contents/Resources/knock` as a link to `waggle` (scripts/bundle-app.sh
//     reads this line);
//   - the CLI plugin migration and the legacy path lookups stay on.
// A later release removes the whole transition by setting this to false and then deleting the code
// that reads it. apps/macos/Sources/Knock/Support/LegacyNames.swift holds the matching Swift
// switch; test/legacy-aliases.test.ts fails when the two differ.
export const LEGACY_KNOCK_ALIASES = true;

// waggle_* tool name -> its old knock_* name.
export const LEGACY_TOOL_NAMES: Record<string, string> = {
  waggle_ask: "knock_ask",
  waggle_check: "knock_check",
  waggle_update: "knock_update",
  waggle_guide: "knock_guide",
  waggle_settings: "knock_settings",
  waggle_themes: "knock_themes",
};

// The waggle_* name for a tool name a client sent: the name itself, or the waggle_* tool an old
// knock_* alias stands for. Null when the name is unknown, or when it is an alias and aliases are off.
export function canonicalToolName(name: string, aliases: boolean = LEGACY_KNOCK_ALIASES): string | null {
  if (Object.hasOwn(LEGACY_TOOL_NAMES, name)) return name;
  if (!aliases) return null;
  for (const [canonical, legacy] of Object.entries(LEGACY_TOOL_NAMES)) {
    if (legacy === name) return canonical;
  }
  return null;
}

export function legacyAliasDescription(canonical: string): string {
  return `Old name of ${canonical}. Use ${canonical}.`;
}
