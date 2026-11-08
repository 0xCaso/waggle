# Waggle

**Product teams were built around handoffs. What comes next is built around decisions.**

Your agents work in many terminals. When one needs a decision or a review, it sends you a request.

Waggle is a native macOS app. Claude Code and Codex agents send it their questions and reviews. You see
every request in one **Needs you** list, with what the agent needs, why it can't decide, and what it
recommends. For a review you can click through the agent's prototype, pin comments on what you see, and
send the answer back to the same agent session. You never go back to the terminal.

Everything stays on your Mac, unless you turn on a connector or Sharing.

## Install

Download the latest
[Waggle.dmg](https://github.com/limone-eth/waggle-releases/releases/latest/download/Waggle.dmg), open it and
drag Waggle onto Applications, then follow [INSTALL.md](INSTALL.md). It takes about 5 minutes. The app is
signed and notarized, and it updates itself.

For an agent: read [INSTALL.md](INSTALL.md) and run its steps in order. Every step has a check command and
the expected output. Stop and report if a check fails.

Requirements: macOS 14 or later, and [Claude Code](https://claude.com/claude-code) or
[Codex](https://developers.openai.com/codex).

## How it works

```text
Claude Code or Codex ──MCP: waggle_ask──► waggle mcp ──unix socket──► waggle daemon (SQLite) ◄──► Waggle.app
```

- **Waggle.app** (`apps/macos`, Swift and SwiftUI): the inbox, the review canvas and Settings.
- **The daemon** (`daemon/`, TypeScript on Bun): one `waggle` binary. It owns the SQLite database and a unix
  socket. It starts on demand and stops when idle. No login item, no LaunchAgent.
- **The MCP shim** (`waggle mcp`): the MCP server your agent talks to. It forwards each call to the daemon.
- **The relay** (`relay/`, a Cloudflare Worker): serves shared pages for Sharing. Sharing is hidden in the
  app for now (`SHARING_AVAILABLE` in `daemon/src/connectors/relay.ts`). You can
  [run your own relay](relay/README.md#run-your-own-relay).

1. Your agent calls `waggle_ask` with a question or a review (a screenshot or a small HTML prototype).
2. Waggle shows it in **Needs you** and sends one notification.
3. You answer: accept the recommendation, pick an option, or write a reply. For a review, press **C** to
   comment on what you see.
4. Waggle returns your answer and your comments to that exact agent session. The agent continues.

The full contract between the parts is [docs/protocol-mvp.md](docs/protocol-mvp.md).

## Privacy and network

With every connector off and Sharing off, Waggle makes no network call. Each exception is opt-in in
Settings and calls fixed hosts only:

| Feature | Hosts | When |
|---|---|---|
| Telegram | `api.telegram.org` | after you connect Telegram |
| Slack | `slack.com`, `wss-*.slack.com` | after you connect Slack |
| Sharing and your Waggle account | `app.waggle.so` | not available in this version |
| T3 Code | loopback only | after you connect T3 Code |
| Updates | the release feed on `github.com` | release builds |

Secrets (connector tokens, the account token, the key of each shared page) live in the macOS Keychain.
Agent content is untrusted: HTML runs in an isolated web view with no network. Details: [SECURITY.md](SECURITY.md).

## Your data

Waggle stores requests, artifacts and replies in `~/Library/Application Support/Knock/`. Remove it all with
`waggle uninstall --purge`.

Waggle also keeps a private usage log there: counts such as how many requests, replies and comments happened,
and how long replies took. It stores no titles, text, paths or project names, and it is never sent anywhere.
See it with `waggle report`. Turn it off with `waggle report --off` (this deletes the log). Rows older than
90 days are deleted.

## Build from source

You need macOS 14+, Xcode 26 or later (Swift 6.2+) and [Bun](https://bun.sh) 1.3+.

```bash
git clone https://github.com/waggle-so/waggle.git && cd waggle
cd daemon && bun install && bun test && cd ..
cd apps/macos && swift build && swift test && cd ../..
./scripts/build-local.sh        # dist/Waggle.app, ad-hoc signed, no update feed
```

Read [CONTRIBUTING.md](CONTRIBUTING.md) before you run anything else: some commands register background
items on your Mac.

## Repository map

| Path | What |
|---|---|
| `apps/macos/` | The macOS app |
| `daemon/` | The `waggle` daemon, the MCP shim and the CLI |
| `relay/` | The optional sharing relay (Cloudflare Worker) |
| `plugins/` | The Claude Code and Codex plugins |
| [docs/protocol-mvp.md](docs/protocol-mvp.md) | The contract between the daemon, the shim and the app |
| [docs/decisions/](docs/decisions/) | Product decisions and why we made them |
| [INSTALL.md](INSTALL.md) | Install, connect, test, uninstall |
| [AGENTS.md](AGENTS.md) | Rules for coding agents working in this repo |

The product was called Knock before. Hidden ids keep that name on purpose (see CONTRIBUTING.md, Names).

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). The Waggle name and logo are not covered by the
license: see [TRADEMARK.md](TRADEMARK.md).
