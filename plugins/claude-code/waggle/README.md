# Waggle for Claude Code

This plugin connects Claude Code to the Waggle Mac app. Claude asks you for decisions and reviews in Waggle. You answer there. Claude gets the answer back.

The plugin has three parts:

- **The Waggle MCP server.** It gives Claude the tools `waggle_ask`, `waggle_check`, `waggle_update` and `waggle_guide`.
- **Skills.** `waggle` tells Claude when to ask and how to write a good ask. `waggle-prototype` gives taste rules and polish details for prototypes (with the MIT-licensed make-interfaces-feel-better by Jakub Krehel), and says when to use the optional impeccable skill.
- **waggle-diagram.** An adapted copy of the MIT-licensed diagram-design by Cathryn Lavery. It gives layout rules, a 9 node and 12 arrow budget, two check scripts (system python3) and takes colours and fonts from the project design system.
- **A mod.** It shows Waggle status above the prompt, tells Waggle what the session is doing, and delivers Waggle's Nudge.

You need the Waggle app in `/Applications` or `~/Applications` first. The plugin does not install it.

## Install

**Waggle installs it for you.** The Waggle app carries this plugin as a local marketplace at `Contents/Resources/claude-plugin`. Onboarding and Settings > Agents > Reconnect run `waggle install claude`. That command adds the marketplace, installs `waggle@waggle` at user scope and removes an older `knock` MCP entry. Claude Code without plugin support (before the `claude plugin` commands) gets the MCP entry instead. After an app update, Waggle refreshes the plugin when it starts.

**By hand.** Add the marketplace that ships in the app, then install:

```text
/plugin marketplace add /Applications/Waggle.app/Contents/Resources/claude-plugin
/plugin install waggle@waggle
```

The repository also holds a marketplace at its root, for developers:

### Terminal

```text
/plugin marketplace add <path of the Waggle repo>
/plugin install waggle@waggle
```

Restart Claude Code, or run `/reload-plugins`.

### Desktop app (Code tab)

1. Open the Code tab.
2. Choose **+**, then **Plugins**.
3. Add the Waggle marketplace, then install **waggle**.

### VS Code and JetBrains

Install the plugin the same way in the terminal inside the editor, or from the plugin list. The chat panels run the mod's hooks, so live state and Nudge work there. They draw no band.

## If you ran `waggle install` before

`waggle install claude` adds a user-level `waggle` MCP server. With the plugin installed, Claude Code would run two Waggle servers. Run `waggle install claude` again. With the plugin present it adds no entry and removes the old one. `waggle doctor` and Waggle's Settings > Agents tell you when both exist.

## What the mod does

**The band above the prompt.** It draws only while this session has an ask that waits for you.

- First minute: nothing. The Waggle notification is fresh.
- One to ten minutes: `Waggle · still waiting on your answer · 3m · 1: open`, with Waggle in its own colour. Type `1` on an empty prompt to open the ask in Waggle.
- After ten minutes: `Waggle · waiting on your answer · <title> · 12m` in Waggle's colour.
- When you answered: a toast, `Answered in Waggle: <choice>`, and the line `Waggle · you chose <choice> · "<note>"` until your next prompt (at most 10 minutes).
- When other sessions have asks for you: `+2 in other sessions · 2: queue` on the right, or, when this session has no ask, `Waggle · 2 requests waiting for you in other sessions · 2: queue`. Type `2` on an empty prompt to open the queue in Waggle.

Press `o` to open Waggle on the ask and `q` to bring Waggle forward. The keys work while the band has focus (click it, or press ctrl+x then tab). The band works on the terminal and in the Desktop app's Code tab.

**Live session state.** The mod tells Waggle when a turn starts and completes, that a prompt was submitted, and the name of each tool Claude calls. Waggle then shows exactly when a session works or is idle. Without the mod, Waggle reads the transcript instead. Before a Waggle tool runs, the mod also gives `waggle mod usage` the session log path. Waggle reads only the four token counts of the latest assistant message from it, never the words, to show what a call re-reads. Turn this off in Settings > Data & privacy > Usage.

**Nudge.** When you answered and Claude has not picked the answer up, Waggle's Nudge reaches the session through the mod. Sessions without the mod still use the messaging socket.

## What the mod can reach

A mod is not sandboxed: it runs with your permissions. This one does only this:

- It runs `bin/waggle-launcher mod ...` through `$.process.run`. The launcher finds the Waggle app and runs its `knock` binary. That binary talks to the Waggle daemon on a local unix socket.
- It sends the session id, the event name (`turn.start`, `turn.complete`, `prompt.submit`, `tool.call`), the tool name, and a count. It never sends your prompt text, tool arguments or Claude's replies.
- It reads ask titles, answers and notes from Waggle to draw the band.
- It submits one prompt, the Nudge line, when Waggle asks.
- It makes no network calls. It reads and writes no files.

## Needs

- Claude Code **2.1.287 or later** for the mod. Below that version the MCP server and the skill still work, and the mod does not load.
- The Waggle app, installed.

## Check it

```text
claude plugin validate --strict plugins/claude-code/waggle
claude plugin test plugins/claude-code/waggle
```

The tests answer every `knock` call with a fake. They need no Waggle app and no Claude Code login. The daemon side is tested by `cd daemon && bun test`.

## Keeping questions in Waggle

The plugin has two hooks (WAG-265). When Claude Code ends a turn with a question and no Waggle ask is open, the `Stop` hook sends it back once with "Ask this in Waggle". After a compaction or a resume, the `SessionStart` hook adds one line that reminds the agent to use `waggle_ask`. A fresh start gets nothing. Turn the first one off in Waggle › Settings › Agents › "Catch questions in the terminal".
