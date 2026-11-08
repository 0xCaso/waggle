# Security

## Report a problem

Please do not open a public issue for a security problem. Report it privately on GitHub:
**Security > Report a vulnerability** in this repository.

- We answer within 3 working days.
- We send a plan or a fix within 14 days for a confirmed problem.
- We credit you in the release notes, unless you ask us not to.

Supported versions: the latest release only. The app updates itself through Sparkle.

## Trust model

Waggle is a local app. The design assumes these things.

**Trusted**
- The operator, and the user account Waggle runs as.
- The Waggle app, the `waggle` daemon and the MCP shim, as signed and shipped.

**Not trusted**
- What an agent sends: text, options and artifacts. An agent can be wrong, or a prompt injection can steer it.
- HTML bundles. They render in an isolated `WKWebView`: file access only inside the bundle's own folder, every
  other URL blocked by a content rule list, no script bridge to the app, and a non-persistent data store. If an
  isolation check fails, the app shows a screenshot only. See "HTML preview isolation" in `docs/protocol-mvp.md`.
- Agent text renders as safe markdown: bold, italics, inline code, lists and paragraphs. No links, no images,
  no HTML.
- On a shared page (the relay): visitors, guests and their comments. Artifact files are served from a separate
  content origin, in a sandboxed frame with `connect-src 'none'` and a one-hour signed ticket.

**Local boundaries**
- The daemon is the only writer of its SQLite database. The app and the shim talk to it over a unix socket
  with mode `0600` in `~/Library/Application Support/Knock/`.
- Connector secrets, the relay device token and each shared case's owner key live in the macOS Keychain,
  never in the database or a log.

## Network

With every connector off and Sharing off, the daemon and the app make no network call. Each exception is
opt-in and calls fixed hosts only:

| Feature | Who calls | Hosts |
|---|---|---|
| Telegram connector | daemon | `api.telegram.org` |
| Slack connector | daemon | `slack.com`, `wss-*.slack.com` |
| Sharing and Waggle account (hidden for now) | daemon | `app.waggle.so` (outbound HTTPS only) |
| T3 Code | app | loopback only (`127.0.0.1`, `::1`, `localhost`) |
| Updates (release builds only) | app (Sparkle) | the release feed on `github.com` |

No listener, no webhook. Environment overrides for these hosts work in a dev build only. A release daemon
ignores them.

## Signing

Release builds are signed with the maintainer's Developer ID, notarized by Apple and signed for Sparkle.
These keys are never in this repository or in CI. A build from source is ad-hoc signed and cannot update a
release install.
