// The desktop flavour of the guide (HAIL-163): for a session that is not Claude Code, such as the
// Claude desktop app or Cowork. No hooks, no nudge, and often no project folder. The shim says so
// with `flavour: "desktop"` on guide.get; Claude Code sessions never see this text.

export const DESKTOP_GUIDE_SECTION = `## Desktop app note

You are not in Claude Code, so three things differ.

1. Keep calling waggle_check until the reply arrives. Waggle cannot wake you when the human answers, so a reply waits until you call waggle_check with the case_id. A pending result is normal: call waggle_check again at once. Do not end your turn while an ask is open. After you send an ask, tell the person once, in plain words: "When you answer in Waggle, paste the line Waggle gives you here so I can continue."
2. Send artifacts as content, not as paths. You have no project folder Waggle can read, and a relative path fails. Use { type: "markdown", content: "# ..." } for a write-up, { type: "html_bundle", html: "<!doctype html>..." } for one self-contained page (inline CSS and JS, no other files, no network), and { type: "screenshot", data_base64: "..." } for a small PNG. Limits: markdown 1 MB, HTML 50 MB, an image 20 MB decoded, but keep all of it small. Ignore the path and dir instructions in this guide. waggle_update takes the same content fields.
3. Pass a topic on every waggle_ask: a short name for the job, like "Syllotips launch email". Without a git project the queue has no other name to show. Asks with the same topic group together, so use the same words each time for the same job.`;

// The shorter note appended to the MCP instructions the shim serves (instructionsFor).
export const DESKTOP_RUNTIME_NOTE = `Desktop app note: Waggle cannot wake you when the human answers, so keep calling waggle_check with the same case_id until the reply arrives; a pending result is normal, and never end your turn while an ask is open. After you send an ask, tell the person once: "When you answer in Waggle, paste the line Waggle gives you here so I can continue." Send artifacts as content, not as paths: markdown as content, an HTML page as one self-contained html string, a small image as data_base64. Pass a topic on every waggle_ask, a short name for the job, so the queue shows what it is about and asks on one job group together.`;
