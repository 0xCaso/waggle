import { z } from "zod";

// WAG-409: a stable code for every MCP tool-call error. The code, never the text, goes into the
// tool-call log and the usage export. The text the agent reads stays as it is. A code is a short
// snake_case word that does not change once shipped. The result kind of a call comes from the code.
export const ToolErrorCode = z.string().regex(/^[a-z][a-z0-9_]{1,59}$/);
export type ToolErrorCode = z.infer<typeof ToolErrorCode>;

export type ToolErrorKind = "error_connection" | "error_artifact" | "error_invalid" | "error_other";

// Used when a call failed and nothing named a cause (an error from a daemon or a path older than this).
export const UNCLASSIFIED_ERROR_CODE = "unclassified";

// An error with a stable code. The message is for the agent and is never logged.
export class CodedError extends Error {
  constructor(
    message: string,
    public readonly errorCode: string,
  ) {
    super(message);
  }
}

// The key in a JSON-RPC error's `data` that carries the code from the daemon to the shim.
export const ERROR_CODE_DATA_KEY = "error_code";

export const CONNECTION_ERROR_CODES: readonly string[] = ["daemon_unreachable", "shim_outdated"];

// Not artifact problems, but the caller sent something wrong.
export const INVALID_ERROR_CODES: readonly string[] = [
  "invalid_params",
  "unknown_guide_topic",
  "unknown_tool",
  "reply_not_queued",
  "choice_not_offered",
  "follows_case_invalid",
  "replaces_case_invalid",
];

// Every code of an artifact problem (ArtifactError in stage.ts, ingest.ts and attachments.ts).
export const ARTIFACT_ERROR_CODES: readonly string[] = [
  "file_unreadable",
  "not_regular_file",
  "too_large",
  "markdown_bad_extension",
  "diagram_bad_extension",
  "screenshot_bad_extension",
  "screenshot_not_png",
  "screenshot_not_jpeg",
  "screenshot_source_missing",
  "html_empty",
  "invalid_base64",
  "not_png_or_jpeg",
  "bundle_dir_not_found",
  "bundle_dir_symlink",
  "bundle_dir_not_directory",
  "bundle_dir_unreadable",
  "bundle_entry_outside",
  "bundle_entry_missing",
  "bundle_entry_symlink",
  "bundle_entry_not_file",
  "bundle_symlink",
  "bundle_too_many_files",
  "bundle_unsupported_entry",
  "preview_outside",
  "preview_missing",
  "preview_symlink",
  "preview_not_file",
  "preview_bad_extension",
  "path_empty",
  "path_not_relative",
  "path_traversal",
  "not_staged_by_shim",
  "attachment_not_staged",
  "attachment_limit",
  "attachment_source_ambiguous",
  "attachment_not_found",
  "attachment_not_regular_file",
  "artifact_invalid",
];

export function errorKindForCode(code: string | undefined): ToolErrorKind {
  if (code === undefined) return "error_other";
  if (CONNECTION_ERROR_CODES.includes(code)) return "error_connection";
  if (INVALID_ERROR_CODES.includes(code)) return "error_invalid";
  if (ARTIFACT_ERROR_CODES.includes(code)) return "error_artifact";
  return "error_other";
}
