import { NOT_STAGED_BY_SHIM } from "../artifacts";
import { CodedError, DAEMON_UNREACHABLE_ERROR, SHIM_OUTDATED_ERROR } from "../protocol";
import { DaemonConnectionError, DaemonRpcError } from "./client";

// Rewrites a daemon-call failure the shim itself cannot fix into the text
// docs/protocol-mvp.md "Errors that say what to tell the user" promises: a
// sentence the agent can relay to the human verbatim, with no socket path,
// port, or other detail the human cannot act on. Every other error (a field
// validation failure, an ownership check) passes through unchanged - those
// are for the agent to fix by calling again, not for the human.
export function translateDaemonError(err: unknown): Error {
  if (err instanceof DaemonConnectionError) {
    return new CodedError(DAEMON_UNREACHABLE_ERROR, "daemon_unreachable");
  }
  if (err instanceof DaemonRpcError && err.message === NOT_STAGED_BY_SHIM) {
    return new CodedError(SHIM_OUTDATED_ERROR, "shim_outdated");
  }
  return err instanceof Error ? err : new Error(String(err));
}

// WAG-268: the text an agent gets when a waggle_ask or waggle_check that names a case fails. The ask
// is still open in Waggle, so the text says so and names the next step. No socket, port or stack text.
export function caseErrorFor(err: Error, caseId: unknown): Error {
  const id = typeof caseId === "string" && caseId.length > 0 ? caseId : null;
  const message = err.message;
  if (message === DAEMON_UNREACHABLE_ERROR || /timed out waiting for the waggle daemon/i.test(message)) {
    if (id === null) return err;
    return new CodedError(
      `The connection to Waggle restarted. Your ask ${id} is still open. ` +
        `Wait a few seconds, then call waggle_check with case_id ${id}. ` +
        "If it fails again, tell the human to open Waggle.",
      "daemon_unreachable",
    );
  }
  if (message === "not your case") {
    return new CodedError(
      "This case belongs to another coding session or folder. Do not call waggle_check for it. " +
        "Call waggle_ask to ask again.",
      "case_not_yours",
    );
  }
  if (message === "case not found") {
    return new CodedError(
      "Waggle has no case with this id. Check the id. If the ask is lost, call waggle_ask to ask again.",
      "case_not_found",
    );
  }
  return err;
}
