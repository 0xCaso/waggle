# Waggle plugin for Codex

The Waggle Codex plugin gives Codex a skill for writing good asks and hooks that tell Waggle what the
session is doing. Waggle's tools (`waggle_ask`, `waggle_check`, `waggle_update`, `waggle_guide`) stay the
`[mcp_servers.waggle]` entry in Codex's config: Codex documents plugin MCP servers as remote URLs, and the
config entry is known to work. `waggle install codex` sets up both.

```text
plugin.json            manifest (Agent Plugins format, OpenAI extension names the hooks)
skills/waggle/          the ask guidance (it points to waggle_guide)
hooks/hooks.json       SessionStart, UserPromptSubmit, PreToolUse, Stop, SessionEnd
bin/waggle-launcher     finds the installed Waggle and runs `knock <args>`
```

The app ships this folder at `Contents/Resources/codex-plugin/waggle`, inside a local marketplace named
`waggle` (`.agents/plugins/marketplace.json`). `waggle install codex` adds that marketplace and runs
`codex plugin add waggle@waggle`, and keeps or adds the `[mcp_servers.waggle]` entry. `waggle install codex --refresh` installs a newer version of an installed
plugin. `waggle uninstall` removes it. Codex without `codex plugin` keeps the old `[mcp_servers.waggle]` entry.

## Hooks

Each hook runs `waggle mod codex-hook <Event>` through the launcher. It reads the JSON Codex sends on stdin,
makes one RPC (`mod.report`, `mod.stop_check`) and exits 0. A problem prints nothing: a hook never breaks
or delays a turn (timeouts are 2 to 3 seconds). Only SessionStart starts the Waggle background service.

| Event | Reports | Sends |
| --- | --- | --- |
| SessionStart | idle | session id, folder |
| UserPromptSubmit | turn start | session id, folder. The prompt text is never read. |
| PreToolUse | tool call | the tool name only |
| Stop | turn complete, then asks `mod.stop_check` | |
| SessionEnd | session end | |

`Stop` continues the turn while the session has a Waggle ask open (waiting on the human, or answered and not
picked up yet). It returns `{"decision":"block","reason":"A Waggle ask is still open (<title>). Call
waggle_check with case_id <id> and wait for the answer before ending your turn."}`. The daemon blocks at most
3 times for one case, so a turn can never loop forever.

**Trust.** Codex skips plugin hooks until the user reviews them. After the install, open `/hooks` in the
Codex CLI and trust the Waggle hooks. Until then the MCP server and the skill work, and the hooks do nothing.

## Session id

Hooks report Codex's `session_id` (its thread id). The shim uses `CODEX_THREAD_ID` as its session id when
Codex passes it to the MCP server. If it does not, the daemon matches the hook session to the one live Codex
session in the same folder; with none or two it does nothing by guess.
