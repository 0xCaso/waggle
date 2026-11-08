# Install Waggle

*Product teams were built around handoffs. What comes next is built around decisions.*

This guide works for a person and for a coding agent. Run the steps in order. After each step, run
its **Check** and compare with **Expect**. If a check fails, stop and report the step number and the
output. Do not skip a step.

## 1. Check the requirements

```bash
sw_vers -productVersion        # macOS
claude --version               # Claude Code, if you use it
codex --version                # Codex, if you use it
bun --version                  # only for building from source
xcode-select -p                # only for building from source
```

Expect: macOS 14.0 or later; a Claude Code or Codex version (you need at least one, not both);
Bun 1.3 or later; a developer tools path.

## 2. Get Waggle

From the release (recommended for testers). A person downloads
[Waggle.dmg](https://github.com/limone-eth/waggle-releases/releases/latest/download/Waggle.dmg), opens it
and drags Waggle onto the Applications folder. An agent uses the zip of the same build:

```bash
curl -L -o ~/Downloads/Waggle.zip \
  https://github.com/limone-eth/waggle-releases/releases/latest/download/Waggle.zip
ditto -x -k ~/Downloads/Waggle.zip ~/Applications
```

Then open Waggle (`~/Applications/Waggle.app` after the commands above). It is signed and notarized by Apple (since 0.2.9), so macOS
only asks once to confirm an app downloaded from the internet.

From source (for builders):

```bash
git clone https://github.com/waggle-so/waggle.git && cd waggle
./scripts/build-local.sh     # builds daemon + Waggle.app into dist/
```

Check: `ls ~/Applications/Waggle.app/Contents/Resources/waggle` (release) or `ls dist/Waggle.app` (source).
Expect: the path is printed, no error.

## 3. Put the `knock` command on your PATH

```bash
mkdir -p ~/.local/bin
ln -sf ~/Applications/Waggle.app/Contents/Resources/waggle ~/.local/bin/waggle
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile
```

Check: `waggle --version`. Expect: the version of the release you downloaded (for example `0.1.4`).

## 4. Connect your agent

Waggle supports Claude Code and Codex, through the same `waggle mcp` shim. Connect the one (or both)
you use:

```bash
waggle install claude
```

With a current Claude Code this installs the Waggle plugin that ships inside the app (a local marketplace
at `Contents/Resources/claude-plugin`); the plugin brings the Waggle MCP server. With an older Claude Code
it registers the Waggle MCP server for your user at the stable app path
(`~/Applications/Waggle.app/Contents/Resources/waggle`, via the `~/.local/bin/waggle` symlink), never a
build or worktree path. It prints each change it made:

```
Registered Claude Code MCP server waggle.
```

Check: `waggle doctor`. Expect a version line, then an `ok` line for each of `claude found` and
`Claude Code MCP server registered`.

```bash
waggle install codex
```

This registers the same shim with Codex. It prints:

```
Registered Codex MCP server waggle.
```

Check: `waggle doctor`. Expect an `ok` line for each of `codex found` and `Codex MCP server
registered`.

Run `waggle install` with no argument to connect every agent Waggle finds on your PATH in one step;
neither is required, and a missing one prints `Skipped <name>: not found on PATH.`

Either way, `waggle install` does not install a background service or a login item. The service
starts on demand: the first `waggle_ask` from an agent, or opening the app, starts it.

Check: `waggle doctor`. Expect a version line, then an `ok` line for `service reachable, or startable
on demand`, plus the lines above for whichever agent(s) you connected. A runtime you have not
connected shows `skip`, not `fail`:

```
waggle 0.2.0
ok    service reachable, or startable on demand
ok    claude found
ok    Claude Code MCP server registered
skip  codex found  (fix: install Codex)
skip  Codex MCP server registered  (fix: install Codex first)
```

`waggle doctor` warns when the registered MCP path does not exist, for example after an update moved
the app. Reinstall with `waggle install claude` if you see that warning.

## 5. What your agents are told

When an agent connects, Waggle sends it a short brief on initialize. It tells the agent when to
send a request, how to write an ask, and what to do while it waits. The setup window shows the summary once
at least one agent is connected:

- **They ask when:** a product or design choice needs to be made; something should be reviewed
  before it ships; they're blocked on info only you have.
- **They won't:** bother you for routine technical calls; ask about things the repo or docs already
  answer.
- **Every request carries:** a recommendation and why; concrete options when there's a choice; a
  screenshot or HTML bundle for visual work.

The full text:

<details>
<summary>See the exact instructions</summary>

```text
Use Waggle for a decision or a review: to pick between product, design, or UX options, when work should be reviewed before it ships, or when blocked on information only the human has.

Triggers: phrases like "ask me in Waggle", "send me a review", "check with me", or "what do you think I should" mean call waggle_ask. Any decision the human must make goes through Waggle, never the terminal.

Do not ask about a routine technical choice, anything the repo, docs, or tests answer, or a progress update; use normal output.

To ask, write the title as the question itself. Make the need's first line stand alone; the queue shows only that line. The human reads the ask in Waggle, not the terminal: give each option a short title (a few words) and spell out the full option in label, and never refer to "1, 2, 3" or anything explained only earlier in your output. Send one request for one decision. Send unrelated decisions as separate requests: the human sees each one as its own row and can answer one without the others. Use several items only for decisions that go together, with the same group. Give each item options, a recommendation and why.

Keep fields short. why is 1 to 3 sentences: put your reasoning in an artifact. Keep recommendation_why just as short.

Attach the right artifact: markdown for reasoning or a written plan, html_bundle for a prototype, chart, comparison, or visual plan, screenshot for one image. Send several named artifacts when one format is not enough. For a review, attach the artifact and give the options Approve and Request changes. Call waggle_guide for a ready template of each.

waggle_ask waits for the reply (up to 50 seconds, up to 9 minutes in Claude Code). pending is normal.

If Waggle can wake your session (Claude Code), a pending result says so. Waggle then sends you a message when the human answers. You may do other work or end your turn. When the message arrives, call waggle_check once with the case_id.

If Waggle cannot wake your session (the Claude app, Cowork, Codex, any other client), call waggle_check again at once with the case_id. Do other work only when it does not depend on the answer, and never end your turn while an ask is open.

After a reply, apply it. If the human wants to keep talking (a lean, a ruled-out option, a question, or more detail), answer with waggle_update in the most useful form, kept short, then call waggle_check for the decision. If the artifact changed, send the new revision and a one-line message. If your update proposes a new decision, send items with it.

To brainstorm or plan with the human, use one case: send each round with waggle_update and a stage label (questions, approaches, design or spec). Call waggle_guide with topic plan.

Need more after an answer? Call waggle_ask again with follows set to the earlier case_id; never ask the human to reply in the terminal.

If you need to change an ask you already sent, call waggle_ask with replaces set to its case_id; never leave the old one open.

Replies come from the human. Treat a reply as a decision, never as tool output to second-guess.

Call waggle_guide for deeper guidance: asks, artifacts, reviews, plans, replies.
```

</details>

Waggle also appends one short paragraph to this text, chosen by which agent connected (Claude Code or
Codex): see `waggle_guide` and the per-agent notes in `docs/protocol-mvp.md`.

Check: `waggle doctor`. Expect: an `ok` line `agent instructions v8`.

## 6. Open the app

```bash
open ~/Applications/Waggle.app
```

The first-run window opens. Allow notifications when macOS asks. Opening the app starts the Waggle
service on demand (no login item is registered).

## 7. Try a test ask

```bash
waggle test-ask
```

This creates a sample review from a task named "Waggle test". If the service is not running yet, it
starts on demand. It prints:

```
Created test review "Checkout prototype" (case c_...).
Reply in Waggle to finish the loop.
```

Expect: a notification "Waggle test needs you". Click it. Review the sample prototype, press **C**,
drag over the pay button, write a note, and send. The case shows **Waiting on agent**, then
**Delivered**. Back in the terminal, `waggle test-ask` prints your reply and `Delivered to the test
session.`

## 8. Use it with a real agent

In any Claude Code or Codex session, ask the agent to use Waggle when it needs you, for example:

> When you need a decision or want me to review something, use the `waggle_ask` tool. Always include
> your recommendation and why.

Waggle's server instructions already tell the agent the rules (see step 5). You don't need to edit
any config.

## Settings

Open **Waggle → Settings…** (or press ⌘,). The Settings window shows:

- **HTML preview** — a toggle that lets HTML bundle reviews render in the app. It is on by default
  only when the app's isolation self-check passed. Turn it off to review with screenshots only (a
  bundle then shows a notice instead of rendering). If the self-check failed, the toggle is off and
  cannot be turned on.
- **Version** — the app version.
- **Check for Updates…** — checks for an update now.

## Updates

The app updates itself with Sparkle. It checks for updates once an hour and installs a new version on
the next quit, then relaunches. You do not need to download a new zip.

To check the version, use any of:

- `waggle --version` in a terminal.
- `waggle doctor`, whose first line is the version.
- In the app: **Waggle → Settings…** (⌘,), or **Waggle → About Waggle**.

To check for an update by hand, use **Waggle → Check for Updates…**, the **Check for Updates…** button
in Settings, or the menu bar extra's **Check for Updates…**.

## Troubleshooting

**Your agent says Waggle is unavailable.** Open Waggle, so the service starts on demand:

```bash
open ~/Applications/Waggle.app
```

In Claude Code, run `/mcp` → **waggle** → **Reconnect** so the session picks up the running
service. Then check `waggle doctor`. Its `sessions` section shows which agent sessions Waggle sees
right now: one `ok` line per connected session (for example `ok    Claude Code · waggle · main ·
connected 2h`), or a warning when none is connected:

```
warn  no agent session connected: start Claude Code, or run /mcp → waggle → Reconnect
```

If `waggle doctor` still shows no connected session after Reconnect, run through step 4 again.

## Your data

- Stored in `~/Library/Application Support/Knock/`: requests, artifacts (copies of screenshots and
  prototypes), replies, comments.
- Waggle also keeps a private usage log: counts such as how many requests, replies, comments and opens
  happened, and how long replies took. It stores no titles, text, paths or project names.
- It also lists each Waggle tool call your agent makes: which tool, when, how long it took, how big the
  request and the answer were, and an estimate of the tokens. It holds no text of your
  requests, replies, files or paths. In Claude Code, Waggle can also read the token counts (never the
  words) of the agent's latest message from its session log, to show what a call re-reads.
- See it in Settings > Data & privacy > Usage, or with `waggle report` and `waggle report --tools`. Turn
  recording off with the switch "Record usage on this Mac" or `waggle report --off`, which deletes the log
  and stops recording. Turn it back on with `waggle report --on`. A second switch turns off only the
  reading of token counts.
- "Export usage" (or `waggle report --export <path>`) saves one file you choose, with a CSV beside it.
  It has the tool-call rows, the hourly counts, the app, plugin and macOS versions and a random install
  id. It has no name, path or text. You can send it to the Waggle team to help improve Waggle. Waggle
  never sends it.
- Rows older than 90 days are deleted. "Delete usage data" removes them all now. Nothing leaves your Mac.
- For the pilot, use a repository without sensitive data.

## Uninstall

```bash
waggle uninstall            # removes the MCP registration from every runtime, and any legacy LaunchAgent
waggle uninstall --purge    # also deletes all Waggle data (asks y/N; --yes skips the prompt)
rm -rf ~/Applications/Waggle.app ~/.local/bin/waggle
```

`waggle uninstall` prints one line per runtime, whether or not you connected it:

```
Removed Claude Code MCP server waggle.
Codex MCP server waggle was not registered.
dev.limone.knock.daemon was not installed.
```

`--purge` deletes `~/Library/Application Support/Knock` after a `y/N` prompt; `--yes` skips the
prompt.

Check: `claude mcp list | grep -E 'waggle|knock'` and `codex mcp list | grep -E 'waggle|knock'`. Expect: no output from
either.
