// User-actionable MCP errors (HAIL-38, docs/protocol-mvp.md "Errors that say
// what to tell the user"). When only the human can fix a problem, the shim's
// error text starts with this exact sentence for the agent to relay verbatim,
// so the agent never invents its own wording, and never leaks a socket path
// or a port to someone who cannot act on it. The translation from a raw
// daemon-call failure to this text lives in daemon/src/mcp/errors.ts, since it
// needs the shim's own error types; this file holds only the strings, so the
// protocol module (no dependency on mcp/) can still export them.

export const USER_ACTIONABLE_PREFIX = "Please tell the user: ";

export const DAEMON_UNREACHABLE_ERROR =
  `${USER_ACTIONABLE_PREFIX}Waggle isn't running. Please open Waggle and tell me when it's ready.\n` +
  "Do not mention sockets, ports, or other technical details. Once they say it's ready, call the " +
  "same tool again.";

export const SHIM_OUTDATED_ERROR =
  `${USER_ACTIONABLE_PREFIX}Waggle was updated, and this coding session is still using the old ` +
  "connection to it. Please close and reopen this coding session, then tell me when you've done " +
  "that.\nDo not mention shims, sockets, or file paths. Once they say it's done, call the same " +
  "tool again.";
